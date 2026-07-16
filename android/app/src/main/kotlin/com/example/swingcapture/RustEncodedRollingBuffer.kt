package com.lumiaiq.MotionCapture

import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import kotlin.math.ceil

/**
 * Thin ownership wrapper around capture_core's fixed-capacity encoded ring.
 *
 * MediaCodec output buffers stay direct all the way into JNI. The only large
 * allocation after capture starts is an explicit clip snapshot on the saver
 * path; normal pushes only copy into Rust's preallocated arena.
 */
internal class RustEncodedRollingBuffer : AutoCloseable {
    private var handle: Long = 0L
    private var format: MediaFormat? = null
    private var targetFps: Int = 120
    private var width: Int = 1920
    private var height: Int = 1080
    private var orientationHintDegrees: Int = 0

    @Synchronized
    fun reset(
        windowUs: Long,
        targetFps: Int,
        width: Int,
        height: Int,
        orientationHintDegrees: Int,
        bitrateBps: Int,
    ) {
        destroyHandle()
        val retentionSeconds = ceil(windowUs / 1_000_000.0).toLong() + KEYFRAME_MARGIN_SECONDS
        val maxSamples = (
            targetFps.toLong() * retentionSeconds + SAMPLE_CAPACITY_MARGIN
        ).coerceIn(MIN_SAMPLE_CAPACITY, MAX_SAMPLE_CAPACITY).toInt()
        val nominalBytes = bitrateBps.toLong() * retentionSeconds / 8L
        val byteCapacity = (nominalBytes * CAPACITY_HEADROOM_NUMERATOR /
            CAPACITY_HEADROOM_DENOMINATOR)
            .coerceIn(MIN_BYTE_CAPACITY, MAX_BYTE_CAPACITY)
        val created = nativeCreate(windowUs, maxSamples, byteCapacity)
        check(created != 0L) {
            "capture_core could not allocate encoded ring " +
                "samples=$maxSamples bytes=$byteCapacity"
        }
        handle = created
        format = null
        this.targetFps = targetFps
        this.width = width
        this.height = height
        this.orientationHintDegrees = orientationHintDegrees
    }

    @Synchronized
    fun clear() {
        if (handle != 0L) {
            nativeClear(handle)
        }
        format = null
    }

    @Synchronized
    fun setFormat(mediaFormat: MediaFormat) {
        format = mediaFormat
    }

    @Synchronized
    fun addSample(
        source: ByteBuffer,
        offset: Int,
        size: Int,
        presentationTimeUs: Long,
        flags: Int,
    ): Boolean {
        if (handle == 0L || size <= 0 || !source.isDirect) {
            return false
        }
        return nativePushDirect(
            handle,
            source,
            offset,
            size,
            presentationTimeUs,
            flags,
        ) == 0
    }

    @Synchronized
    fun metrics(): RollingBufferMetrics {
        val localHandle = handle
        if (localHandle == 0L) {
            return RollingBufferMetrics.empty()
        }
        val sampleCount = nativeSampleCount(localHandle)
        val durationUs = nativeDurationUs(localHandle).coerceAtLeast(0L)
        return RollingBufferMetrics(
            sampleCount = sampleCount,
            durationUs = durationUs,
            sizeBytes = nativeSizeBytes(localHandle).coerceAtLeast(0L),
            keyFrameCount = nativeKeyFrameCount(localHandle),
            achievedFps = if (sampleCount > 1 && durationUs > 0L) {
                (sampleCount - 1) * 1_000_000.0 / durationUs.toDouble()
            } else {
                null
            },
        )
    }

    @Synchronized
    fun snapshot(): RustEncodedBufferSnapshot? {
        val mediaFormat = format ?: return null
        val localHandle = handle
        if (localHandle == 0L) {
            return null
        }
        val snapshotHandle = nativeSnapshot(localHandle)
        if (snapshotHandle == 0L) {
            return null
        }
        val sampleCount = nativeSnapshotCount(snapshotHandle)
        val maxSampleSize = nativeSnapshotMaxSampleSize(snapshotHandle)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
        if (sampleCount <= 0 || maxSampleSize <= 0) {
            nativeSnapshotDestroy(snapshotHandle)
            return null
        }
        return RustEncodedBufferSnapshot(
            owner = this,
            handle = snapshotHandle,
            format = mediaFormat,
            sampleCount = sampleCount,
            maxSampleSize = maxSampleSize,
            targetFps = targetFps,
            width = width,
            height = height,
            orientationHintDegrees = orientationHintDegrees,
        )
    }

    internal fun snapshotSampleSize(snapshotHandle: Long, index: Int): Int {
        return nativeSnapshotSampleSize(snapshotHandle, index)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }

    internal fun snapshotSamplePts(snapshotHandle: Long, index: Int): Long {
        return nativeSnapshotSamplePts(snapshotHandle, index)
    }

    internal fun snapshotSampleFlags(snapshotHandle: Long, index: Int): Int {
        return nativeSnapshotSampleFlags(snapshotHandle, index)
    }

    internal fun snapshotCopySample(
        snapshotHandle: Long,
        index: Int,
        destination: ByteBuffer,
    ): Int {
        return nativeSnapshotCopySample(snapshotHandle, index, destination)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }

    internal fun destroySnapshot(snapshotHandle: Long) {
        nativeSnapshotDestroy(snapshotHandle)
    }

    @Synchronized
    override fun close() {
        destroyHandle()
        format = null
    }

    private fun destroyHandle() {
        if (handle != 0L) {
            nativeDestroy(handle)
            handle = 0L
        }
    }

    private companion object {
        private const val LOG_TAG = "CaptureCore"
        private const val KEYFRAME_MARGIN_SECONDS = 2L
        private const val SAMPLE_CAPACITY_MARGIN = 16L
        private const val MIN_SAMPLE_CAPACITY = 64L
        private const val MAX_SAMPLE_CAPACITY = 4096L
        private const val MIN_BYTE_CAPACITY = 8L * 1024L * 1024L
        private const val MAX_BYTE_CAPACITY = 128L * 1024L * 1024L
        private const val CAPACITY_HEADROOM_NUMERATOR = 5L
        private const val CAPACITY_HEADROOM_DENOMINATOR = 4L

        init {
            System.loadLibrary("capture_core")
            check(runNativeBridgeSelfTest()) {
                "capture_core JNI direct-buffer self-test failed"
            }
        }

        private fun runNativeBridgeSelfTest(): Boolean {
            val coreHandle = nativeCreate(
                windowUs = 1_000_000L,
                maxSamples = 4,
                byteCapacity = 4096L,
            )
            if (coreHandle == 0L) {
                return false
            }
            var snapshotHandle = 0L
            return try {
                val expected = byteArrayOf(0x01, 0x23, 0x45, 0x67)
                val source = ByteBuffer.allocateDirect(expected.size)
                source.put(expected)
                if (
                    nativePushDirect(
                        coreHandle,
                        source,
                        0,
                        expected.size,
                        123_456L,
                        1,
                    ) != 0 ||
                    nativeSampleCount(coreHandle) != 1 ||
                    nativeKeyFrameCount(coreHandle) != 1 ||
                    nativeSizeBytes(coreHandle) != expected.size.toLong() ||
                    nativeFirstPtsUs(coreHandle) != 123_456L ||
                    nativeLastPtsUs(coreHandle) != 123_456L
                ) {
                    return false
                }
                snapshotHandle = nativeSnapshot(coreHandle)
                if (
                    snapshotHandle == 0L ||
                    nativeSnapshotCount(snapshotHandle) != 1 ||
                    nativeSnapshotSampleSize(snapshotHandle, 0) != expected.size.toLong() ||
                    nativeSnapshotSamplePts(snapshotHandle, 0) != 123_456L ||
                    nativeSnapshotSampleFlags(snapshotHandle, 0) and 1 == 0
                ) {
                    return false
                }
                val destination = ByteBuffer.allocateDirect(expected.size)
                if (
                    nativeSnapshotCopySample(snapshotHandle, 0, destination) !=
                    expected.size.toLong()
                ) {
                    return false
                }
                val matches = expected.indices.all { index ->
                    destination.get(index) == expected[index]
                }
                if (matches) {
                    Log.i(LOG_TAG, "JNI direct-buffer ring self-test passed")
                }
                matches
            } finally {
                if (snapshotHandle != 0L) {
                    nativeSnapshotDestroy(snapshotHandle)
                }
                nativeDestroy(coreHandle)
            }
        }

        @JvmStatic
        private external fun nativeCreate(
            windowUs: Long,
            maxSamples: Int,
            byteCapacity: Long,
        ): Long

        @JvmStatic
        private external fun nativeDestroy(handle: Long)

        @JvmStatic
        private external fun nativeClear(handle: Long): Int

        @JvmStatic
        private external fun nativePushDirect(
            handle: Long,
            source: ByteBuffer,
            offset: Int,
            size: Int,
            presentationTimeUs: Long,
            flags: Int,
        ): Int

        @JvmStatic
        private external fun nativeSampleCount(handle: Long): Int

        @JvmStatic
        private external fun nativeKeyFrameCount(handle: Long): Int

        @JvmStatic
        private external fun nativeSizeBytes(handle: Long): Long

        @JvmStatic
        private external fun nativeDurationUs(handle: Long): Long

        @JvmStatic
        private external fun nativeFirstPtsUs(handle: Long): Long

        @JvmStatic
        private external fun nativeLastPtsUs(handle: Long): Long

        @JvmStatic
        private external fun nativeSnapshot(handle: Long): Long

        @JvmStatic
        private external fun nativeSnapshotDestroy(handle: Long)

        @JvmStatic
        private external fun nativeSnapshotCount(handle: Long): Int

        @JvmStatic
        private external fun nativeSnapshotMaxSampleSize(handle: Long): Long

        @JvmStatic
        private external fun nativeSnapshotSampleSize(handle: Long, index: Int): Long

        @JvmStatic
        private external fun nativeSnapshotSamplePts(handle: Long, index: Int): Long

        @JvmStatic
        private external fun nativeSnapshotSampleFlags(handle: Long, index: Int): Int

        @JvmStatic
        private external fun nativeSnapshotCopySample(
            handle: Long,
            index: Int,
            destination: ByteBuffer,
        ): Long
    }
}

internal class RustEncodedBufferSnapshot(
    private val owner: RustEncodedRollingBuffer,
    private var handle: Long,
    val format: MediaFormat,
    val sampleCount: Int,
    val maxSampleSize: Int,
    val targetFps: Int,
    val width: Int,
    val height: Int,
    val orientationHintDegrees: Int,
) : AutoCloseable {
    fun sampleSize(index: Int): Int = owner.snapshotSampleSize(requireHandle(), index)

    fun samplePresentationTimeUs(index: Int): Long =
        owner.snapshotSamplePts(requireHandle(), index)

    fun sampleFlags(index: Int): Int = owner.snapshotSampleFlags(requireHandle(), index)

    fun copySample(index: Int, destination: ByteBuffer): Int =
        owner.snapshotCopySample(requireHandle(), index, destination)

    override fun close() {
        val localHandle = handle
        if (localHandle != 0L) {
            handle = 0L
            owner.destroySnapshot(localHandle)
        }
    }

    private fun requireHandle(): Long {
        check(handle != 0L) { "Encoded snapshot is already closed." }
        return handle
    }
}
