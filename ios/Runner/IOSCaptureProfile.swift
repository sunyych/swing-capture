import AVFoundation
import CoreMedia
import Foundation

struct IOSCaptureProfile: Equatable, Hashable, CustomStringConvertible {
  let width: Int32
  let height: Int32
  let fps: Int

  init(width: Int, height: Int, fps: Int) {
    self.width = Int32(width)
    self.height = Int32(height)
    self.fps = fps
  }

  var description: String {
    "\(width)x\(height)@\(fps)"
  }
}

struct IOSCaptureFormatCapability: Equatable {
  let width: Int32
  let height: Int32
  let minFps: Double
  let maxFps: Double

  init(width: Int, height: Int, minFps: Double, maxFps: Double) {
    self.width = Int32(width)
    self.height = Int32(height)
    self.minFps = minFps
    self.maxFps = maxFps
  }

  func supports(_ profile: IOSCaptureProfile) -> Bool {
    width == profile.width &&
      height == profile.height &&
      minFps <= Double(profile.fps) &&
      maxFps + 0.01 >= Double(profile.fps)
  }
}

let iosCaptureFallbackLadder = [
  IOSCaptureProfile(width: 1920, height: 1080, fps: 120),
  IOSCaptureProfile(width: 1280, height: 720, fps: 120),
  IOSCaptureProfile(width: 1920, height: 1080, fps: 60),
  IOSCaptureProfile(width: 1280, height: 720, fps: 60),
  IOSCaptureProfile(width: 1920, height: 1080, fps: 30),
]

let iosCaptureMinimumFpsRatio = 0.90

func minimumAcceptedIOSCaptureFps(for profile: IOSCaptureProfile) -> Double {
  Double(profile.fps) * iosCaptureMinimumFpsRatio
}

func supportedIOSCaptureProfiles(
  in formats: [IOSCaptureFormatCapability]
) -> [IOSCaptureProfile] {
  iosCaptureFallbackLadder.filter { profile in
    formats.contains { $0.supports(profile) }
  }
}

extension AVCaptureDevice.Format {
  var swingCaptureCapability: IOSCaptureFormatCapability {
    let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
    var minimum = Double.greatestFiniteMagnitude
    var maximum = 0.0
    for range in videoSupportedFrameRateRanges {
      minimum = min(minimum, range.minFrameRate)
      maximum = max(maximum, range.maxFrameRate)
    }
    return IOSCaptureFormatCapability(
      width: Int(dimensions.width),
      height: Int(dimensions.height),
      minFps: minimum.isFinite ? minimum : 0,
      maxFps: maximum
    )
  }
}

func captureFormat(
  for profile: IOSCaptureProfile,
  on device: AVCaptureDevice
) -> AVCaptureDevice.Format? {
  device.formats
    .filter { $0.swingCaptureCapability.supports(profile) }
    .sorted { lhs, rhs in
      let leftSubtype = CMFormatDescriptionGetMediaSubType(lhs.formatDescription)
      let rightSubtype = CMFormatDescriptionGetMediaSubType(rhs.formatDescription)
      let leftIsNV12 = leftSubtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        leftSubtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      let rightIsNV12 = rightSubtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
        rightSubtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      if leftIsNV12 != rightIsNV12 {
        return leftIsNV12
      }
      return lhs.videoFieldOfView > rhs.videoFieldOfView
    }
    .first
}
