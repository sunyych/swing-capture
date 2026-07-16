import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {
  func testIOSCaptureFallbackLadderIsStrictlyOrdered() {
    XCTAssertEqual(
      iosCaptureFallbackLadder,
      [
        IOSCaptureProfile(width: 1920, height: 1080, fps: 120),
        IOSCaptureProfile(width: 1280, height: 720, fps: 120),
        IOSCaptureProfile(width: 1920, height: 1080, fps: 60),
        IOSCaptureProfile(width: 1280, height: 720, fps: 60),
        IOSCaptureProfile(width: 1920, height: 1080, fps: 30),
      ]
    )
  }

  func testIOSCaptureProfileSelectorSkipsUnsupportedStepsWithoutReordering() {
    let formats = [
      IOSCaptureFormatCapability(width: 1920, height: 1080, minFps: 24, maxFps: 60),
      IOSCaptureFormatCapability(width: 1280, height: 720, minFps: 30, maxFps: 120),
    ]

    XCTAssertEqual(
      supportedIOSCaptureProfiles(in: formats),
      [
        IOSCaptureProfile(width: 1280, height: 720, fps: 120),
        IOSCaptureProfile(width: 1920, height: 1080, fps: 60),
        IOSCaptureProfile(width: 1280, height: 720, fps: 60),
        IOSCaptureProfile(width: 1920, height: 1080, fps: 30),
      ]
    )
  }

  func testIOSCaptureProfilesRequireNinetyPercentMeasuredThroughput() {
    XCTAssertEqual(
      minimumAcceptedIOSCaptureFps(
        for: IOSCaptureProfile(width: 1920, height: 1080, fps: 120)
      ),
      108,
      accuracy: 0.001
    )
    XCTAssertEqual(
      minimumAcceptedIOSCaptureFps(
        for: IOSCaptureProfile(width: 1920, height: 1080, fps: 30)
      ),
      27,
      accuracy: 0.001
    )
  }
}
