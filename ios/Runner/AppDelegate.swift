import AVFoundation
import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  private let captureChannelName = "swingcapture/capture"
  private let captureEventsName = "swingcapture/capture_events"
  private let dualCameraBleChannelName = "swingcapture/dual_camera_ble"
  private let dualCameraBleEventsName = "swingcapture/dual_camera_ble_events"
  private let previewTypeId = "swingcapture/native_preview"

  private var capturePipeline: NativeCapturePipeline?
  private let dualCameraBleControl = DualCameraBleControl()
  private weak var flutterViewController: FlutterViewController?
  private var pendingVideoPickResult: FlutterResult?
  private var pendingVideoPickDestinationDirectory: String?
  private var pendingVideoPickFilePrefix: String?
  private var captureEventSink: FlutterEventSink?
  private let videoImportQueue = DispatchQueue(label: "com.swingcapture.video_import", qos: .userInitiated)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
    flutterViewController = controller

    let pipeline = NativeCapturePipeline(eventSink: nil)
    capturePipeline = pipeline

    let methodChannel = FlutterMethodChannel(
      name: captureChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    methodChannel.setMethodCallHandler { [weak self] call, result in
      if call.method == "saveClip" {
        self?.saveClip(call: call, result: result)
        return
      }
      if call.method == "pickVideoFromLibrary" {
        self?.pickVideoFromLibrary(call: call, result: result)
        return
      }
      if call.method == "readVideoMetadata" {
        self?.readVideoMetadata(call: call, result: result)
        return
      }
      if call.method == "extractPoseFramesFromVideo" {
        self?.extractPoseFramesFromVideo(call: call, result: result)
        return
      }
      pipeline.handle(call, result: result)
    }

    let bleMethodChannel = FlutterMethodChannel(
      name: dualCameraBleChannelName,
      binaryMessenger: controller.binaryMessenger
    )
    bleMethodChannel.setMethodCallHandler { [weak self] call, result in
      self?.dualCameraBleControl.handle(call, result: result)
    }

    let events = FlutterEventChannel(
      name: captureEventsName,
      binaryMessenger: controller.binaryMessenger
    )
    events.setStreamHandler(
      CaptureEventStreamHandler(
        pipeline: pipeline,
        onSinkChanged: { [weak self] sink in
          self?.captureEventSink = sink
        }
      )
    )

    let bleEvents = FlutterEventChannel(
      name: dualCameraBleEventsName,
      binaryMessenger: controller.binaryMessenger
    )
    bleEvents.setStreamHandler(dualCameraBleControl)

    let factory = NativePreviewViewFactory(pipeline: pipeline)
    self.registrar(forPlugin: "com.swingcapture.native_preview")?.register(factory, withId: previewTypeId)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func pickVideoFromLibrary(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard pendingVideoPickResult == nil else {
      result(
        FlutterError(
          code: "picker_busy",
          message: "A video picker is already open.",
          details: nil
        )
      )
      return
    }
    guard
      let args = call.arguments as? [String: Any],
      let destinationDirectory = args["destinationDirectory"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "pickVideoFromLibrary requires destinationDirectory.",
          details: nil
        )
      )
      return
    }
    guard UIImagePickerController.isSourceTypeAvailable(.photoLibrary) else {
      result(
        FlutterError(
          code: "picker_unavailable",
          message: "Photo library is not available.",
          details: nil
        )
      )
      return
    }

    pendingVideoPickResult = result
    pendingVideoPickDestinationDirectory = destinationDirectory
    pendingVideoPickFilePrefix = args["filePrefix"] as? String

    guard let presenter = flutterViewController else {
      clearPendingVideoPick()
      result(
        FlutterError(
          code: "picker_unavailable",
          message: "Flutter view controller is not available.",
          details: nil
        )
      )
      return
    }

    let picker = UIImagePickerController()
    picker.sourceType = .photoLibrary
    picker.mediaTypes = ["public.movie"]
    picker.videoQuality = .typeHigh
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    guard
      let result = pendingVideoPickResult,
      let destinationDirectory = pendingVideoPickDestinationDirectory,
      let sourceURL = info[.mediaURL] as? URL
    else {
      pendingVideoPickResult?(nil)
      clearPendingVideoPick()
      return
    }
    let filePrefix = pendingVideoPickFilePrefix ?? "imported_video"
    clearPendingVideoPick()

    videoImportQueue.async { [weak self] in
      guard let self else { return }
      do {
        let copiedURL = try self.copyPickedVideoToAppStorage(
          sourceURL: sourceURL,
          destinationDirectory: destinationDirectory,
          filePrefix: filePrefix
        )
        let response: [String: Any] = [
          "videoPath": copiedURL.path,
          "durationMs": self.durationMs(for: copiedURL),
          "displayName": copiedURL.lastPathComponent,
        ]
        DispatchQueue.main.async {
          result(response)
        }
      } catch {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "video_import_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
    pendingVideoPickResult?(nil)
    clearPendingVideoPick()
  }

  private func clearPendingVideoPick() {
    pendingVideoPickResult = nil
    pendingVideoPickDestinationDirectory = nil
    pendingVideoPickFilePrefix = nil
  }

  private func extractPoseFramesFromVideo(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let videoPath = args["videoPath"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "extractPoseFramesFromVideo requires videoPath.",
          details: nil
        )
      )
      return
    }
    let targetFps = min(max((args["targetFps"] as? NSNumber)?.doubleValue ?? 12.0, 1.0), 30.0)
    let maxFrames = min(max((args["maxFrames"] as? NSNumber)?.intValue ?? 1800, 1), 10000)
    let jobId = args["jobId"] as? String ?? "video_pose_import"

    videoImportQueue.async { [weak self] in
      guard let self else { return }
      do {
        let response = try self.extractPoseFrames(
          videoPath: videoPath,
          targetFps: targetFps,
          maxFrames: maxFrames,
          jobId: jobId
        )
        DispatchQueue.main.async {
          result(response)
        }
      } catch {
        self.emitVideoImportProgress(
          jobId: jobId,
          phase: "failed",
          progress: 0,
          processedFrames: 0,
          totalFrames: nil,
          message: "Pose extraction failed."
        )
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: "pose_extraction_failed",
              message: error.localizedDescription,
              details: nil
            )
          )
        }
      }
    }
  }

  private func copyPickedVideoToAppStorage(
    sourceURL: URL,
    destinationDirectory: String,
    filePrefix: String
  ) throws -> URL {
    let manager = FileManager.default
    let destinationURL = URL(fileURLWithPath: destinationDirectory, isDirectory: true)
    try manager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

    let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
    let sanitizedPrefix = sanitizedFileSegment(filePrefix)
    let prefix = sanitizedPrefix.isEmpty ? "imported_video" : sanitizedPrefix
    var outputURL = destinationURL.appendingPathComponent("\(prefix).\(ext)")
    var suffix = 1
    while manager.fileExists(atPath: outputURL.path) {
      outputURL = destinationURL.appendingPathComponent("\(prefix)_\(suffix).\(ext)")
      suffix += 1
    }

    let accessing = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if accessing {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }
    try manager.copyItem(at: sourceURL, to: outputURL)
    return outputURL
  }

  private func extractPoseFrames(
    videoPath: String,
    targetFps: Double,
    maxFrames: Int,
    jobId: String
  ) throws -> [String: Any] {
    let url = URL(fileURLWithPath: videoPath)
    let asset = AVURLAsset(url: url)
    let durationSeconds = CMTimeGetSeconds(asset.duration)
    guard durationSeconds.isFinite, durationSeconds > 0 else {
      throw NSError(
        domain: "MotionCapture",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not read video duration."]
      )
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 720, height: 720)
    let stepSeconds = 1.0 / targetFps
    let tolerance = CMTime(seconds: stepSeconds / 2.0, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance

    var frames: [[String: Any]] = []
    var poseFrameCount = 0
    var seconds = 0.0
    var processedFrames = 0
    var lastProgressUpdate = Date.distantPast
    let totalFrames = max(1, min(Int(floor(durationSeconds / stepSeconds)) + 1, maxFrames))
    emitVideoImportProgress(
      jobId: jobId,
      phase: "extracting",
      progress: 0,
      processedFrames: 0,
      totalFrames: totalFrames,
      message: "Extracting pose JSON... 0%"
    )
    while seconds <= durationSeconds, frames.count < maxFrames {
      processedFrames += 1
      let requested = CMTime(seconds: seconds, preferredTimescale: 600)
      var actual = CMTime.zero
      let image = try generator.copyCGImage(at: requested, actualTime: &actual)
      let landmarks = try detectPoseLandmarks(in: image)
      if !landmarks.isEmpty {
        poseFrameCount += 1
      }
      frames.append([
        "offsetMs": min(Int(CMTimeGetSeconds(actual) * 1000.0), Int(durationSeconds * 1000.0)),
        "landmarks": landmarks,
      ])
      let now = Date()
      if now.timeIntervalSince(lastProgressUpdate) >= 0.3 || processedFrames >= totalFrames {
        lastProgressUpdate = now
        let progress = min(max(Double(processedFrames) / Double(totalFrames), 0), 1)
        let percent = Int(progress * 100)
        emitVideoImportProgress(
          jobId: jobId,
          phase: "extracting",
          progress: progress,
          processedFrames: processedFrames,
          totalFrames: totalFrames,
          message: "Extracting pose JSON... \(percent)%"
        )
      }
      seconds += stepSeconds
    }
    emitVideoImportProgress(
      jobId: jobId,
      phase: "completed",
      progress: 1,
      processedFrames: processedFrames,
      totalFrames: totalFrames,
      message: "Pose JSON ready."
    )

    return [
      "durationMs": Int(durationSeconds * 1000.0),
      "frameCount": frames.count,
      "poseFrameCount": poseFrameCount,
      "frames": frames,
    ]
  }

  private func detectPoseLandmarks(in image: CGImage) throws -> [[String: Any]] {
    let request = VNDetectHumanBodyPoseRequest()
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
    try handler.perform([request])
    guard let observation = request.results?.first else {
      return []
    }

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

    var landmarks: [[String: Any]] = []
    for joint in joints {
      guard let point = try? observation.recognizedPoint(joint), point.confidence > 0.1 else {
        continue
      }
      landmarks.append([
        "name": names[joint] ?? "",
        "x": min(max(Double(point.location.x), 0.0), 1.0),
        "y": min(max(Double(1 - point.location.y), 0.0), 1.0),
        "confidence": Double(point.confidence),
      ])
    }
    return landmarks
  }

  private func durationMs(for url: URL) -> Int {
    let asset = AVURLAsset(url: url)
    let seconds = CMTimeGetSeconds(asset.duration)
    guard seconds.isFinite, seconds > 0 else {
      return 0
    }
    return Int(seconds * 1000.0)
  }

  private func readVideoMetadata(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let videoPath = args["videoPath"] as? String,
      !videoPath.isEmpty
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "readVideoMetadata requires videoPath.",
          details: nil
        )
      )
      return
    }

    let url = URL(fileURLWithPath: videoPath)
    let asset = AVURLAsset(url: url)
    let frameRate = videoFrameRate(for: asset)
    let frameRateValue: Any
    if let frameRate {
      frameRateValue = frameRate
    } else {
      frameRateValue = NSNull()
    }
    result([
      "durationMs": durationMs(for: url),
      "frameRate": frameRateValue,
    ])
  }

  private func videoFrameRate(for asset: AVAsset) -> Double? {
    guard let track = asset.tracks(withMediaType: .video).first else {
      return nil
    }
    let nominal = Double(track.nominalFrameRate)
    if nominal > 0 && nominal.isFinite {
      return nominal
    }
    let minFrameDuration = CMTimeGetSeconds(track.minFrameDuration)
    if minFrameDuration.isFinite && minFrameDuration > 0 {
      return 1.0 / minFrameDuration
    }
    return sampleFrameRate(asset: asset, track: track)
  }

  private func sampleFrameRate(asset: AVAsset, track: AVAssetTrack) -> Double? {
    guard
      let reader = try? AVAssetReader(asset: asset)
    else {
      return nil
    }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      return nil
    }
    reader.add(output)
    guard reader.startReading() else {
      return nil
    }

    var firstTime: Double?
    var lastTime: Double?
    var frameCount = 0
    while frameCount < 1200, let sample = output.copyNextSampleBuffer() {
      let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
      if time.isFinite {
        if firstTime == nil {
          firstTime = time
        }
        lastTime = time
        frameCount += 1
      }
      CMSampleBufferInvalidate(sample)
    }
    reader.cancelReading()

    guard
      frameCount >= 2,
      let first = firstTime,
      let last = lastTime,
      last > first
    else {
      return nil
    }
    return Double(frameCount - 1) / (last - first)
  }

  private func sanitizedFileSegment(_ value: String) -> String {
    return value.replacingOccurrences(
      of: "[^A-Za-z0-9._-]",
      with: "_",
      options: .regularExpression
    )
  }

  private func emitVideoImportProgress(
    jobId: String,
    phase: String,
    progress: Double,
    processedFrames: Int,
    totalFrames: Int?,
    message: String
  ) {
    var payload: [String: Any] = [
      "type": "video_import_progress",
      "jobId": jobId,
      "phase": phase,
      "progress": min(max(progress, 0), 1),
      "processedFrames": processedFrames,
      "message": message,
    ]
    if let totalFrames {
      payload["totalFrames"] = totalFrames
    }
    DispatchQueue.main.async { [weak self] in
      self?.captureEventSink?(payload)
    }
  }

  private func saveClip(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard
      let args = call.arguments as? [String: Any],
      let sourcePath = args["sourcePath"] as? String,
      let outputPath = args["outputPath"] as? String,
      let triggerMs = args["triggerMs"] as? NSNumber,
      let preRollMs = args["preRollMs"] as? NSNumber,
      let postRollMs = args["postRollMs"] as? NSNumber
    else {
      result(
        FlutterError(
          code: "invalid_args",
          message: "saveClip requires sourcePath/outputPath/triggerMs/preRollMs/postRollMs",
          details: nil
        )
      )
      return
    }

    let sourceURL = URL(fileURLWithPath: sourcePath)
    let outputURL = URL(fileURLWithPath: outputPath)
    let asset = AVURLAsset(url: sourceURL)
    let durationMs = Int64(CMTimeGetSeconds(asset.duration) * 1000)
    let clipStartMs = max(0, triggerMs.int64Value - preRollMs.int64Value)
    let clipEndMs = min(durationMs, triggerMs.int64Value + postRollMs.int64Value)

    guard clipEndMs > clipStartMs else {
      result(sourcePath)
      return
    }

    do {
      if FileManager.default.fileExists(atPath: outputPath) {
        try FileManager.default.removeItem(at: outputURL)
      }
    } catch {
      result(
        FlutterError(
          code: "io_error",
          message: "Failed to clear existing clip output path.",
          details: error.localizedDescription
        )
      )
      return
    }

    guard let exportSession = AVAssetExportSession(
      asset: asset,
      presetName: AVAssetExportPresetHighestQuality
    ) else {
      result(sourcePath)
      return
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .mp4
    exportSession.shouldOptimizeForNetworkUse = true
    exportSession.timeRange = CMTimeRange(
      start: CMTime(milliseconds: clipStartMs),
      end: CMTime(milliseconds: clipEndMs)
    )

    exportSession.exportAsynchronously {
      DispatchQueue.main.async {
        switch exportSession.status {
        case .completed:
          result(outputPath)
        case .failed, .cancelled:
          result(sourcePath)
        default:
          result(sourcePath)
        }
      }
    }
  }
}

private final class CaptureEventStreamHandler: NSObject, FlutterStreamHandler {
  weak var pipeline: NativeCapturePipeline?
  let onSinkChanged: (FlutterEventSink?) -> Void

  init(
    pipeline: NativeCapturePipeline,
    onSinkChanged: @escaping (FlutterEventSink?) -> Void
  ) {
    self.pipeline = pipeline
    self.onSinkChanged = onSinkChanged
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onSinkChanged(events)
    pipeline?.setEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onSinkChanged(nil)
    pipeline?.setEventSink(nil)
    return nil
  }
}

private extension CMTime {
  init(milliseconds: Int64) {
    self = CMTime(value: milliseconds, timescale: 1000)
  }
}
