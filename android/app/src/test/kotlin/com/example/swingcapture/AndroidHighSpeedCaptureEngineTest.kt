package com.lumiaiq.MotionCapture

import android.media.MediaCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidHighSpeedCaptureEngineTest {
    @Test
    fun captureProfilesFollowRequiredFallbackOrder() {
        assertEquals(
            listOf(
                CaptureProfile(1920, 1080, 120),
                CaptureProfile(1280, 720, 120),
                CaptureProfile(1920, 1080, 60),
                CaptureProfile(1280, 720, 60),
                CaptureProfile(1920, 1080, 30),
            ),
            captureProfilePriority(),
        )
    }

    @Test
    fun rollingBufferRetainsOnlyConfiguredTimeWindowAndReportsActualFps() {
        val buffer = EncodedRollingBuffer()
        buffer.reset(
            windowUs = 4_000_000L,
            targetFps = 60,
            width = 1920,
            height = 1080,
            orientationHintDegrees = 0,
        )

        repeat(361) { index ->
            buffer.addSample(
                EncodedVideoSample(
                    data = ByteArray(100),
                    presentationTimeUs = index * 1_000_000L / 60L,
                    flags = if (index % 60 == 0) {
                        MediaCodec.BUFFER_FLAG_KEY_FRAME
                    } else {
                        0
                    },
                ),
            )
        }

        val metrics = buffer.metrics()
        assertTrue(metrics.sampleCount in 240..242)
        assertTrue(metrics.durationUs in 3_990_000L..4_000_000L)
        assertEquals(metrics.sampleCount * 100L, metrics.sizeBytes)
        assertTrue((metrics.achievedFps ?: 0.0) in 59.9..60.1)
        assertTrue(metrics.keyFrameCount >= 4)
    }
}
