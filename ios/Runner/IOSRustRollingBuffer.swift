import AVFoundation
import CoreMedia
import Foundation

private let captureCoreKeyFrameFlag: Int32 = 1

@_silgen_name("capture_core_create")
private func captureCoreCreate(
  _ windowUs: Int64,
  _ maxSamples: UInt32,
  _ byteCapacity: UInt64
) -> UInt64

@_silgen_name("capture_core_destroy")
private func captureCoreDestroy(_ handle: UInt64)

@_silgen_name("capture_core_clear")
private func captureCoreClear(_ handle: UInt64) -> Int32

@_silgen_name("capture_core_push")
private func captureCorePush(
  _ handle: UInt64,
  _ data: UnsafePointer<UInt8>?,
  _ length: Int,
  _ presentationTimeUs: Int64,
  _ flags: Int32
) -> Int32

@_silgen_name("capture_core_stats")
private func captureCoreStats(
  _ handle: UInt64,
  _ output: UnsafeMutablePointer<IOSCaptureCoreStats>?
) -> Int32

@_silgen_name("capture_core_snapshot")
private func captureCoreSnapshot(_ handle: UInt64) -> UInt64

@_silgen_name("capture_core_snapshot_destroy")
private func captureCoreSnapshotDestroy(_ handle: UInt64)

@_silgen_name("capture_core_snapshot_count")
private func captureCoreSnapshotCount(_ handle: UInt64) -> UInt32

@_silgen_name("capture_core_snapshot_max_sample_size")
private func captureCoreSnapshotMaxSampleSize(_ handle: UInt64) -> UInt64

@_silgen_name("capture_core_snapshot_sample_size")
private func captureCoreSnapshotSampleSize(_ handle: UInt64, _ index: UInt32) -> UInt64

@_silgen_name("capture_core_snapshot_sample_pts")
private func captureCoreSnapshotSamplePts(_ handle: UInt64, _ index: UInt32) -> Int64

@_silgen_name("capture_core_snapshot_sample_flags")
private func captureCoreSnapshotSampleFlags(_ handle: UInt64, _ index: UInt32) -> Int32

@_silgen_name("capture_core_snapshot_copy_sample")
private func captureCoreSnapshotCopySample(
  _ handle: UInt64,
  _ index: UInt32,
  _ destination: UnsafeMutablePointer<UInt8>?,
  _ capacity: Int
) -> Int

struct IOSCaptureCoreStats {
  var sampleCount: UInt32 = 0
  var keyFrameCount: UInt32 = 0
  var sizeBytes: UInt64 = 0
  var durationUs: UInt64 = 0
  var firstPtsUs: Int64 = -1
  var lastPtsUs: Int64 = -1

  var achievedFps: Double? {
    guard sampleCount > 1, durationUs > 0 else { return nil }
    return Double(sampleCount - 1) * 1_000_000 / Double(durationUs)
  }
}

final class IOSRustEncodedRollingBuffer {
  private let lock = NSLock()
  private var handle: UInt64 = 0
  private var formatDescription: CMFormatDescription?
  private var profile = IOSCaptureProfile(width: 1920, height: 1080, fps: 30)
  private var codec = "h264"
  private var orientationDegrees = 0

  deinit {
    close()
  }

  func reset(
    windowUs: Int64,
    profile: IOSCaptureProfile,
    codec: String,
    bitrateBps: Int,
    orientationDegrees: Int
  ) throws {
    lock.lock()
    defer { lock.unlock() }
    destroyLocked()

    let retentionSeconds = Int(ceil(Double(windowUs) / 1_000_000)) + 2
    let maxSamples = UInt32(min(max(profile.fps * retentionSeconds + 16, 64), 4096))
    let nominalBytes = UInt64(max(bitrateBps, 1)) * UInt64(retentionSeconds) / 8
    let byteCapacity = min(max(nominalBytes * 5 / 4, 8 * 1024 * 1024), 128 * 1024 * 1024)
    let next = captureCoreCreate(windowUs, maxSamples, byteCapacity)
    guard next != 0 else {
      throw IOSRollingBufferError.allocationFailed
    }
    handle = next
    formatDescription = nil
    self.profile = profile
    self.codec = codec
    self.orientationDegrees = orientationDegrees
  }

  func clear() {
    lock.lock()
    defer { lock.unlock() }
    if handle != 0 {
      _ = captureCoreClear(handle)
    }
    formatDescription = nil
  }

  func push(_ sampleBuffer: CMSampleBuffer) -> Bool {
    guard CMSampleBufferDataIsReady(sampleBuffer),
          let block = CMSampleBufferGetDataBuffer(sampleBuffer),
          let description = CMSampleBufferGetFormatDescription(sampleBuffer)
    else {
      return false
    }

    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let ptsUs = CMTimeConvertScale(pts, timescale: 1_000_000, method: .default).value
    let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer,
      createIfNecessary: false
    ) as? [[CFString: Any]]
    let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    let flags: Int32 = isNotSync ? 0 : captureCoreKeyFrameFlag

    var lengthAtOffset = 0
    var totalLength = 0
    var pointer: UnsafeMutablePointer<Int8>?
    let pointerStatus = CMBlockBufferGetDataPointer(
      block,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &pointer
    )
    guard totalLength > 0 else { return false }

    lock.lock()
    defer { lock.unlock() }
    guard handle != 0 else { return false }
    formatDescription = description

    if pointerStatus == kCMBlockBufferNoErr,
       lengthAtOffset == totalLength,
       let pointer {
      return captureCorePush(
        handle,
        UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
        totalLength,
        ptsUs,
        flags
      ) == 0
    }

    var copy = Data(count: totalLength)
    let copyStatus = copy.withUnsafeMutableBytes { destination in
      CMBlockBufferCopyDataBytes(
        block,
        atOffset: 0,
        dataLength: totalLength,
        destination: destination.baseAddress!
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else { return false }
    return copy.withUnsafeBytes { source in
      captureCorePush(
        handle,
        source.baseAddress?.assumingMemoryBound(to: UInt8.self),
        totalLength,
        ptsUs,
        flags
      ) == 0
    }
  }

  func metrics() -> IOSCaptureCoreStats {
    lock.lock()
    defer { lock.unlock() }
    guard handle != 0 else { return IOSCaptureCoreStats() }
    var stats = IOSCaptureCoreStats()
    guard captureCoreStats(handle, &stats) == 0 else {
      return IOSCaptureCoreStats()
    }
    return stats
  }

  func snapshot() -> IOSRustEncodedSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    guard handle != 0, let formatDescription else { return nil }
    let snapshotHandle = captureCoreSnapshot(handle)
    guard snapshotHandle != 0 else { return nil }
    let count = Int(captureCoreSnapshotCount(snapshotHandle))
    let maxSize = Int(captureCoreSnapshotMaxSampleSize(snapshotHandle))
    guard count > 0, maxSize > 0 else {
      captureCoreSnapshotDestroy(snapshotHandle)
      return nil
    }
    return IOSRustEncodedSnapshot(
      handle: snapshotHandle,
      formatDescription: formatDescription,
      profile: profile,
      codec: codec,
      orientationDegrees: orientationDegrees,
      sampleCount: count,
      maxSampleSize: maxSize
    )
  }

  func close() {
    lock.lock()
    defer { lock.unlock() }
    destroyLocked()
    formatDescription = nil
  }

  private func destroyLocked() {
    if handle != 0 {
      captureCoreDestroy(handle)
      handle = 0
    }
  }
}

final class IOSRustEncodedSnapshot {
  private var handle: UInt64
  let formatDescription: CMFormatDescription
  let profile: IOSCaptureProfile
  let codec: String
  let orientationDegrees: Int
  let sampleCount: Int
  let maxSampleSize: Int

  init(
    handle: UInt64,
    formatDescription: CMFormatDescription,
    profile: IOSCaptureProfile,
    codec: String,
    orientationDegrees: Int,
    sampleCount: Int,
    maxSampleSize: Int
  ) {
    self.handle = handle
    self.formatDescription = formatDescription
    self.profile = profile
    self.codec = codec
    self.orientationDegrees = orientationDegrees
    self.sampleCount = sampleCount
    self.maxSampleSize = maxSampleSize
  }

  deinit {
    close()
  }

  func sampleSize(at index: Int) -> Int {
    guard handle != 0, index >= 0, index < sampleCount else { return 0 }
    return Int(captureCoreSnapshotSampleSize(handle, UInt32(index)))
  }

  func samplePtsUs(at index: Int) -> Int64 {
    guard handle != 0, index >= 0, index < sampleCount else { return -1 }
    return captureCoreSnapshotSamplePts(handle, UInt32(index))
  }

  func sampleFlags(at index: Int) -> Int32 {
    guard handle != 0, index >= 0, index < sampleCount else { return 0 }
    return captureCoreSnapshotSampleFlags(handle, UInt32(index))
  }

  func copySample(at index: Int) -> Data? {
    let size = sampleSize(at: index)
    guard size > 0 else { return nil }
    var data = Data(count: size)
    let copied = data.withUnsafeMutableBytes { destination in
      captureCoreSnapshotCopySample(
        handle,
        UInt32(index),
        destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
        size
      )
    }
    return copied == size ? data : nil
  }

  func close() {
    if handle != 0 {
      captureCoreSnapshotDestroy(handle)
      handle = 0
    }
  }
}

enum IOSRollingBufferError: LocalizedError {
  case allocationFailed
  case invalidSnapshot
  case writer(String)

  var errorDescription: String? {
    switch self {
    case .allocationFailed:
      return "Rust rolling buffer allocation failed."
    case .invalidSnapshot:
      return "Rust rolling buffer has no keyframe-backed encoded samples."
    case .writer(let message):
      return message
    }
  }
}

enum IOSCompressedClipWriter {
  static func write(
    snapshot: IOSRustEncodedSnapshot,
    outputURL: URL,
    queue: DispatchQueue,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    queue.async {
      do {
        try FileManager.default.createDirectory(
          at: outputURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(
          mediaType: .video,
          outputSettings: nil,
          sourceFormatHint: snapshot.formatDescription
        )
        input.expectsMediaDataInRealTime = false
        input.transform = transform(degrees: snapshot.orientationDegrees)
        guard writer.canAdd(input) else {
          throw IOSRollingBufferError.writer("AVAssetWriter rejected the encoded video track.")
        }
        writer.add(input)
        guard writer.startWriting() else {
          throw IOSRollingBufferError.writer(
            writer.error?.localizedDescription ?? "AVAssetWriter could not start."
          )
        }
        writer.startSession(atSourceTime: .zero)

        var index = 0
        var finishing = false
        let firstPtsUs = snapshot.samplePtsUs(at: 0)
        guard firstPtsUs >= 0 else { throw IOSRollingBufferError.invalidSnapshot }

        input.requestMediaDataWhenReady(on: queue) {
          guard !finishing else { return }
          do {
            while input.isReadyForMoreMediaData, index < snapshot.sampleCount {
              let sample = try makeSampleBuffer(
                snapshot: snapshot,
                index: index,
                firstPtsUs: firstPtsUs
              )
              guard input.append(sample) else {
                throw IOSRollingBufferError.writer(
                  writer.error?.localizedDescription ?? "AVAssetWriter rejected an encoded sample."
                )
              }
              index += 1
            }
            if index == snapshot.sampleCount {
              finishing = true
              input.markAsFinished()
              writer.finishWriting {
                snapshot.close()
                if writer.status == .completed {
                  completion(.success(outputURL))
                } else {
                  completion(
                    .failure(
                      IOSRollingBufferError.writer(
                        writer.error?.localizedDescription ?? "AVAssetWriter did not finish."
                      )
                    )
                  )
                }
              }
            }
          } catch {
            finishing = true
            input.markAsFinished()
            writer.cancelWriting()
            snapshot.close()
            completion(.failure(error))
          }
        }
      } catch {
        snapshot.close()
        completion(.failure(error))
      }
    }
  }

  private static func makeSampleBuffer(
    snapshot: IOSRustEncodedSnapshot,
    index: Int,
    firstPtsUs: Int64
  ) throws -> CMSampleBuffer {
    guard let data = snapshot.copySample(at: index), !data.isEmpty else {
      throw IOSRollingBufferError.invalidSnapshot
    }
    var block: CMBlockBuffer?
    let createStatus = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: 0,
      blockBufferOut: &block
    )
    guard createStatus == kCMBlockBufferNoErr, let block else {
      throw IOSRollingBufferError.writer("Could not allocate an encoded sample block.")
    }
    let copyStatus = data.withUnsafeBytes { source in
      CMBlockBufferReplaceDataBytes(
        with: source.baseAddress!,
        blockBuffer: block,
        offsetIntoDestination: 0,
        dataLength: data.count
      )
    }
    guard copyStatus == kCMBlockBufferNoErr else {
      throw IOSRollingBufferError.writer("Could not copy an encoded sample block.")
    }

    let ptsUs = snapshot.samplePtsUs(at: index) - firstPtsUs
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: CMTimeScale(snapshot.profile.fps)),
      presentationTimeStamp: CMTime(value: max(ptsUs, 0), timescale: 1_000_000),
      decodeTimeStamp: .invalid
    )
    var sampleSize = data.count
    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: block,
      formatDescription: snapshot.formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr, let sampleBuffer else {
      throw IOSRollingBufferError.writer("Could not rebuild an encoded sample.")
    }
    if snapshot.sampleFlags(at: index) & captureCoreKeyFrameFlag == 0 {
      CMSetAttachment(
        sampleBuffer,
        key: kCMSampleAttachmentKey_NotSync,
        value: kCFBooleanTrue,
        attachmentMode: kCMAttachmentMode_ShouldNotPropagate
      )
    }
    return sampleBuffer
  }

  private static func transform(degrees: Int) -> CGAffineTransform {
    CGAffineTransform(rotationAngle: CGFloat(degrees) * .pi / 180)
  }
}
