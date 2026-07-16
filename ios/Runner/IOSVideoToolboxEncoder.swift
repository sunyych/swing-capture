import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum IOSVideoEncoderError: LocalizedError {
  case creationFailed(OSStatus)
  case configurationFailed(OSStatus)
  case encodeFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .creationFailed(let status):
      return "VideoToolbox hardware encoder creation failed (\(status))."
    case .configurationFailed(let status):
      return "VideoToolbox hardware encoder configuration failed (\(status))."
    case .encodeFailed(let status):
      return "VideoToolbox frame encode failed (\(status))."
    }
  }
}

final class IOSVideoToolboxEncoder {
  typealias OutputHandler = (CMSampleBuffer) -> Void
  typealias ErrorHandler = (Error) -> Void

  private var session: VTCompressionSession?
  private var callbackContext: IOSVideoToolboxCallbackContext?
  private let stateLock = NSLock()
  private let outputHandler: OutputHandler
  private let errorHandler: ErrorHandler
  private(set) var codecName = "h264"
  private var forceKeyFrame = true
  private var generation = 0
  private var failureReported = false

  init(
    outputHandler: @escaping OutputHandler,
    errorHandler: @escaping ErrorHandler
  ) {
    self.outputHandler = outputHandler
    self.errorHandler = errorHandler
  }

  deinit {
    stop()
  }

  func start(profile: IOSCaptureProfile, bitrateBps: Int) throws -> String {
    stop()
    stateLock.lock()
    generation &+= 1
    let candidateGeneration = generation
    failureReported = false
    stateLock.unlock()
    var lastStatus: OSStatus = kVTParameterErr
    for codec in [kCMVideoCodecType_HEVC, kCMVideoCodecType_H264] {
      var candidate: VTCompressionSession?
      let context = IOSVideoToolboxCallbackContext(
        encoder: self,
        generation: candidateGeneration
      )
      let specification: CFDictionary?
      if #available(iOS 17.4, *) {
        specification = [
          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
          kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
        ] as CFDictionary
      } else {
        // VideoToolbox selects hardware by default on physical iOS devices.
        specification = nil
      }
      let status = VTCompressionSessionCreate(
        allocator: kCFAllocatorDefault,
        width: profile.width,
        height: profile.height,
        codecType: codec,
        encoderSpecification: specification,
        imageBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          kCVPixelBufferWidthKey as String: profile.width,
          kCVPixelBufferHeightKey as String: profile.height,
          kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary,
        compressedDataAllocator: nil,
        outputCallback: iosVideoToolboxOutputCallback,
        refcon: Unmanaged.passUnretained(context).toOpaque(),
        compressionSessionOut: &candidate
      )
      lastStatus = status
      guard status == noErr, let candidate else { continue }
      do {
        try configure(
          session: candidate,
          profile: profile,
          bitrateBps: bitrateBps,
          codec: codec
        )
        let selectedCodec = codec == kCMVideoCodecType_HEVC ? "h265" : "h264"
        stateLock.lock()
        session = candidate
        callbackContext = context
        codecName = selectedCodec
        forceKeyFrame = true
        failureReported = false
        stateLock.unlock()
        return selectedCodec
      } catch {
        VTCompressionSessionInvalidate(candidate)
        lastStatus = (error as? IOSVideoEncoderError)?.statusCode ?? kVTParameterErr
      }
    }
    throw IOSVideoEncoderError.creationFailed(lastStatus)
  }

  func encode(
    pixelBuffer: CVPixelBuffer,
    presentationTime: CMTime,
    duration: CMTime
  ) {
    stateLock.lock()
    guard let session, !failureReported else {
      stateLock.unlock()
      return
    }
    let frameGeneration = generation
    let shouldForceKeyFrame = forceKeyFrame
    forceKeyFrame = false
    stateLock.unlock()
    let options: CFDictionary? = shouldForceKeyFrame
      ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
      : nil
    let status = VTCompressionSessionEncodeFrame(
      session,
      imageBuffer: pixelBuffer,
      presentationTimeStamp: presentationTime,
      duration: duration,
      frameProperties: options,
      sourceFrameRefcon: nil,
      infoFlagsOut: nil
    )
    if status != noErr {
      reportFailure(
        IOSVideoEncoderError.encodeFailed(status),
        generation: frameGeneration
      )
    }
  }

  func requestKeyFrame() {
    stateLock.lock()
    forceKeyFrame = true
    stateLock.unlock()
  }

  func stop() {
    stateLock.lock()
    generation &+= 1
    let oldSession = session
    let oldContext = callbackContext
    self.session = nil
    callbackContext = nil
    failureReported = false
    forceKeyFrame = true
    stateLock.unlock()
    guard let oldSession else { return }
    withExtendedLifetime(oldContext) {
      VTCompressionSessionCompleteFrames(
        oldSession,
        untilPresentationTimeStamp: .invalid
      )
      VTCompressionSessionInvalidate(oldSession)
    }
  }

  fileprivate func handleOutput(
    generation outputGeneration: Int,
    status: OSStatus,
    sampleBuffer: CMSampleBuffer?
  ) {
    guard status == noErr else {
      reportFailure(
        IOSVideoEncoderError.encodeFailed(status),
        generation: outputGeneration
      )
      return
    }
    stateLock.lock()
    let isCurrent = outputGeneration == generation && !failureReported
    stateLock.unlock()
    guard isCurrent else { return }
    guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    outputHandler(sampleBuffer)
  }

  private func reportFailure(_ error: Error, generation failedGeneration: Int) {
    stateLock.lock()
    guard failedGeneration == generation, !failureReported else {
      stateLock.unlock()
      return
    }
    failureReported = true
    stateLock.unlock()
    errorHandler(error)
  }

  private func configure(
    session: VTCompressionSession,
    profile: IOSCaptureProfile,
    bitrateBps: Int,
    codec: CMVideoCodecType
  ) throws {
    let properties: [(CFString, CFTypeRef)] = [
      (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
      (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
      (kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: profile.fps)),
      (kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrateBps)),
      (kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: profile.fps)),
      (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 1)),
      (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
    ]
    for (key, value) in properties {
      let status = VTSessionSetProperty(session, key: key, value: value)
      guard status == noErr else {
        throw IOSVideoEncoderError.configurationFailed(status)
      }
    }
    let profileLevel: CFString = codec == kCMVideoCodecType_HEVC
      ? kVTProfileLevel_HEVC_Main_AutoLevel
      : kVTProfileLevel_H264_High_AutoLevel
    let profileStatus = VTSessionSetProperty(
      session,
      key: kVTCompressionPropertyKey_ProfileLevel,
      value: profileLevel
    )
    guard profileStatus == noErr else {
      throw IOSVideoEncoderError.configurationFailed(profileStatus)
    }
    let status = VTCompressionSessionPrepareToEncodeFrames(session)
    guard status == noErr else {
      throw IOSVideoEncoderError.configurationFailed(status)
    }
  }
}

private final class IOSVideoToolboxCallbackContext {
  weak var encoder: IOSVideoToolboxEncoder?
  let generation: Int

  init(encoder: IOSVideoToolboxEncoder, generation: Int) {
    self.encoder = encoder
    self.generation = generation
  }
}

private let iosVideoToolboxOutputCallback: VTCompressionOutputCallback = {
  outputCallbackRefCon,
  _,
  status,
  _,
  sampleBuffer in
  guard let outputCallbackRefCon else { return }
  let context = Unmanaged<IOSVideoToolboxCallbackContext>
    .fromOpaque(outputCallbackRefCon)
    .takeUnretainedValue()
  context.encoder?.handleOutput(
    generation: context.generation,
    status: status,
    sampleBuffer: sampleBuffer
  )
}

private extension IOSVideoEncoderError {
  var statusCode: OSStatus {
    switch self {
    case .creationFailed(let status),
         .configurationFailed(let status),
         .encodeFailed(let status):
      return status
    }
  }
}
