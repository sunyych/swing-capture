package com.lumiaiq.MotionCapture

import android.media.Image
import android.util.Log
import android.view.TextureView
import androidx.camera.core.ImageAnalysis
import com.pedro.common.ConnectChecker
import com.pedro.encoder.input.sources.audio.MicrophoneSource
import com.pedro.encoder.input.video.Camera2ApiManager
import com.pedro.extrasources.CameraXSource
import com.pedro.library.generic.GenericStream
import io.flutter.embedding.android.FlutterActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Live RTMP using RootEncoder [GenericStream] + [CameraXSource] + microphone.
 * Requires exclusive camera access — [NativeCapturePipeline] must unbind CameraX first.
 */
internal class RtmpLiveBroadcaster(
    private val activity: FlutterActivity,
    private val connectChecker: ConnectChecker,
) {
    private var genericStream: GenericStream? = null
    private val cameraXSource = CameraXSource(activity)
    private var idleBitrate = 2_500_000
    private var swingBitrate = 4_500_000

    fun updateBitrates(idle: Int, swing: Int) {
        idleBitrate = idle
        swingBitrate = swing
    }

    fun start(
        textureView: TextureView,
        url: String,
        idleBitrateBps: Int,
        swingBitrateBps: Int,
    ): Boolean {
        stop()
        idleBitrate = idleBitrateBps
        swingBitrate = swingBitrateBps
        return try {
            val gs = GenericStream(activity, connectChecker, cameraXSource, MicrophoneSource())
            genericStream = gs
            val okVideo = gs.prepareVideo(1280, 720, idleBitrateBps, 30)
            val okAudio = gs.prepareAudio(44100, true, 128 * 1024)
            if (!okVideo || !okAudio) {
                Log.e(TAG, "prepare failed video=$okVideo audio=$okAudio")
                stop()
                return false
            }
            gs.startPreview(textureView)
            gs.startStream(url)
            true
        } catch (e: Exception) {
            Log.e(TAG, "start", e)
            stop()
            false
        }
    }

    fun setSwingBitrateActive(active: Boolean) {
        val gs = genericStream ?: return
        val target = if (active) swingBitrate else idleBitrate
        try {
            gs.setVideoBitrateOnFly(target)
        } catch (e: Exception) {
            Log.w(TAG, "setVideoBitrateOnFly", e)
        }
    }

    fun stop() {
        try {
            genericStream?.stopStream()
            genericStream?.stopPreview()
        } catch (_: Exception) {
        }
        try {
            cameraXSource.stop()
        } catch (_: Exception) {
        }
        genericStream = null
    }

    /**
     * Sends `@setDataFrame` + [eventName] (e.g. onSwingStart) with AMF0 ecma payload.
     */
    fun sendSwingDataFrame(eventName: String, props: Map<String, Any?>) {
        val gs = genericStream ?: return
        val client = gs.reflectRtmpClient() ?: return
        CoroutineScope(Dispatchers.IO).launch {
            RtmpSwingAmf.sendSetDataFrame(client, eventName, props)
        }
    }

    val isActive: Boolean
        get() = genericStream != null

    /**
     * After [start], routes camera frames to ML Kit (same pipeline as classic ImageAnalysis).
     */
    fun attachPoseProcessor(onImage: (Image) -> Unit) {
        try {
            cameraXSource.addImageListener(
                960,
                540,
                ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888,
                false,
                object : Camera2ApiManager.ImageCallback {
                    override fun onImageAvailable(image: Image) {
                        onImage(image)
                    }
                },
            )
        } catch (e: Exception) {
            Log.e(TAG, "attachPoseProcessor", e)
        }
    }

    companion object {
        private const val TAG = "RtmpLiveBroadcaster"
    }
}
