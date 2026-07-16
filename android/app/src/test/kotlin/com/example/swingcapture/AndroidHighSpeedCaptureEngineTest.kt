package com.lumiaiq.MotionCapture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    fun previewBufferLensAndZoomMethodsStayOwnedByCamera2Engine() {
        listOf(
            "startPreview",
            "stopPreview",
            "startBuffering",
            "stopBuffering",
            "saveBufferedClip",
            "switchCamera",
            "setZoomRatio",
        ).forEach { method ->
            assertTrue("$method must bypass CameraX", isCamera2OwnedCaptureMethod(method))
        }
        assertFalse(isCamera2OwnedCaptureMethod("startRtmpStream"))
        assertFalse(isCamera2OwnedCaptureMethod("stopRtmpStream"))
    }

    @Test
    fun rtmpOwnershipBlocksNewCaptureWork() {
        assertTrue(isCaptureStartBlockedByRtmp("startCapture"))
        assertTrue(isCaptureStartBlockedByRtmp("startBuffering"))
        assertTrue(isCaptureStartBlockedByRtmp("saveBufferedClip"))
        assertFalse(isCaptureStartBlockedByRtmp("stopBuffering"))
        assertFalse(isCaptureStartBlockedByRtmp("getCapabilities"))
    }

    @Test
    fun validPreviewSurfaceIsNeverReusedForANewSurfaceTexture() {
        val oldTexture = Any()
        val replacementTexture = Any()

        assertTrue(
            shouldReusePreviewSurface(
                existingSurfaceValid = true,
                existingOwner = oldTexture,
                currentTexture = oldTexture,
            ),
        )
        assertFalse(
            shouldReusePreviewSurface(
                existingSurfaceValid = true,
                existingOwner = oldTexture,
                currentTexture = replacementTexture,
            ),
        )
    }

    @Test
    fun replacingThePreviewViewRestartsTheActiveCameraOwner() {
        assertEquals(
            PreviewRebindAction.RESTART_CAPTURE,
            previewRebindAction(
                viewChanged = true,
                captureActive = true,
                previewActive = true,
            ),
        )
        assertEquals(
            PreviewRebindAction.RESTART_PREVIEW,
            previewRebindAction(
                viewChanged = true,
                captureActive = false,
                previewActive = true,
            ),
        )
        assertEquals(
            PreviewRebindAction.NONE,
            previewRebindAction(
                viewChanged = false,
                captureActive = true,
                previewActive = true,
            ),
        )
    }

    @Test
    fun bitmapSamplingWaitsForTheCurrentSurfaceTextureFirstFrame() {
        val currentTexture = Any()

        assertFalse(
            canSamplePreviewBitmap(
                viewAvailable = true,
                currentTexture = currentTexture,
                lastRenderedTexture = null,
            ),
        )
        assertTrue(
            canSamplePreviewBitmap(
                viewAvailable = true,
                currentTexture = currentTexture,
                lastRenderedTexture = currentTexture,
            ),
        )
        assertFalse(
            canSamplePreviewBitmap(
                viewAvailable = true,
                currentTexture = currentTexture,
                lastRenderedTexture = Any(),
            ),
        )
    }
}
