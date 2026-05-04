import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let captureChannelName = "swingcapture/capture"
  private let captureEventsName = "swingcapture/capture_events"
  private let previewTypeId = "swingcapture/native_preview"

  private var capturePipeline: NativeCapturePipeline?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

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
      pipeline.handle(call, result: result)
    }

    let events = FlutterEventChannel(
      name: captureEventsName,
      binaryMessenger: controller.binaryMessenger
    )
    events.setStreamHandler(CaptureEventStreamHandler(pipeline: pipeline))

    let factory = NativePreviewViewFactory(pipeline: pipeline)
    self.registrar(forPlugin: "com.swingcapture.native_preview")?.register(factory, withId: previewTypeId)

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
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

  init(pipeline: NativeCapturePipeline) {
    self.pipeline = pipeline
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    pipeline?.setEventSink(events)
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    pipeline?.setEventSink(nil)
    return nil
  }
}

private extension CMTime {
  init(milliseconds: Int64) {
    self = CMTime(value: milliseconds, timescale: 1000)
  }
}
