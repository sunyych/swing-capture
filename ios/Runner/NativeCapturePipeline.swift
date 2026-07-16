import AVFoundation
import CoreMedia
import CoreVideo
import Flutter
import Foundation
import HaishinKit
import UIKit
import Vision

private struct ZoomLens {
  let device: AVCaptureDevice
  let baseZoom: CGFloat
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

final class NativeCapturePipeline: NSObject {
  private var eventSink: FlutterEventSink?
  private var methodChannel: FlutterMethodChannel?

  private let clipsDirectory: URL
  private let sessionQueue = DispatchQueue(label: "com.swingcapture.session")
  private let writerQueue = DispatchQueue(label: "com.swingcapture.writer")
  private let poseQueue = DispatchQueue(label: "com.swingcapture.pose")
  private let videoOutputQueue = DispatchQueue(
    label: "com.swingcapture.video_output",
    qos: .userInteractive
  )
  private let poseStateLock = NSLock()

  private var captureSession: AVCaptureSession?
  private var videoDataOutput: AVCaptureVideoDataOutput?
  private var previewContainer: PreviewContainerView?
  private let rollingBuffer = IOSRustEncodedRollingBuffer()
  private lazy var videoEncoder = IOSVideoToolboxEncoder(
    outputHandler: { [weak self] sampleBuffer in
      self?.handleEncodedSample(sampleBuffer)
    },
    errorHandler: { [weak self] error in
      self?.handleEncoderFailure(error)
    }
  )

  private var lensPosition: AVCaptureDevice.Position = .back
  private var activeCameraUniqueID: String?
  private var requestedZoomRatio: CGFloat = 1
  private var previewRequested = false
  private var detectionEnabled = false
  private var bufferingEnabled = false
  private var preRollMs: Int64 = 3000
  private var postRollMs: Int64 = 3000
  private var videoFpsMode: String = "fps120"
  private var activeProfile: IOSCaptureProfile?
  private var activeCodec = "h264"
  private var nextFallbackIndex = 0
  private var profileValidationComplete = false
  private var fallbackInProgress = false
  private var encodedSampleSeen = false
  private var firstEncodedSampleEmitted = false
  private var encoderWatchdog: DispatchWorkItem?
  private var lastBufferStatePtsUs: Int64 = -1
  private var lastPosePtsUs: Int64 = -1
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
      nextFallbackIndex = 0
      firstEncodedSampleEmitted = false
      encodedSampleSeen = false
      profileValidationComplete = false
      sendBufferState(segmentStarting: true)
      sessionQueue.async { [weak self] in
        self?.rebuildSessionIfNeeded()
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
      saveBufferedClip(
        outputPath: outputPath,
        triggerEpochMs: trigger.int64Value,
        result: result
      )
    case "switchCamera":
      lensPosition = lensPosition == .back ? .front : .back
      activeCameraUniqueID = nil
      requestedZoomRatio = 1
      nextFallbackIndex = 0
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

    guard let cam = cameraDevice() else {
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
      self.tearDownCaptureSessionOnSessionQueue()
    }
  }

  private func tearDownCaptureSessionOnSessionQueue() {
    encoderWatchdog?.cancel()
    encoderWatchdog = nil
    videoEncoder.stop()
    videoDataOutput?.setSampleBufferDelegate(nil, queue: nil)
    videoDataOutput = nil
    captureSession?.stopRunning()
    captureSession = nil
    activeProfile = nil
  }

  private func rebuildSessionIfNeeded() {
    if rtmpStream != nil { return }
    guard previewRequested, previewContainer != nil else { return }
    tearDownCaptureSessionOnSessionQueue()

    let session = AVCaptureSession()
    session.beginConfiguration()
    session.sessionPreset = .inputPriority

    guard let device = cameraDevice(),
          let input = try? AVCaptureDeviceInput(device: device),
          session.canAddInput(input)
    else {
      session.commitConfiguration()
      sendError(code: "camera_input_failed", message: "Unable to open camera.")
      return
    }
    session.addInput(input)
    guard configureDevice(device, forBuffering: bufferingEnabled) else {
      session.commitConfiguration()
      sendError(
        code: "capture_profile_unavailable",
        message: "None of 1080p120, 720p120, 1080p60, 720p60, or 1080p30 could start."
      )
      return
    }
    applyZoom(to: device)

    let videoOut = AVCaptureVideoDataOutput()
    videoOut.alwaysDiscardsLateVideoFrames = !bufferingEnabled
    videoOut.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
    ]
    if session.canAddOutput(videoOut) {
      session.addOutput(videoOut)
      videoOut.setSampleBufferDelegate(self, queue: videoOutputQueue)
      videoDataOutput = videoOut
    } else {
      session.commitConfiguration()
      videoEncoder.stop()
      sendError(
        code: "yuv_output_unavailable",
        message: "AVFoundation could not add the NV12/YUV video output."
      )
      return
    }
    configureVideoConnection(videoOut.connection(with: .video))
    session.commitConfiguration()

    captureSession = session
    session.startRunning()

    DispatchQueue.main.async { [weak self] in
      guard let self, let s = self.captureSession else { return }
      self.previewContainer?.showClassicPreview(session: s)
    }
    sendCameraState()
    sendBufferState(segmentStarting: bufferingEnabled)
    if bufferingEnabled {
      scheduleEncoderWatchdog(for: activeProfile)
    }
  }

  private func cameraDevice() -> AVCaptureDevice? {
    if let activeCameraUniqueID,
       let active = zoomLenses(for: lensPosition)
        .first(where: { $0.device.uniqueID == activeCameraUniqueID })?.device {
      return active
    }
    guard let lens = lensForLogicalZoom(requestedZoomRatio) else {
      return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: lensPosition)
    }
    activeCameraUniqueID = lens.device.uniqueID
    return lens.device
  }

  private func zoomLenses(for position: AVCaptureDevice.Position) -> [ZoomLens] {
    let deviceTypes: [AVCaptureDevice.DeviceType] = [
      .builtInUltraWideCamera,
      .builtInWideAngleCamera,
      .builtInTelephotoCamera,
    ]
    let devices = AVCaptureDevice.DiscoverySession(
      deviceTypes: deviceTypes,
      mediaType: .video,
      position: position
    ).devices
    guard !devices.isEmpty else { return [] }
    let reference = devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? devices.first!
    let referenceFov = max(CGFloat(reference.activeFormat.videoFieldOfView), 1)
    return devices
      .map { device in
        let fov = max(CGFloat(device.activeFormat.videoFieldOfView), 1)
        let base = tan(referenceFov * .pi / 360) / tan(fov * .pi / 360)
        return ZoomLens(device: device, baseZoom: max(base, 0.1))
      }
      .sorted { $0.baseZoom < $1.baseZoom }
  }

  private func lensForLogicalZoom(_ ratio: CGFloat) -> ZoomLens? {
    let lenses = zoomLenses(for: lensPosition)
    guard !lenses.isEmpty else { return nil }
    return lenses
      .filter { $0.baseZoom <= ratio + 0.001 }
      .max { $0.baseZoom < $1.baseZoom }
      ?? lenses.first
  }

  private func logicalZoomRange() -> (min: CGFloat, max: CGFloat) {
    let lenses = zoomLenses(for: lensPosition)
    guard !lenses.isEmpty else { return (1, 1) }
    let minZoom = lenses.map(\.baseZoom).min() ?? 1
    let maxZoom = lenses
      .map { $0.baseZoom * max($0.device.activeFormat.videoMaxZoomFactor, 1) }
      .max() ?? minZoom
    return (minZoom, max(maxZoom, minZoom))
  }

  private func applyZoom(_ ratio: CGFloat) {
    let range = logicalZoomRange()
    requestedZoomRatio = min(max(ratio, range.min), range.max)
    guard let lens = lensForLogicalZoom(requestedZoomRatio) else { return }
    let nextCameraID = lens.device.uniqueID
    if nextCameraID != activeCameraUniqueID {
      activeCameraUniqueID = nextCameraID
      rebuildSessionIfNeeded()
      return
    }
    applyZoom(to: lens.device)
    sendCameraState()
  }

  private func applyZoom(to device: AVCaptureDevice) {
    let lenses = zoomLenses(for: lensPosition)
    let baseZoom = lenses
      .first(where: { $0.device.uniqueID == device.uniqueID })?
      .baseZoom ?? 1
    let maxZoom = max(device.activeFormat.videoMaxZoomFactor, 1)
    let localZoom = min(max(requestedZoomRatio / baseZoom, 1), maxZoom)
    do {
      try device.lockForConfiguration()
      device.videoZoomFactor = localZoom
      device.unlockForConfiguration()
    } catch {}
  }

  private func sendCameraState() {
    let range = logicalZoomRange()
    requestedZoomRatio = min(max(requestedZoomRatio, range.min), range.max)
    emit(
      [
        "type": "camera_state",
        "lensDirection": lensPosition == .back ? "back" : "front",
        "minZoom": range.min,
        "maxZoom": range.max,
        "zoom": requestedZoomRatio,
      ]
    )
  }

  private func sendBufferState(segmentStarting: Bool = false) {
    let metrics = rollingBuffer.metrics()
    let profile = activeProfile
    var payload: [String: Any] = [
      "type": "buffer_state",
      "buffering": bufferingEnabled,
      "completedSegmentCount": 0,
      "segmentSliceMs": 0,
      "queueFrameCapacity": max((profile?.fps ?? 30) * rollingWindowSeconds(), 1),
      "queueDurationMs": rollingWindowMilliseconds(),
      "bufferedFrameCount": Int(metrics.sampleCount),
      "bufferedDurationMs": Int(metrics.durationUs / 1000),
      "bufferedBytes": Int(clamping: metrics.sizeBytes),
      "targetFps": profile?.fps ?? Int(nominalTargetFps()),
      "highSpeed": (profile?.fps ?? 30) >= 60,
      "segmentRecording": bufferingEnabled && metrics.sampleCount > 0,
      "segmentStarting": bufferingEnabled && (segmentStarting || metrics.sampleCount == 0),
      "codec": activeCodec,
      "bufferOwner": "rust",
    ]
    if let profile {
      payload["profileWidth"] = Int(profile.width)
      payload["profileHeight"] = Int(profile.height)
    }
    if let achievedFps = metrics.achievedFps {
      payload["achievedFps"] = achievedFps
    }
    emit(payload)
  }

  private func nominalTargetFps() -> Double {
    switch videoFpsMode {
    case "fps60": return 60
    case "fps120": return 120
    case "fps240": return 120
    case "maxSupported": return 120
    default: return 30
    }
  }

  private func recommendedModeForMaxFps(_ maxFps: Int) -> String {
    if maxFps >= 120 { return "fps120" }
    if maxFps >= 60 { return "fps60" }
    return "standard"
  }

  private func normalizedSupportedFps(for device: AVCaptureDevice) -> [Int] {
    var values = Set<Int>([30])
    for format in device.formats {
      for range in format.videoSupportedFrameRateRanges {
        let maxFps = Int(floor(range.maxFrameRate))
        if maxFps >= 60 {
          values.insert(60)
        }
        if maxFps >= 120 {
          values.insert(120)
        }
      }
    }
    return values.sorted()
  }

  private func queryRecordingCapability() -> [String: Any] {
    var seen = Set<String>()
    let lenses = [AVCaptureDevice.Position.back, .front]
      .flatMap { zoomLenses(for: $0) }
      .filter { lens in
        if seen.contains(lens.device.uniqueID) {
          return false
        }
        seen.insert(lens.device.uniqueID)
        return true
      }
    guard !lenses.isEmpty else {
      return [
        "maxFps": 30,
        "supportedFps": [30],
        "recommendedVideoFpsMode": "standard",
        "source": "fallback",
        "message": "No camera device is available.",
      ]
    }
    let lensCapabilities = lenses.map { lens -> [String: Any] in
      let supported = normalizedSupportedFps(for: lens.device)
      let maxFps = supported.max() ?? 30
      return [
        "cameraId": lens.device.uniqueID,
        "lensDirection": lens.device.position == .front ? "front" : "back",
        "cameraLabel": cameraCapabilityLabel(for: lens),
        "maxFps": maxFps,
        "supportedFps": supported,
      ]
    }
    let activeDevice = cameraDevice() ?? lenses[0].device
    let supported = normalizedSupportedFps(for: activeDevice)
    let maxFps = supported.max() ?? 30
    return [
      "maxFps": maxFps,
      "supportedFps": supported,
      "recommendedVideoFpsMode": recommendedModeForMaxFps(maxFps),
      "source": "avfoundation",
      "cameraLabel": activeDevice.localizedName,
      "lensCapabilities": lensCapabilities,
    ]
  }

  private func cameraCapabilityLabel(for lens: ZoomLens) -> String {
    if lens.device.position == .front {
      return "front camera"
    }
    return String(format: "back %.1fx lens", Double(lens.baseZoom))
  }

  private func configureDevice(
    _ device: AVCaptureDevice,
    forBuffering: Bool
  ) -> Bool {
    let profiles: [IOSCaptureProfile]
    if forBuffering {
      profiles = Array(iosCaptureFallbackLadder.dropFirst(nextFallbackIndex))
    } else {
      profiles = [IOSCaptureProfile(width: 1920, height: 1080, fps: 30)]
    }

    for profile in profiles {
      let ladderIndex = iosCaptureFallbackLadder.firstIndex(of: profile) ?? 0
      guard let format = captureFormat(for: profile, on: device) else {
        if forBuffering {
          emitProfileFallback(
            from: profile,
            reason: "AVCaptureDevice has no exact \(profile) NV12-capable format."
          )
        }
        continue
      }
      do {
        try apply(profile: profile, format: format, to: device)
        if forBuffering {
          let bitrate = bitrateBps(for: profile)
          let codec = try videoEncoder.start(profile: profile, bitrateBps: bitrate)
          try rollingBuffer.reset(
            windowUs: Int64(rollingWindowMilliseconds()) * 1000,
            profile: profile,
            codec: codec,
            bitrateBps: bitrate,
            orientationDegrees: videoOrientationDegrees()
          )
          activeCodec = codec
          nextFallbackIndex = ladderIndex
          encodedSampleSeen = false
          firstEncodedSampleEmitted = false
          profileValidationComplete = false
          lastBufferStatePtsUs = -1
        }
        activeProfile = profile
        return true
      } catch {
        videoEncoder.stop()
        rollingBuffer.clear()
        if forBuffering {
          emitProfileFallback(from: profile, reason: error.localizedDescription)
          nextFallbackIndex = ladderIndex + 1
        }
      }
    }
    return false
  }

  private func apply(
    profile: IOSCaptureProfile,
    format: AVCaptureDevice.Format,
    to device: AVCaptureDevice
  ) throws {
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    device.activeFormat = format
    let duration = CMTime(value: 1, timescale: CMTimeScale(profile.fps))
    device.activeVideoMinFrameDuration = duration
    device.activeVideoMaxFrameDuration = duration
  }

  private func bitrateBps(for profile: IOSCaptureProfile) -> Int {
    let pixels = Double(profile.width * profile.height)
    let scale = pixels / (1920 * 1080) * (Double(profile.fps) / 30)
    return min(max(Int((12_000_000 * scale).rounded()), 8_000_000), 80_000_000)
  }

  private func rollingWindowMilliseconds() -> Int {
    max(Int(preRollMs + postRollMs), 4000)
  }

  private func rollingWindowSeconds() -> Int {
    max(Int(ceil(Double(rollingWindowMilliseconds()) / 1000)), 1)
  }

  private func emitProfileFallback(from profile: IOSCaptureProfile, reason: String) {
    let next = iosCaptureFallbackLadder
      .drop(while: { $0 != profile })
      .dropFirst()
      .first
    var payload: [String: Any] = [
      "type": "ProfileFallback",
      "from": profile.description,
      "reason": reason,
    ]
    if let next {
      payload["to"] = next.description
    }
    emit(payload)
  }

  private func configureVideoConnection(_ connection: AVCaptureConnection?) {
    guard let connection else { return }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = switch videoOrientationDegrees() {
      case 0: .landscapeRight
      case 180: .landscapeLeft
      case 270: .portraitUpsideDown
      default: .portrait
      }
    }
    if connection.isVideoMirroringSupported {
      connection.isVideoMirrored = lensPosition == .front
    }
  }

  private func videoOrientationDegrees() -> Int {
    switch UIDevice.current.orientation {
    case .landscapeLeft: return 0
    case .landscapeRight: return 180
    case .portraitUpsideDown: return 270
    default: return 90
    }
  }

  private func handleEncodedSample(_ sampleBuffer: CMSampleBuffer) {
    guard bufferingEnabled, rollingBuffer.push(sampleBuffer) else { return }
    let metrics = rollingBuffer.metrics()
    let ptsUs = CMTimeConvertScale(
      CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
      timescale: 1_000_000,
      method: .default
    ).value

    if !firstEncodedSampleEmitted {
      firstEncodedSampleEmitted = true
      let profile = activeProfile
      emit([
        "type": "CaptureStarted",
        "width": profile.map { Int($0.width) } ?? 0,
        "height": profile.map { Int($0.height) } ?? 0,
        "fps": profile?.fps ?? 0,
        "codec": activeCodec,
        "bufferOwner": "rust",
      ])
    }
    if lastBufferStatePtsUs < 0 || ptsUs - lastBufferStatePtsUs >= 500_000 {
      lastBufferStatePtsUs = ptsUs
      sendBufferState()
    }

    let profile = activeProfile
    sessionQueue.async { [weak self] in
      guard let self, self.bufferingEnabled, self.activeProfile == profile else { return }
      self.encodedSampleSeen = true
      self.encoderWatchdog?.cancel()
      self.encoderWatchdog = nil
      guard !self.profileValidationComplete,
            metrics.durationUs >= 1_500_000,
            let achieved = metrics.achievedFps,
            let profile
      else {
        return
      }
      self.profileValidationComplete = true
      let minimum = minimumAcceptedIOSCaptureFps(for: profile)
      if achieved < minimum {
        self.fallbackFromActiveProfile(
          reason: String(
            format: "Measured encoded throughput %.1ffps is below %.1ffps.",
            achieved,
            minimum
          )
        )
      }
    }
  }

  private func handleEncoderFailure(_ error: Error) {
    sessionQueue.async { [weak self] in
      guard let self, self.bufferingEnabled else { return }
      self.fallbackFromActiveProfile(reason: error.localizedDescription)
    }
  }

  private func scheduleEncoderWatchdog(for profile: IOSCaptureProfile?) {
    encoderWatchdog?.cancel()
    guard let profile else { return }
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self,
            self.bufferingEnabled,
            self.activeProfile == profile,
            !self.encodedSampleSeen
      else {
        return
      }
      self.fallbackFromActiveProfile(
        reason: "No VideoToolbox encoded sample arrived within 2.5 seconds."
      )
    }
    encoderWatchdog = watchdog
    sessionQueue.asyncAfter(deadline: .now() + .milliseconds(2500), execute: watchdog)
  }

  private func fallbackFromActiveProfile(reason: String) {
    guard !fallbackInProgress, let profile = activeProfile else { return }
    let currentIndex = iosCaptureFallbackLadder.firstIndex(of: profile) ?? nextFallbackIndex
    let nextIndex = currentIndex + 1
    guard nextIndex < iosCaptureFallbackLadder.count else {
      profileValidationComplete = true
      sendError(
        code: "capture_throughput_degraded",
        message: "1080p30 fallback is active but degraded: \(reason)"
      )
      return
    }
    fallbackInProgress = true
    emitProfileFallback(from: profile, reason: reason)
    nextFallbackIndex = nextIndex
    rebuildSessionIfNeeded()
    fallbackInProgress = false
  }

  private func stopBuffering(discardSegments: Bool) {
    bufferingEnabled = false
    encoderWatchdog?.cancel()
    encoderWatchdog = nil
    sessionQueue.async { [weak self] in
      guard let self else { return }
      self.videoEncoder.stop()
      self.rollingBuffer.clear()
      self.activeProfile = nil
      self.firstEncodedSampleEmitted = false
      self.encodedSampleSeen = false
      self.sendBufferState()
      if self.previewRequested, self.rtmpStream == nil {
        self.rebuildSessionIfNeeded()
      }
    }
  }

  // MARK: - Save clip

  private func saveBufferedClip(outputPath: String, triggerEpochMs: Int64, result: @escaping FlutterResult) {
    guard bufferingEnabled else {
      result(FlutterError(code: "buffer_inactive", message: "Rolling buffer is not active.", details: nil))
      return
    }
    guard let snapshot = rollingBuffer.snapshot() else {
      result(
        FlutterError(
          code: "buffer_empty",
          message: "Rust rolling buffer has no keyframe-backed encoded video yet.",
          details: ["triggerEpochMs": triggerEpochMs]
        )
      )
      return
    }
    IOSCompressedClipWriter.write(
      snapshot: snapshot,
      outputURL: URL(fileURLWithPath: outputPath),
      queue: writerQueue
    ) { writeResult in
      DispatchQueue.main.async {
        switch writeResult {
        case .success(let url):
          result(url.path)
        case .failure(let error):
          result(
            FlutterError(
              code: "buffer_export_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
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
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if bufferingEnabled, let profile = activeProfile {
      let duration = CMSampleBufferGetDuration(sampleBuffer)
      videoEncoder.encode(
        pixelBuffer: pixelBuffer,
        presentationTime: presentationTime,
        duration: duration.isValid && duration.value > 0
          ? duration
          : CMTime(value: 1, timescale: CMTimeScale(profile.fps))
      )
    }

    guard detectionEnabled else { return }
    let ptsUs = CMTimeConvertScale(
      presentationTime,
      timescale: 1_000_000,
      method: .default
    ).value
    guard lastPosePtsUs < 0 || ptsUs - lastPosePtsUs >= 50_000 else { return }
    lastPosePtsUs = ptsUs

    poseStateLock.lock()
    guard !isProcessingPose else {
      poseStateLock.unlock()
      return
    }
    isProcessingPose = true
    poseStateLock.unlock()

    poseQueue.async { [weak self] in
      guard let self else { return }
      defer {
        self.poseStateLock.lock()
        self.isProcessingPose = false
        self.poseStateLock.unlock()
      }
      let handler = VNImageRequestHandler(
        cvPixelBuffer: pixelBuffer,
        orientation: .up,
        options: [:]
      )
      let request = VNDetectHumanBodyPoseRequest()
      do {
        try handler.perform([request])
      } catch {
        return
      }
      let observation = (request.results as? [VNHumanBodyPoseObservation])?.first
      self.emitPose(
        observation: observation,
        pixelBuffer: pixelBuffer,
        timestampMs: Int64(Date().timeIntervalSince1970 * 1000)
      )
    }
  }

  private func emitPose(
    observation: VNHumanBodyPoseObservation?,
    pixelBuffer: CVPixelBuffer,
    timestampMs: Int64
  ) {
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
      "timestampMs": timestampMs,
      "landmarks": landmarks,
      "sourceWidth": CVPixelBufferGetWidth(pixelBuffer),
      "sourceHeight": CVPixelBufferGetHeight(pixelBuffer),
      "pixelFormat": "nv12",
    ])
  }
}
