import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let channelName = "swingcapture/capture"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "startPreview", "stopPreview", "startDetection", "stopDetection",
             "startBuffering", "createAlbumIfNeeded", "saveToGallery":
          result(nil)
        case "saveClip":
          self.saveClip(call: call, result: result)
        case "getAlbums":
          result(["SwingCapture"])
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
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

private extension CMTime {
  init(milliseconds: Int64) {
    self = CMTime(value: milliseconds, timescale: 1000)
  }
}
