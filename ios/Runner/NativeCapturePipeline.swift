import AVFoundation
import CoreMedia
import Flutter
import Foundation
import HaishinKit
import UIKit
import Vision

private struct BufferedSegment {
  let path: String
  let startEpochMs: Int64
  let endEpochMs: Int64
}

/// Parses `rtmp://host:1935/app/streamKey` → connect URL + stream name.
private enum RtmpUrl {
  static func split(_ raw: String) -> (tcUrl: String, streamName: String)? {
    guard let u = URL(string: raw), let scheme = u.scheme, scheme.hasPrefix("rtmp") else {
      return nil
    }
    var path = u.path
    if path.hasPrefix("/") {
      path.removeFirst()
    }
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.isEmpty else { return nil }
    let streamName = parts.last!
    let parent = parts.dropLast().joined(separator: "/")
    var comp = URLComponents(url: u, resolvingAgainstBaseURL: false)!
    comp.path = parent.isEmpty ? "" : "/" + parent
    guard let base = comp.string else { return nil }
    return (base, streamName)
  }
}

final class NativeCapturePipeline: NSObject, AVCaptureFileOutputRecordingDelegate {
  private var eventSink: FlutterEventSink?
  private var methodChannel: FlutterMethodChannel?

  private let clipsDirectory: URL
  private let sessionQueue = DispatchQueue(label: "com.swingcapture.session")
  private let writerQueue = DispatchQueue(label: "com.swingcapture.writer")
  private let poseQueue = DispatchQueue(label: "com.swingcapture.pose")

  private var captureSession: AVCaptureSession?
  private var movieOutput: AVCaptureMovieFileOutput?
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private var previewContainer: PreviewContainerView?

  private var lensPosition: AVCaptureDevice.Position = .back
  private var previewRequested = false
  private var detectionEnabled = false
  private var bufferingEnabled = false
  private var preRollMs: Int64 = 3000
  private var postRollMs: Int64 = 3000
  private var segmentDurationMs: Int64 = 2000
  private var videoFpsMode: String = "standard"

  private var currentRecordingURL: URL?
  private var currentSegmentStartEpochMs: Int64 = 0
  private var segmentRotateWorkItem: DispatchWorkItem?
  private var completedSegments: [BufferedSegment] = []
  private var isProcessingPose = false

  private var rtmpConnection: RTMPConnection?
  private var rtmpStream: RTMPStream?
  private var idleBitrateBps: Int = 2_500_000
  private var swingBitrateBps: Int = 4_500_000

  init(eventSink: FlutterEventSink?) {
    self.eventSink = eventSink
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    self.clipsDirectory = docs.appendingPathComponent("native_buffer", isDirectory: true)
    super.init()
    try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
  }

  func setEventSink(_ sink: FlutterEventSink?) {
    eventSink = sink
  }

  func attachPreviewContainer(_ view: PreviewContainerView) {
    previewContainer = view
    sessionQueue.async { [weak self] in
      self?.rebuildSessionIfNeeded()
    }
  }

  func detachPreviewContainer(_ view: PreviewContainerView) {
    if previewContainer === view {
      previewContainer = nil
    }
  }

  // MARK: - Method channel

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startPreview":
      previewRequested = true
      sessionQueue.async { [weak self] in self?.rebuildSessionIfNeeded() }
      result(nil)
    case "queryRecordingCapability":
      result(queryRecordingCapability())
    case "stopPreview":
      stopPreview()
      result(nil)
    case "startDetection":
      detectionEnabled = true
      result(nil)
    case "stopDetection":
      detectionEnabled = false
      result(nil)
    case "startBuffering":
      if let args = call.arguments as? [String: Any] {
        if let p = args["preRollMs"] as? Int { preRollMs = Int64(p) }
        if let p = args["postRollMs"] as? Int { postRollMs = Int64(p) }
        if let m = args["videoFpsMode"] as? String { videoFpsMode = m }
      }
      bufferingEnabled = true
      segmentDurationMs = computeSegmentSliceMs(preRollMs: preRollMs, postRollMs: postRollMs)
      sessionQueue.async { [weak self] in
        self?.rebuildSessionIfNeeded()
        self?.startNewSegmentIfBuffering()
      }
      result(nil)
    case "stopBuffering":
      stopBuffering(discardSegments: true)
      result(nil)
    case "saveBufferedClip":
      guard let args = call.arguments as? [String: Any],
            let outputPath = args["outputPath"] as? String,
            let trigger = args["triggerEpochMs"] as? NSNumber,
            let pr = args["preRollMs"] as? NSNumber,
            let po = args["postRollMs"] as? NSNumber
      else {
        result(FlutterError(code: "invalid_args", message: "saveBufferedClip", details: nil))
        return
      }
      preRollMs = pr.int64Value
      postRollMs = po.int64Value
      saveBufferedClip(outputPath: outputPath, triggerEpochMs: trigger.int64Value, result: result)
    case "switchCamera":
      lensPosition = lensPosition == .back ? .front : .back
      sessionQueue.async { [weak self] in
        self?.rebuildSessionIfNeeded()
        self?.sendCameraState()
      }
      result(["lensDirection": lensPosition == .back ? "back" : "front"])
    case "setZoomRatio":
      let ratio = (call.arguments as? NSNumber)?.floatValue ?? 1
      sessionQueue.async { [weak self] in
        self?.applyZoom(CGFloat(ratio))
      }
      result(nil)
    case "startRtmpStream":
      guard let args = call.arguments as? [String: Any],
            let url = args["url"] as? String, !url.isEmpty
      else {
        result(FlutterError(code: "invalid_args", message: "startRtmpStream requires url", details: nil))
        return
      }
      let idle = (args["idleBitrateBps"] as? NSNumber)?.intValue ?? 2_500_000
      let swing = (args["swingBitrateBps"] as? NSNumber)?.intValue ?? 4_500_000
      DispatchQueue.main.async { [weak self] in
        self?.startRtmp(url: url, idle: idle, swing: swing, result: result)
      }
    case "stopRtmpStream":
      DispatchQueue.main.async { [weak self] in
        self?.stopRtmp()
        self?.emitRtmp(state: "stopped")
        result(nil)
      }
    case "setRtmpSwingBitrate":
      let active = (call.arguments as? [String: Any])?["swingActive"] as? Bool ?? false
      DispatchQueue.main.async { [weak self] in
        guard let s = self?.rtmpStream else { return }
        let target = active ? (self?.swingBitrateBps ?? 4_500_000) : (self?.idleBitrateBps ?? 2_500_000)
        s.videoSettings.bitRate = target
      }
      result(nil)
    case "sendSwingMarker":
      guard let args = call.arguments as? [String: Any],
            let phase = args["phase"] as? String,
            let swingId = args["swingId"] as? String
      else {
        result(nil)
        return
      }
      let weight = (args["weight"] as? NSNumber)?.doubleValue ?? 0
      let w = min(max(weight, 0), 1)
      let score = (args["score"] as? NSNumber)?.doubleValue ?? weight
      let sc = min(max(score, 0), 1)
      let triggerEpochMs = (args["triggerEpochMs"] as? NSNumber)?.int64Value ?? 0
      let pr = (args["preRollMs"] as? NSNumber)?.intValue ?? 0
      let po = (args["postRollMs"] as? NSNumber)?.intValue ?? 0
      let endedAt = (args["endedAtEpochMs"] as? NSNumber)?.int64Value
      DispatchQueue.main.async { [weak self] in
        guard let stream = self?.rtmpStream else {
          result(nil)
          return
        }
        switch phase {
        case "start":
          let meta: [String: Any] = [
            "swingId": swingId,
            "weight": w,
            "score": sc,
            "triggerEpochMs": Double(triggerEpochMs),
            "preRollMs": Double(pr),
            "postRollMs": Double(po),
          ]
          stream.send(handlerName: "@setDataFrame", arguments: "onSwingStart", meta, isResetTimestamp: false)
        case "end":
          let meta: [String: Any] = [
            "swingId": swingId,
            "weight": w,
            "endedAtEpochMs": Double(endedAt ?? Int64(Date().timeIntervalSince1970 * 1000)),
          ]
          stream.send(handlerName: "@setDataFrame", arguments: "onSwingEnd", meta, isResetTimestamp: false)
        default:
          break
        }
        result(nil)
      }
    case "publishSwingClip":
      guard let args = call.arguments as? [String: Any],
            let url = args["url"] as? String, !url.isEmpty,
            let filePath = args["filePath"] as? String, !filePath.isEmpty,
            let swingId = args["swingId"] as? String
      else {
        result(FlutterError(code: "invalid_args", message: "publishSwingClip", details: nil))
        return
      }
      let weight = (args["weight"] as? NSNumber)?.doubleValue ?? 0
      publishSwingClip(url: url, filePath: filePath, swingId: swingId, weight: weight, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - RTMP

  private func startRtmp(url: String, idle: Int, swing: Int, result: @escaping FlutterResult) {
    idleBitrateBps = idle
    swingBitrateBps = swing
    stopBuffering(discardSegments: false)
    tearDownCaptureSession()

    guard let parts = RtmpUrl.split(url) else {
      result(FlutterError(code: "invalid_args", message: "Bad RTMP URL", details: nil))
      sessionQueue.async { [weak self] in self?.rebuildSessionIfNeeded() }
      return
    }

    guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lensPosition) else {
      result(FlutterError(code: "camera_unavailable", message: "No video device.", details: nil))
      sessionQueue.async { [weak self] in self?.rebuildSessionIfNeeded() }
      return
    }

    let conn = RTMPConnection()
    let stream = RTMPStream(connection: conn)
    stream.delegate = self
    rtmpConnection = conn
    rtmpStream = stream

    stream.videoSettings.videoSize = CGSize(width: 1280, height: 720)
    stream.videoSettings.bitRate = idle
    stream.attachCamera(cam)
    stream.attachAudio(AVCaptureDevice.default(for: .audio))

    emitRtmp(state: "connecting", message: url)
    conn.connect(parts.tcUrl, arguments: nil)
    stream.publish(parts.streamName)

    previewContainer?.showRtmpPreview(stream: stream)
    result(nil)
  }

  private func stopRtmp() {
    rtmpStream?.close()
    rtmpConnection?.close()
    rtmpStream = nil
    rtmpConnection = nil
    previewContainer?.clearPreview()
    sessionQueue.async { [weak self] in
      self?.rebuildSessionIfNeeded()
    }
  }

  private func emitRtmp(state: String, message: String? = nil, bitrate: Int? = nil) {
    var payload: [String: Any] = ["type": "rtmp_state", "state": state]
    if let message { payload["message"] = message }
    if let bitrate { payload["bitrateBps"] = bitrate }
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(payload)
    }
  }

  // MARK: - Session

  private func stopPreview() {
    previewRequested = false
    stopBuffering(discardSegments: true)
    tearDownCaptureSession()
  }

  private func tearDownCaptureSession() {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.movieOutput?.stopRecording()
      self.movieOutput = nil
      self.videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
      self.videoDataOutput = nil
      self.captureSession?.stopRunning()
      self.captureSession = nil
    }
  }

  private func rebuildSessionIfNeeded() {
    if rtmpStream != nil { return }
    guard previewRequested, previewContainer != nil else { return }

    let session = AVCaptureSession()
    session.sessionPreset = .hd1280x720

    guard let device = cameraDevice(),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input)
    else {
      sendError(code: "camera_input_failed", message: "Unable to open camera.")
      return
    }
    configureDeviceForCurrentVideoMode(device)
    session.addInput(input)

    if let audio = AVCaptureDevice.default(for: .audio),
       let audioIn = try? AVCaptureDeviceInput(device: audio),
       session.canAddInput(audioIn) {
      session.addInput(audioIn)
    }

    let movie = AVCaptureMovieFileOutput()
    if session.canAddOutput(movie) {
      session.addOutput(movie)
      movieOutput = movie
    }

    let videoOut = AVCaptureVideoDataOutput()
    videoOut.alwaysDiscardsLateVideoFrames = true
    videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    if session.canAddOutput(videoOut) {
      session.addOutput(videoOut)
      videoOut.setSampleBufferDelegate(self, queue: poseQueue)
      videoDataOutput = videoOut
    }

    captureSession = session
    session.startRunning()

    DispatchQueue.main.async { [weak self] in
      guard let self, let s = self.captureSession else { return }
      self.previewContainer?.showClassicPreview(session: s)
    }
    sendCameraState()
    sendBufferState()
  }

  private func cameraDevice() -> AVCaptureDevice? {
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lensPosition)
  }

  private func applyZoom(_ ratio: CGFloat) {
    guard let device = cameraDevice() else { return }
    do {
      try device.lockForConfiguration()
      let maxZ = device.activeFormat.videoMaxZoomFactor
      device.videoZoomFactor = min(max(1, ratio), maxZ)
      device.unlockForConfiguration()
    } catch {}
  }

  private func sendCameraState() {
    guard let device = cameraDevice() else { return }
    let minZ: CGFloat = 1
    let maxZ = device.activeFormat.videoMaxZoomFactor
    let z = device.videoZoomFactor
    emit(
      [
        "type": "camera_state",
        "lensDirection": lensPosition == .back ? "back" : "front",
        "minZoom": minZ,
        "maxZoom": maxZ,
        "zoom": z,
      ]
    )
  }

  private func sendBufferState() {
    emit(
      [
        "type": "buffer_state",
        "buffering": bufferingEnabled,
        "completedSegmentCount": completedSegments.count,
        "segmentSliceMs": Int(segmentDurationMs),
        "targetFps": nominalTargetFps(),
        "achievedFps": nil,
        "highSpeed": videoFpsMode != "standard",
      ]
    )
  }

  private func nominalTargetFps() -> Double {
    switch videoFpsMode {
    case "fps60": return 60
    case "fps120": return 120
    case "fps240": return 240
    case "maxSupported": return 240
    default: return 30
    }
  }

  private func recommendedModeForMaxFps(_ maxFps: Int) -> String {
    if maxFps >= 240 { return "fps240" }
    if maxFps >= 120 { return "fps120" }
    if maxFps >= 60 { return "fps60" }
    return "standard"
  }

  private func normalizedSupportedFps(for device: AVCaptureDevice) -> [Int] {
    var values = Set<Int>([30])
    for format in device.formats {
      for range in format.videoSupportedFrameRateRanges {
        let maxFps = Int(floor(range.maxFrameRate))
        if maxFps >= 240 {
          values.insert(240)
        } else if maxFps >= 120 {
          values.insert(120)
        } else if maxFps >= 60 {
          values.insert(60)
        }
      }
    }
    return values.sorted()
  }

  private func queryRecordingCapability() -> [String: Any] {
    guard let device = cameraDevice() else {
      return [
        "maxFps": 30,
        "supportedFps": [30],
        "recommendedVideoFpsMode": "standard",
        "source": "fallback",
        "message": "No camera device is available.",
      ]
    }
    let supported = normalizedSupportedFps(for: device)
    let maxFps = supported.max() ?? 30
    return [
      "maxFps": maxFps,
      "supportedFps": supported,
      "recommendedVideoFpsMode": recommendedModeForMaxFps(maxFps),
      "source": "avfoundation",
      "cameraLabel": lensPosition == .back ? "back camera" : "front camera",
    ]
  }

  private func targetFpsForCurrentDevice(_ device: AVCaptureDevice) -> Double {
    if videoFpsMode == "maxSupported" {
      return Double(normalizedSupportedFps(for: device).max() ?? 30)
    }
    return nominalTargetFps()
  }

  private func configureDeviceForCurrentVideoMode(_ device: AVCaptureDevice) {
    let targetFps = targetFpsForCurrentDevice(device)
    guard targetFps > 30 else { return }
    var selectedFormat: AVCaptureDevice.Format?
    var selectedMaxFps: Double = 0
    var selectedArea: Int32 = 0

    for format in device.formats {
      var supportsTarget = false
      var formatMaxFps: Double = 0
      for range in format.videoSupportedFrameRateRanges {
        formatMaxFps = max(formatMaxFps, range.maxFrameRate)
        if range.maxFrameRate >= targetFps && range.minFrameRate <= targetFps {
          supportsTarget = true
        }
      }
      if !supportsTarget {
        continue
      }
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let area = dimensions.width * dimensions.height
      if selectedFormat == nil ||
        formatMaxFps > selectedMaxFps ||
        (formatMaxFps == selectedMaxFps && area > selectedArea) {
        selectedFormat = format
        selectedMaxFps = formatMaxFps
        selectedArea = area
      }
    }
    guard let format = selectedFormat else { return }

    var locked = false
    do {
      try device.lockForConfiguration()
      locked = true
      device.activeFormat = format
      let frameDuration = CMTime(
        value: 1,
        timescale: CMTimeScale(Int32(targetFps.rounded()))
      )
      device.activeVideoMinFrameDuration = frameDuration
      device.activeVideoMaxFrameDuration = frameDuration
      device.unlockForConfiguration()
    } catch {
      if locked {
        device.unlockForConfiguration()
      }
    }
  }

  private func computeSegmentSliceMs(preRollMs: Int64, postRollMs: Int64) -> Int64 {
    let ring = preRollMs + postRollMs + 1500
    let slice = ring / 5
    return min(max(slice, 600), 2800)
  }

  private func stopBuffering(discardSegments: Bool) {
    bufferingEnabled = false
    segmentRotateWorkItem?.cancel()
    segmentRotateWorkItem = nil
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.movieOutput?.stopRecording()
      if discardSegments {
        for s in self.completedSegments {
          try? FileManager.default.removeItem(atPath: s.path)
        }
        self.completedSegments.removeAll()
      }
      self.sendBufferState()
    }
  }

  private func startNewSegmentIfBuffering() {
    guard bufferingEnabled, let movie = movieOutput, let session = captureSession, session.isRunning else {
      return
    }
    let name = "seg_\(Int(Date().timeIntervalSince1970 * 1000)).mov"
    let url = clipsDirectory.appendingPathComponent(name)
    currentRecordingURL = url
    currentSegmentStartEpochMs = Int64(Date().timeIntervalSince1970 * 1000)
    if movie.isRecording {
      movie.stopRecording()
    }
    movie.startRecording(to: url, recordingDelegate: self)
    scheduleSegmentRotation()
  }

  private func scheduleSegmentRotation() {
    segmentRotateWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.rotateSegment()
    }
    segmentRotateWorkItem = work
    sessionQueue.asyncAfter(deadline: .now() + .milliseconds(Int(segmentDurationMs)), execute: work)
  }

  private func rotateSegment() {
    guard bufferingEnabled else { return }
    movieOutput?.stopRecording()
  }

  // MARK: - AVCaptureFileOutputRecordingDelegate

  func fileOutput(
    _ output: AVCaptureFileOutput,
    didFinishRecordingTo outputFileURL: URL,
    from connections: [AVCaptureConnection],
    error: Error?
  ) {
    sessionQueue.async { [weak self] in
      guard let self else { return }
      let end = Int64(Date().timeIntervalSince1970 * 1000)
      let start = self.currentSegmentStartEpochMs
      if error == nil, FileManager.default.fileExists(atPath: outputFileURL.path) {
        self.completedSegments.append(
          BufferedSegment(path: outputFileURL.path, startEpochMs: start, endEpochMs: end)
        )
        self.pruneSegments(nowEpochMs: end)
        self.sendBufferState()
      }
      if self.bufferingEnabled {
        self.startNewSegmentIfBuffering()
      }
    }
  }

  private func pruneSegments(nowEpochMs: Int64) {
    let horizon = preRollMs + postRollMs + 2000
    let cutoff = nowEpochMs - horizon
    completedSegments.removeAll { segment in
      if segment.endEpochMs < cutoff {
        try? FileManager.default.removeItem(atPath: segment.path)
        return true
      }
      return false
    }
  }

  // MARK: - Save clip

  private func saveBufferedClip(outputPath: String, triggerEpochMs: Int64, result: @escaping FlutterResult) {
    guard bufferingEnabled else {
      result(FlutterError(code: "buffer_inactive", message: "Rolling buffer is not active.", details: nil))
      return
    }
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.movieOutput?.stopRecording()
      let clipStart = triggerEpochMs - self.preRollMs
      let clipEnd = triggerEpochMs + self.postRollMs
      let selected = self.completedSegments.filter {
        $0.endEpochMs > clipStart && $0.startEpochMs < clipEnd
      }
      if selected.isEmpty {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "buffer_empty",
              message: "No buffered segments overlap the requested clip window.",
              details: nil
            )
          )
        }
        return
      }
      self.mergeSegments(segments: selected, outputPath: outputPath, clipStart: clipStart, clipEnd: clipEnd) { ok, err in
        DispatchQueue.main.async {
          if ok {
            result(outputPath)
          } else {
            result(FlutterError(code: "buffer_export_failed", message: err ?? "export failed", details: nil))
          }
        }
      }
    }
  }

  private func mergeSegments(
    segments: [BufferedSegment],
    outputPath: String,
    clipStart: Int64,
    clipEnd: Int64,
    done: @escaping (Bool, String?) -> Void
  ) {
    writerQueue.async {
      let composition = AVMutableComposition()
      guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        done(false, "no video track")
        return
      }
      let hasAnyAudio = segments.contains { seg in
        let a = AVURLAsset(url: URL(fileURLWithPath: seg.path))
        return a.tracks(withMediaType: .audio).first != nil
      }
      let audioTrack: AVMutableCompositionTrack? = hasAnyAudio
        ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        : nil

      var cursor = CMTime.zero
      for seg in segments.sorted(by: { $0.startEpochMs < $1.startEpochMs }) {
        let url = URL(fileURLWithPath: seg.path)
        let asset = AVURLAsset(url: url)
        guard let srcVideo = asset.tracks(withMediaType: .video).first else { continue }

        let wallT0 = max(clipStart, seg.startEpochMs)
        let wallT1 = min(clipEnd, seg.endEpochMs)
        if wallT1 <= wallT0 { continue }

        let local0 = Double(wallT0 - seg.startEpochMs) / 1000.0
        let local1 = Double(wallT1 - seg.startEpochMs) / 1000.0
        let rangeStart = CMTime(seconds: local0, preferredTimescale: 600)
        let rangeDur = CMTime(seconds: local1 - local0, preferredTimescale: 600)
        if rangeDur.seconds <= 0 { continue }
        let range = CMTimeRange(start: rangeStart, duration: rangeDur)

        do {
          try videoTrack.insertTimeRange(range, of: srcVideo, at: cursor)
          if let srcAudio = asset.tracks(withMediaType: .audio).first, let at = audioTrack {
            try at.insertTimeRange(range, of: srcAudio, at: cursor)
          }
          cursor = CMTimeAdd(cursor, rangeDur)
        } catch {
          done(false, error.localizedDescription)
          return
        }
      }

      guard cursor.seconds > 0 else {
        done(false, "empty composition")
        return
      }

      guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        done(false, "export session")
        return
      }
      let out = URL(fileURLWithPath: outputPath)
      try? FileManager.default.removeItem(at: out)
      export.outputURL = out
      export.outputFileType = .mp4
      export.exportAsynchronously {
        if export.status == .completed {
          done(true, nil)
        } else {
          done(false, export.error?.localizedDescription)
        }
      }
    }
  }

  // MARK: - Clip RTMP

  private func publishSwingClip(
    url: String,
    filePath: String,
    swingId: String,
    weight: Double,
    result: @escaping FlutterResult
  ) {
    writerQueue.async { [weak self] in
      guard let self,
            let parts = RtmpUrl.split(url)
      else {
        DispatchQueue.main.async {
          result(FlutterError(code: "clip_rtmp_failed", message: "bad url", details: nil))
        }
        return
      }
      let asset = AVURLAsset(url: URL(fileURLWithPath: filePath))
      let durationMs = Int(CMTimeGetSeconds(asset.duration) * 1000)
      let w = min(max(weight, 0), 1)

      let conn = RTMPConnection()
      let stream = RTMPStream(connection: conn)
      stream.delegate = nil
      stream.videoSettings.videoSize = CGSize(width: 1280, height: 720)

      conn.connect(parts.tcUrl, arguments: nil)
      stream.publish(parts.streamName)

      // Wait briefly for publish handshake then send onSwingClip metadata
      Thread.sleep(forTimeInterval: 0.6)
      let meta: [String: Any] = [
        "swingId": swingId,
        "weight": w,
        "durationMs": Double(durationMs),
        "filename": (filePath as NSString).lastPathComponent,
      ]
      stream.send(handlerName: "@setDataFrame", arguments: "onSwingClip", meta, isResetTimestamp: false)

      let reader: AVAssetReader
      do {
        reader = try AVAssetReader(asset: asset)
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "clip_rtmp_failed", message: error.localizedDescription, details: nil))
        }
        return
      }

      if let vTrack = asset.tracks(withMediaType: .video).first {
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        if reader.canAdd(vOut) {
          reader.add(vOut)
        }
      }
      if let aTrack = asset.tracks(withMediaType: .audio).first {
        let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
        if reader.canAdd(aOut) {
          reader.add(aOut)
        }
      }

      guard reader.startReading() else {
        DispatchQueue.main.async {
          result(FlutterError(code: "clip_rtmp_failed", message: "reader failed", details: nil))
        }
        return
      }

      readLoop: while reader.status == .reading {
        var progressed = false
        for output in reader.outputs {
          while let sb = output.copyNextSampleBuffer() {
            stream.append(sb)
            progressed = true
          }
        }
        if !progressed {
          break readLoop
        }
      }
      stream.close()
      conn.close()
      DispatchQueue.main.async { result(nil) }
    }
  }

  private func emit(_ map: [String: Any]) {
    DispatchQueue.main.async { [weak self] in
      self?.eventSink?(map)
    }
  }

  private func sendError(code: String, message: String) {
    emit(["type": "error", "code": code, "message": message])
  }

  deinit {
    stopRtmp()
  }
}

// MARK: - HaishinKit IOStreamDelegate

extension NativeCapturePipeline: IOStreamDelegate {
  func stream(_ stream: IOStream, track: UInt8, didInput buffer: AVAudioBuffer, when: AVAudioTime) {}

  func stream(_ stream: IOStream, track: UInt8, didInput buffer: CMSampleBuffer) {}

  func stream(_ stream: IOStream, videoErrorOccurred error: IOVideoUnitError) {}

  func stream(_ stream: IOStream, audioErrorOccurred error: IOAudioUnitError) {}

  func stream(_ stream: IOStream, willChangeReadyState state: IOStream.ReadyState) {}

  func stream(_ stream: IOStream, didChangeReadyState state: IOStream.ReadyState) {
    if case .publishing = state {
      emitRtmp(state: "live", bitrate: idleBitrateBps)
    }
  }

  #if os(iOS) || os(tvOS)
  func stream(_ stream: IOStream, sessionWasInterrupted session: AVCaptureSession, reason: AVCaptureSession.InterruptionReason?) {}

  func stream(_ stream: IOStream, sessionInterruptionEnded session: AVCaptureSession) {}
  #endif
}

// MARK: - Video frames → Vision pose

@available(iOS 14.0, *)
extension NativeCapturePipeline: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard detectionEnabled, !isProcessingPose else { return }
    isProcessingPose = true
    defer { isProcessingPose = false }
    let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
    let request = VNDetectHumanBodyPoseRequest()
    do {
      try handler.perform([request])
    } catch {
      return
    }
    let obs = (request.results as? [VNHumanBodyPoseObservation])?.first
    emitPose(observation: obs, buffer: sampleBuffer)
  }

  private func emitPose(observation: VNHumanBodyPoseObservation?, buffer: CMSampleBuffer) {
    guard let pb = CMSampleBufferGetImageBuffer(buffer) else {
      return
    }
    let w = CGFloat(CVPixelBufferGetWidth(pb))
    let h = CGFloat(CVPixelBufferGetHeight(pb))

    var landmarks: [[String: Any]] = []
    if let observation {
      let joints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .leftHip, .rightHip, .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
      ]
      let names: [VNHumanBodyPoseObservation.JointName: String] = [
        .nose: "nose",
        .leftShoulder: "leftShoulder",
        .rightShoulder: "rightShoulder",
        .leftElbow: "leftElbow",
        .rightElbow: "rightElbow",
        .leftWrist: "leftWrist",
        .rightWrist: "rightWrist",
        .leftHip: "leftHip",
        .rightHip: "rightHip",
        .leftKnee: "leftKnee",
        .rightKnee: "rightKnee",
        .leftAnkle: "leftAnkle",
        .rightAnkle: "rightAnkle",
      ]
      for j in joints {
        guard let p = try? observation.recognizedPoint(j), p.confidence > 0.1 else { continue }
        let nx = lensPosition == .front ? (1 - Double(p.location.x)) : Double(p.location.x)
        let ny = Double(1 - p.location.y)
        landmarks.append([
          "name": names[j] ?? "",
          "x": nx,
          "y": ny,
          "confidence": Double(p.confidence),
        ])
      }
    }

    emit([
      "type": "pose",
      "timestampMs": Int64(Date().timeIntervalSince1970 * 1000),
      "landmarks": landmarks,
    ])
  }
}
