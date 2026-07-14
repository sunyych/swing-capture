package com.lumiaiq.MotionCapture

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraConstrainedHighSpeedCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureFailure
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import android.view.TextureView
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt

private const val HIGH_SPEED_TAG = "SwingHighSpeed"
private const val DEFAULT_ROLLING_SECONDS = 4
private const val DEFAULT_SENSITIVITY = 0.55
private const val MOTION_SAMPLE_WIDTH = 160
private const val MOTION_SAMPLE_HEIGHT = 90
private const val MOTION_SAMPLE_INTERVAL_MS = 33L
private const val MOTION_TRIGGER_DEBOUNCE_MS = 1800L
private const val BUFFER_STATE_INTERVAL_MS = 500L
private const val SYNC_FRAME_INTERVAL_MS = 1000L

internal data class CaptureProfile(
    val width: Int,
    val height: Int,
    val fps: Int,
)

internal fun captureProfilePriority(): List<CaptureProfile> {
    return listOf(
        CaptureProfile(width = 1920, height = 1080, fps = 120),
        CaptureProfile(width = 1280, height = 720, fps = 120),
        CaptureProfile(width = 1920, height = 1080, fps = 60),
        CaptureProfile(width = 1280, height = 720, fps = 60),
        CaptureProfile(width = 1920, height = 1080, fps = 30),
    )
}

private data class NativeHighSpeedConfig(
    val cameraId: String,
    val facing: Int?,
    val size: Size,
    val fpsRange: Range<Int>,
    val targetFps: Int,
    val bitrateBps: Int,
    val orientationHintDegrees: Int,
    val constrainedHighSpeed: Boolean,
) {
    fun toMap(): Map<String, Any> {
        return mapOf(
            "cameraId" to cameraId,
            "lensDirection" to lensDirectionLabel(facing),
            "width" to size.width,
            "height" to size.height,
            "fps" to targetFps,
            "fpsRange" to mapOf(
                "lower" to fpsRange.lower,
                "upper" to fpsRange.upper,
            ),
            "bitrateBps" to bitrateBps,
            "orientationHintDegrees" to orientationHintDegrees,
            "codec" to MediaFormat.MIMETYPE_VIDEO_AVC,
            "highSpeed" to constrainedHighSpeed,
        )
    }
}

internal data class EncodedVideoSample(
    val data: ByteArray,
    val presentationTimeUs: Long,
    val flags: Int,
)

internal data class EncodedBufferSnapshot(
    val format: MediaFormat,
    val samples: List<EncodedVideoSample>,
    val targetFps: Int,
    val width: Int,
    val height: Int,
    val orientationHintDegrees: Int,
)

private data class SavedClipResult(
    val file: File,
    val durationMs: Long,
    val frameCount: Int,
    val achievedFps: Double?,
)

internal data class RollingBufferMetrics(
    val sampleCount: Int,
    val durationUs: Long,
    val sizeBytes: Long,
    val keyFrameCount: Int,
    val achievedFps: Double?,
)

class AndroidHighSpeedCaptureEngine(
    private val activity: FlutterActivity,
) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val encoderExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val clipSaverExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val codecLock = Any()
    private val rollingBuffer = EncodedRollingBuffer()
    private val motionDetector = NativeMotionDetector(
        sampleWidth = MOTION_SAMPLE_WIDTH,
        sampleHeight = MOTION_SAMPLE_HEIGHT,
        sensitivity = DEFAULT_SENSITIVITY,
    )

    private val clipDirectory: File by lazy {
        File(activity.filesDir, "high_speed_clips").apply { mkdirs() }
    }

    private var eventSink: EventChannel.EventSink? = null
    private var previewView: TextureView? = null
    private var previewSurface: Surface? = null
    private var encoderInputSurface: Surface? = null
    private var encoder: MediaCodec? = null
    private var captureSession: CameraConstrainedHighSpeedCaptureSession? = null
    private var standardSession: CameraCaptureSession? = null
    private var cameraDevice: CameraDevice? = null
    private var pendingStartResult: MethodChannel.Result? = null
    private var pendingCandidates: ArrayDeque<NativeHighSpeedConfig> = ArrayDeque()
    private var activeConfig: NativeHighSpeedConfig? = null
    private var rollingSeconds: Int = DEFAULT_ROLLING_SECONDS
    private var debugLogging: Boolean = false
    private var drainLoopActive: Boolean = false
    private var captureStarting: Boolean = false
    private var captureRunning: Boolean = false
    private var clipSaveInFlight: Boolean = false
    private var lastMotionTriggerMs: Long = 0L

    private val motionSamplingRunnable = object : Runnable {
        override fun run() {
            sampleMotionFrame()
            if (captureRunning) {
                mainHandler.postDelayed(this, MOTION_SAMPLE_INTERVAL_MS)
            }
        }
    }
    private val bufferStateRunnable = object : Runnable {
        override fun run() {
            emitBufferState()
            if (captureRunning) {
                mainHandler.postDelayed(this, BUFFER_STATE_INTERVAL_MS)
            }
        }
    }
    private val syncFrameRunnable = object : Runnable {
        override fun run() {
            val codec = synchronized(codecLock) { encoder }
            if (captureRunning && codec != null) {
                try {
                    codec.setParameters(
                        Bundle().apply {
                            putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                        },
                    )
                } catch (_: Exception) {
                }
                mainHandler.postDelayed(this, SYNC_FRAME_INTERVAL_MS)
            }
        }
    }

    val isRunningOrStarting: Boolean
        get() = captureRunning || captureStarting

    fun attachEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun attachPreviewView(view: TextureView) {
        previewView = view
    }

    fun detachPreviewView(view: TextureView) {
        if (previewView === view) {
            previewView = null
        }
    }

    fun dispose() {
        stopCaptureInternal(sendStoppedEvent = false)
        eventSink = null
        previewView = null
        encoderExecutor.shutdown()
        clipSaverExecutor.shutdown()
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "getCapabilities" -> {
                result.success(getCapabilities())
                return true
            }
            "startCapture" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                startCapture(args, result)
                return true
            }
            "startBuffering" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val rollingMs =
                    ((args["preRollMs"] as? Number)?.toLong() ?: DEFAULT_ROLLING_SECONDS * 1000L) +
                        ((args["postRollMs"] as? Number)?.toLong() ?: 0L)
                startCapture(
                    args + mapOf(
                        "rollingSeconds" to (rollingMs / 1000L).coerceAtLeast(1L).toInt(),
                    ),
                    result,
                )
                return true
            }
            "stopCapture" -> {
                stopCaptureInternal(sendStoppedEvent = true)
                result.success(null)
                return true
            }
            "stopBuffering" -> {
                stopCaptureInternal(sendStoppedEvent = true)
                result.success(null)
                return true
            }
            "saveBufferedClip" -> {
                val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
                val outputPath = args["outputPath"] as? String
                val triggerEpochMs = (args["triggerEpochMs"] as? Number)?.toLong()
                if (outputPath.isNullOrBlank() || triggerEpochMs == null) {
                    result.error(
                        "invalid_args",
                        "saveBufferedClip requires outputPath/triggerEpochMs",
                        null
                    )
                    return true
                }
                saveRollingClip(
                    triggerEpochMs = triggerEpochMs,
                    motionScore = 0.0,
                    outputFile = File(outputPath),
                    result = result,
                )
                return true
            }
            "setSensitivity" -> {
                val value = (call.arguments as? Number)?.toDouble()
                    ?: ((call.arguments as? Map<*, *>)?.get("sensitivity") as? Number)
                        ?.toDouble()
                    ?: DEFAULT_SENSITIVITY
                motionDetector.setSensitivity(value)
                result.success(null)
                return true
            }
            "getSavedClips" -> {
                result.success(savedClipMaps())
                return true
            }
            else -> return false
        }
    }

    fun stopCaptureForLegacyRebind() {
        stopCaptureInternal(sendStoppedEvent = false)
    }

    @SuppressLint("MissingPermission")
    private fun startCapture(args: Map<*, *>, result: MethodChannel.Result) {
        val view = previewView
        if (view == null || !view.isAvailable || view.surfaceTexture == null) {
            result.error("no_preview", "Native preview Surface is not attached.", null)
            sendError("no_preview", "Native preview Surface is not attached.")
            return
        }
        if (
            ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("camera_permission_missing", "Camera permission is required.", null)
            sendError("camera_permission_missing", "Camera permission is required.")
            return
        }

        stopCaptureInternal(sendStoppedEvent = false)
        rollingSeconds =
            ((args["rollingSeconds"] as? Number)?.toInt() ?: DEFAULT_ROLLING_SECONDS)
                .coerceIn(1, 10)
        motionDetector.setSensitivity(
            ((args["sensitivity"] as? Number)?.toDouble() ?: DEFAULT_SENSITIVITY),
        )
        debugLogging = args["debug"] as? Boolean ?: false
        val candidates = selectCaptureCandidates(args)
        if (candidates.isEmpty()) {
            result.error(
                "high_speed_unavailable",
                "No Camera2 high-speed recording configuration is available.",
                null,
            )
            sendError(
                "high_speed_unavailable",
                "No Camera2 high-speed recording configuration is available.",
            )
            return
        }

        pendingStartResult = result
        pendingCandidates = ArrayDeque(candidates)
        captureStarting = true
        emitBufferState()
        tryStartNextCandidate()
    }

    @SuppressLint("MissingPermission")
    private fun tryStartNextCandidate(previousError: String? = null) {
        val config = pendingCandidates.removeFirstOrNull()
        if (config == null) {
            val message = previousError ?: "Camera2 high-speed session could not be created."
            val result = pendingStartResult
            pendingStartResult = null
            captureStarting = false
            result?.error("high_speed_start_failed", message, null)
            sendError("high_speed_start_failed", message)
            return
        }

        log(
            "Camera",
            "Trying ${config.size.width}x${config.size.height}@${config.targetFps} " +
                "mode=${if (config.constrainedHighSpeed) "hfr" else "standard"} " +
                "camera=${config.cameraId} fps=${config.fpsRange}",
        )
        activeConfig = config
        emitBufferState()
        rollingBuffer.reset(
            windowUs = rollingSeconds * 1_000_000L,
            targetFps = config.targetFps,
            width = config.size.width,
            height = config.size.height,
            orientationHintDegrees = config.orientationHintDegrees,
        )
        motionDetector.reset()
        try {
            startEncoder(config)
            val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            manager.openCamera(
                config.cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        cameraDevice = device
                        configureCaptureSession(device, config)
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        device.close()
                        failCandidate("High-speed camera disconnected.")
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        failCandidate("High-speed camera open failed: $error.")
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failCandidate(error.message ?: "Unable to start high-speed camera.")
        }
    }

    private fun startEncoder(config: NativeHighSpeedConfig) {
        val format = MediaFormat.createVideoFormat(
            MediaFormat.MIMETYPE_VIDEO_AVC,
            config.size.width,
            config.size.height,
        ).apply {
            setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            setInteger(MediaFormat.KEY_BIT_RATE, config.bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, config.targetFps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        }
        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        val inputSurface = codec.createInputSurface()
        codec.start()
        synchronized(codecLock) {
            encoder = codec
            encoderInputSurface = inputSurface
            drainLoopActive = true
        }
        encoderExecutor.execute { drainEncoderLoop() }
        log("Encoder", "Started AVC encoder ${config.size.width}x${config.size.height}@${config.targetFps}")
    }

    private fun configureCaptureSession(
        device: CameraDevice,
        config: NativeHighSpeedConfig,
    ) {
        val view = previewView
        val texture = view?.surfaceTexture
        val encoderSurface = encoderInputSurface
        if (view == null || texture == null || encoderSurface == null) {
            failCandidate("Preview or encoder Surface is unavailable.")
            return
        }
        try {
            texture.setDefaultBufferSize(config.size.width, config.size.height)
            val localPreviewSurface = Surface(texture)
            previewSurface = localPreviewSurface
            if (!config.constrainedHighSpeed) {
                configureStandardSession(
                    device = device,
                    config = config,
                    previewSurface = localPreviewSurface,
                    encoderSurface = encoderSurface,
                )
                return
            }
            device.createConstrainedHighSpeedCaptureSession(
                listOf(localPreviewSurface, encoderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        val highSpeed = session as? CameraConstrainedHighSpeedCaptureSession
                        if (highSpeed == null) {
                            failCandidate("Camera did not create a constrained high-speed session.")
                            return
                        }
                        captureSession = highSpeed
                        startRepeatingBurst(
                            device = device,
                            session = highSpeed,
                            config = config,
                            previewSurface = localPreviewSurface,
                            encoderSurface = encoderSurface,
                        )
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        failCandidate("Unable to configure high-speed camera session.")
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failCandidate(error.message ?: "Unable to create high-speed camera session.")
        }
    }

    private fun configureStandardSession(
        device: CameraDevice,
        config: NativeHighSpeedConfig,
        previewSurface: Surface,
        encoderSurface: Surface,
    ) {
        try {
            device.createCaptureSession(
                listOf(previewSurface, encoderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        standardSession = session
                        startRepeatingRequest(
                            device = device,
                            session = session,
                            config = config,
                            previewSurface = previewSurface,
                            encoderSurface = encoderSurface,
                        )
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        failCandidate("Unable to configure standard Camera2 recording session.")
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failCandidate(error.message ?: "Unable to create standard Camera2 recording session.")
        }
    }

    private fun startRepeatingBurst(
        device: CameraDevice,
        session: CameraConstrainedHighSpeedCaptureSession,
        config: NativeHighSpeedConfig,
        previewSurface: Surface,
        encoderSurface: Surface,
    ) {
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(previewSurface)
            builder.addTarget(encoderSurface)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(
                CaptureRequest.CONTROL_CAPTURE_INTENT,
                CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD,
            )
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, config.fpsRange)
            builder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
            )
            builder.set(
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
            )
            builder.set(
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
            )
            val requests = session.createHighSpeedRequestList(builder.build())
            session.setRepeatingBurst(
                requests,
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult,
                    ) {
                        markCaptureStarted(config)
                    }

                    override fun onCaptureFailed(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        failure: CaptureFailure,
                    ) {
                        val message = "High-speed capture failed: " +
                            "reason=${failure.reason}, frame=${failure.frameNumber}."
                        if (!captureRunning) {
                            failCandidate(message)
                        } else {
                            sendError("high_speed_capture_failed", message)
                        }
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failCandidate(error.message ?: "Unable to start high-speed repeating burst.")
        }
    }

    private fun startRepeatingRequest(
        device: CameraDevice,
        session: CameraCaptureSession,
        config: NativeHighSpeedConfig,
        previewSurface: Surface,
        encoderSurface: Surface,
    ) {
        try {
            val builder = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
            builder.addTarget(previewSurface)
            builder.addTarget(encoderSurface)
            builder.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
            builder.set(
                CaptureRequest.CONTROL_CAPTURE_INTENT,
                CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD,
            )
            builder.set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
            builder.set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, config.fpsRange)
            builder.set(
                CaptureRequest.CONTROL_AF_MODE,
                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
            )
            session.setRepeatingRequest(
                builder.build(),
                object : CameraCaptureSession.CaptureCallback() {
                    override fun onCaptureCompleted(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        result: TotalCaptureResult,
                    ) {
                        markCaptureStarted(config)
                    }

                    override fun onCaptureFailed(
                        session: CameraCaptureSession,
                        request: CaptureRequest,
                        failure: CaptureFailure,
                    ) {
                        val message = "Standard Camera2 capture failed: " +
                            "reason=${failure.reason}, frame=${failure.frameNumber}."
                        if (!captureRunning) {
                            failCandidate(message)
                        } else {
                            sendError("standard_capture_failed", message)
                        }
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failCandidate(error.message ?: "Unable to start standard Camera2 repeating request.")
        }
    }

    private fun markCaptureStarted(config: NativeHighSpeedConfig) {
        if (captureRunning || activeConfig != config) {
            return
        }
        captureRunning = true
        captureStarting = false
        emit("CameraReady", config.toMap())
        emit(
            "CaptureStarted",
            config.toMap() + mapOf("rollingSeconds" to rollingSeconds),
        )
        emitBufferState()
        pendingStartResult?.success(config.toMap())
        pendingStartResult = null
        mainHandler.removeCallbacks(motionSamplingRunnable)
        mainHandler.postDelayed(motionSamplingRunnable, MOTION_SAMPLE_INTERVAL_MS)
        mainHandler.removeCallbacks(bufferStateRunnable)
        mainHandler.postDelayed(bufferStateRunnable, BUFFER_STATE_INTERVAL_MS)
        mainHandler.removeCallbacks(syncFrameRunnable)
        mainHandler.postDelayed(syncFrameRunnable, SYNC_FRAME_INTERVAL_MS)
        log("Camera", "Capture started")
    }

    private fun failCandidate(message: String) {
        log("Camera", "Candidate failed: $message")
        emitBufferState()
        emitProfileFallbackIfNeeded(message)
        releaseCameraSession()
        releaseEncoder()
        rollingBuffer.clear()
        if (captureStarting && pendingCandidates.isNotEmpty()) {
            tryStartNextCandidate(message)
            return
        }
        val result = pendingStartResult
        pendingStartResult = null
        captureStarting = false
        captureRunning = false
        result?.error("high_speed_start_failed", message, null)
        sendError("high_speed_start_failed", message)
        emitBufferState()
    }

    private fun emitProfileFallbackIfNeeded(reason: String) {
        val current = activeConfig ?: return
        val next = pendingCandidates.firstOrNull() ?: return
        if (
            current.size.width == next.size.width &&
            current.size.height == next.size.height &&
            current.targetFps == next.targetFps
        ) {
            return
        }
        val priorities = captureProfilePriority()
        val currentIndex = priorities.indexOfFirst {
            it.width == current.size.width &&
                it.height == current.size.height &&
                it.fps == current.targetFps
        }
        val nextIndex = priorities.indexOfFirst {
            it.width == next.size.width &&
                it.height == next.size.height &&
                it.fps == next.targetFps
        }
        val skipped = if (currentIndex >= 0 && nextIndex > currentIndex + 1) {
            priorities.subList(currentIndex + 1, nextIndex).map {
                "${it.width}x${it.height}@${it.fps}"
            }
        } else {
            emptyList()
        }
        log(
            "Camera",
            "Fallback ${current.size.width}x${current.size.height}@${current.targetFps} -> " +
                "${next.size.width}x${next.size.height}@${next.targetFps}" +
                if (skipped.isEmpty()) "" else " unavailable=${skipped.joinToString()}",
        )
        emit(
            "ProfileFallback",
            mapOf(
                "from" to "${current.size.width}x${current.size.height}@${current.targetFps}",
                "to" to "${next.size.width}x${next.size.height}@${next.targetFps}",
                "skippedUnavailable" to skipped,
                "reason" to reason,
            ),
        )
    }

    private fun stopCaptureInternal(sendStoppedEvent: Boolean) {
        val wasActive = captureRunning || captureStarting
        captureRunning = false
        captureStarting = false
        pendingCandidates.clear()
        pendingStartResult?.error("capture_stopped", "Capture was stopped before startup completed.", null)
        pendingStartResult = null
        mainHandler.removeCallbacks(motionSamplingRunnable)
        mainHandler.removeCallbacks(bufferStateRunnable)
        mainHandler.removeCallbacks(syncFrameRunnable)
        releaseCameraSession()
        releaseEncoder()
        rollingBuffer.clear()
        motionDetector.reset()
        activeConfig = null
        clipSaveInFlight = false
        if (sendStoppedEvent && wasActive) {
            emit("CaptureStopped", emptyMap())
        }
        emitBufferState()
    }

    private fun releaseCameraSession() {
        try {
            captureSession?.stopRepeating()
        } catch (_: Exception) {
        }
        try {
            captureSession?.close()
        } catch (_: Exception) {
        }
        captureSession = null
        try {
            standardSession?.stopRepeating()
        } catch (_: Exception) {
        }
        try {
            standardSession?.close()
        } catch (_: Exception) {
        }
        standardSession = null
        try {
            cameraDevice?.close()
        } catch (_: Exception) {
        }
        cameraDevice = null
        try {
            previewSurface?.release()
        } catch (_: Exception) {
        }
        previewSurface = null
    }

    private fun releaseEncoder() {
        val codec: MediaCodec?
        val inputSurface: Surface?
        synchronized(codecLock) {
            drainLoopActive = false
            codec = encoder
            inputSurface = encoderInputSurface
            encoder = null
            encoderInputSurface = null
        }
        try {
            codec?.signalEndOfInputStream()
        } catch (_: Exception) {
        }
        try {
            codec?.stop()
        } catch (_: Exception) {
        }
        try {
            codec?.release()
        } catch (_: Exception) {
        }
        try {
            inputSurface?.release()
        } catch (_: Exception) {
        }
    }

    private fun drainEncoderLoop() {
        val info = MediaCodec.BufferInfo()
        while (true) {
            val codec = synchronized(codecLock) {
                if (!drainLoopActive) {
                    return
                }
                encoder
            } ?: return
            val index = try {
                codec.dequeueOutputBuffer(info, 10_000L)
            } catch (_: Exception) {
                return
            }
            when {
                index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    try {
                        rollingBuffer.setFormat(codec.outputFormat)
                    } catch (_: Exception) {
                    }
                }
                index >= 0 -> {
                    try {
                        val output = codec.getOutputBuffer(index)
                        if (
                            output != null &&
                                info.size > 0 &&
                                info.presentationTimeUs >= 0 &&
                                info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0
                        ) {
                            output.position(info.offset)
                            output.limit(info.offset + info.size)
                            val data = ByteArray(info.size)
                            output.get(data)
                            rollingBuffer.addSample(
                                EncodedVideoSample(
                                    data = data,
                                    presentationTimeUs = info.presentationTimeUs,
                                    flags = info.flags,
                                ),
                            )
                        }
                    } catch (_: Exception) {
                    } finally {
                        try {
                            codec.releaseOutputBuffer(index, false)
                        } catch (_: Exception) {
                        }
                    }
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        return
                    }
                }
            }
        }
    }

    private fun sampleMotionFrame() {
        val view = previewView ?: return
        if (!view.isAvailable || !captureRunning) {
            return
        }
        val score = motionDetector.process(view) ?: return
        if (!score.triggered) {
            return
        }
        val nowMs = System.currentTimeMillis()
        if (nowMs - lastMotionTriggerMs < MOTION_TRIGGER_DEBOUNCE_MS) {
            return
        }
        lastMotionTriggerMs = nowMs
        val payload = mapOf(
            "score" to score.score,
            "changedRatio" to score.changedRatio,
            "timestampMs" to nowMs,
        )
        emit("MotionDetected", payload)
        saveRollingClip(
            triggerEpochMs = nowMs,
            motionScore = score.score,
            outputFile = nextClipFile(nowMs),
            result = null,
        )
    }

    private fun saveRollingClip(
        triggerEpochMs: Long,
        motionScore: Double,
        outputFile: File,
        result: MethodChannel.Result?,
    ) {
        if (clipSaveInFlight) {
            result?.error("clip_save_busy", "A rolling-buffer clip is already being saved.", null)
            return
        }
        val snapshot = rollingBuffer.snapshot()
        if (snapshot == null || snapshot.samples.isEmpty()) {
            val message = "Rolling buffer does not contain encoded video yet."
            result?.error("rolling_buffer_empty", message, null)
            sendError("rolling_buffer_empty", message)
            return
        }
        clipSaveInFlight = true
        clipSaverExecutor.execute {
            try {
                val saved = NativeClipSaver.save(snapshot, outputFile)
                mainHandler.post {
                    clipSaveInFlight = false
                    result?.success(saved.file.absolutePath)
                    emit(
                        "ClipSaved",
                        mapOf(
                            "path" to saved.file.absolutePath,
                            "durationMs" to saved.durationMs,
                            "frameCount" to saved.frameCount,
                            "triggerEpochMs" to triggerEpochMs,
                            "motionScore" to motionScore,
                            "width" to snapshot.width,
                            "height" to snapshot.height,
                            "fps" to (saved.achievedFps ?: snapshot.targetFps.toDouble()),
                            "targetFps" to snapshot.targetFps,
                            "sizeBytes" to saved.file.length(),
                        ),
                    )
                    log(
                        "ClipSaver",
                        "Saved ${saved.file.absolutePath} frames=${saved.frameCount} " +
                            "durationMs=${saved.durationMs} fps=${saved.achievedFps} " +
                            "bytes=${saved.file.length()}",
                    )
                }
            } catch (error: Exception) {
                outputFile.delete()
                mainHandler.post {
                    clipSaveInFlight = false
                    result?.error(
                        "clip_save_failed",
                        error.message ?: "Unable to save high-speed clip.",
                        null,
                    )
                    sendError(
                        "clip_save_failed",
                        error.message ?: "Unable to save high-speed clip.",
                    )
                }
            }
        }
    }

    private fun nextClipFile(epochMs: Long): File {
        val formatter = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
        val baseName = "Swing_${formatter.format(Date(epochMs))}"
        var file = File(clipDirectory, "$baseName.mp4")
        var index = 1
        while (file.exists()) {
            file = File(clipDirectory, "${baseName}_$index.mp4")
            index += 1
        }
        return file
    }

    private fun savedClipMaps(): List<Map<String, Any>> {
        return clipDirectory
            .listFiles { file -> file.isFile && file.extension.equals("mp4", ignoreCase = true) }
            .orEmpty()
            .sortedByDescending { it.lastModified() }
            .map { file ->
                mapOf(
                    "path" to file.absolutePath,
                    "displayName" to file.name,
                    "sizeBytes" to file.length(),
                    "createdAtEpochMs" to file.lastModified(),
                )
            }
    }

    private fun getCapabilities(): Map<String, Any> {
        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameras = mutableListOf<Map<String, Any>>()
        for (cameraId in manager.cameraIdList) {
            val characteristics = try {
                manager.getCameraCharacteristics(cameraId)
            } catch (_: Exception) {
                continue
            }
            val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val highSpeedSizes = map?.highSpeedVideoSizes?.toList().orEmpty()
            val highSpeedRanges = map?.highSpeedVideoFpsRanges?.toList().orEmpty()
            val supportsHighSpeed = highSpeedSizes.isNotEmpty() && highSpeedRanges.isNotEmpty()
            val sizePayload = highSpeedSizes.sortedWith(
                compareByDescending<Size> { it.width * it.height }.thenByDescending { it.width },
            ).map { size ->
                val rangesForSize = try {
                    map?.getHighSpeedVideoFpsRangesFor(size)?.toList().orEmpty()
                } catch (_: Exception) {
                    highSpeedRanges
                }
                mapOf(
                    "width" to size.width,
                    "height" to size.height,
                    "fpsRanges" to rangesForSize.map { range ->
                        mapOf("lower" to range.lower, "upper" to range.upper)
                    },
                    "fps" to rangesForSize.map { it.upper }.toSet().sorted(),
                )
            }
            cameras.add(
                mapOf(
                    "cameraId" to cameraId,
                    "lensDirection" to lensDirectionLabel(facing),
                    "supportsHighSpeed" to supportsHighSpeed,
                    "highSpeedVideoSizes" to sizePayload,
                    "highSpeedFpsRanges" to highSpeedRanges.map { range ->
                        mapOf("lower" to range.lower, "upper" to range.upper)
                    },
                ),
            )
        }
        val preferred = selectCaptureCandidates(emptyMap<Any, Any>()).firstOrNull()
        return mapOf(
            "cameras" to cameras,
            "supportsHighSpeed" to cameras.any { it["supportsHighSpeed"] == true },
            "preferred" to (preferred?.toMap() ?: emptyMap<String, Any>()),
            "rollingSeconds" to DEFAULT_ROLLING_SECONDS,
            "codec" to MediaFormat.MIMETYPE_VIDEO_AVC,
        )
    }

    private fun selectCaptureCandidates(
        @Suppress("UNUSED_PARAMETER") args: Map<*, *>,
    ): List<NativeHighSpeedConfig> {
        val priorities = captureProfilePriority()

        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val cameraIds = manager.cameraIdList.sortedWith(
            compareBy<String> { cameraId ->
                val facing = try {
                    manager.getCameraCharacteristics(cameraId)
                        .get(CameraCharacteristics.LENS_FACING)
                } catch (_: Exception) {
                    null
                }
                when (facing) {
                    CameraCharacteristics.LENS_FACING_BACK -> 0
                    CameraCharacteristics.LENS_FACING_EXTERNAL -> 1
                    CameraCharacteristics.LENS_FACING_FRONT -> 2
                    else -> 3
                }
            }.thenBy { it },
        )

        val candidates = mutableListOf<NativeHighSpeedConfig>()
        val seen = mutableSetOf<String>()
        for (profile in priorities) {
            val desiredSize = Size(profile.width, profile.height)
            val desiredFps = profile.fps
            for (cameraId in cameraIds) {
                val characteristics = try {
                    manager.getCameraCharacteristics(cameraId)
                } catch (_: Exception) {
                    continue
                }
                val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    ?: continue
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)

                if (desiredFps >= 60) {
                    val availableSizes = map.highSpeedVideoSizes?.toList().orEmpty()
                    val size = availableSizes.firstOrNull {
                        it.width == desiredSize.width && it.height == desiredSize.height
                    }
                    if (size != null) {
                        val ranges = try {
                            map.getHighSpeedVideoFpsRangesFor(size).toList()
                        } catch (_: Exception) {
                            map.highSpeedVideoFpsRanges?.toList().orEmpty()
                        }
                        val range = selectRangeForFps(ranges, desiredFps)
                        if (range != null) {
                            val config = NativeHighSpeedConfig(
                                cameraId = cameraId,
                                facing = facing,
                                size = size,
                                fpsRange = range,
                                targetFps = minOf(range.upper, desiredFps),
                                bitrateBps = bitrateFor(size, desiredFps),
                                orientationHintDegrees = videoOrientationHintForCamera(characteristics),
                                constrainedHighSpeed = true,
                            )
                            val key = "${config.cameraId}:${config.size.width}x${config.size.height}:" +
                                "${config.targetFps}:hfr"
                            if (seen.add(key)) {
                                candidates.add(config)
                            }
                        }
                    }
                }

                if (desiredFps <= 60) {
                    val recorderSizes = map.getOutputSizes(MediaRecorder::class.java)
                        ?.toList()
                        .orEmpty()
                    val size = recorderSizes.firstOrNull {
                        it.width == desiredSize.width && it.height == desiredSize.height
                    } ?: continue
                    val ranges = characteristics
                        .get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                        ?.toList()
                        .orEmpty()
                    val range = selectStandardRangeForFps(ranges, desiredFps) ?: continue
                    val config = NativeHighSpeedConfig(
                        cameraId = cameraId,
                        facing = facing,
                        size = size,
                        fpsRange = range,
                        targetFps = desiredFps,
                        bitrateBps = bitrateFor(size, desiredFps),
                        orientationHintDegrees = videoOrientationHintForCamera(characteristics),
                        constrainedHighSpeed = false,
                    )
                    val key = "${config.cameraId}:${config.size.width}x${config.size.height}:" +
                        "${config.targetFps}:standard"
                    if (seen.add(key)) {
                        candidates.add(config)
                    }
                }
            }
        }
        return candidates
    }

    private fun selectRangeForFps(ranges: List<Range<Int>>, desiredFps: Int): Range<Int>? {
        if (ranges.isEmpty()) {
            return null
        }
        return ranges
            .filter { it.upper == desiredFps }
            .sortedWith(
                compareBy<Range<Int>> { if (it.lower == it.upper) 0 else 1 }
                    .thenBy { abs(it.upper - desiredFps) }
                    .thenByDescending { it.lower },
            )
            .firstOrNull()
    }

    private fun selectStandardRangeForFps(ranges: List<Range<Int>>, desiredFps: Int): Range<Int>? {
        if (ranges.isEmpty()) {
            return null
        }
        return ranges
            .filter { it.upper >= desiredFps }
            .sortedWith(
                compareBy<Range<Int>> { abs(it.upper - desiredFps) }
                    .thenBy { if (it.lower == it.upper) 0 else 1 }
                    .thenByDescending { it.lower },
            )
            .firstOrNull()
    }

    private fun bitrateFor(size: Size, fps: Int): Int {
        val pixels = size.width * size.height
        val base1080p30 = 12_000_000.0
        val scale = (pixels / (1920.0 * 1080.0)) * (fps / 30.0)
        return (base1080p30 * scale).roundToInt().coerceIn(8_000_000, 80_000_000)
    }

    private fun videoOrientationHintForCamera(
        characteristics: CameraCharacteristics,
    ): Int {
        val sensorOrientation =
            characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val deviceRotation = displayRotationDegrees()
        val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
        return if (facing == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensorOrientation + deviceRotation) % 360
        } else {
            (sensorOrientation - deviceRotation + 360) % 360
        }
    }

    private fun displayRotationDegrees(): Int {
        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity.display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            activity.windowManager.defaultDisplay.rotation
        }
        return when (rotation) {
            Surface.ROTATION_0 -> 0
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
    }

    private fun emit(type: String, payload: Map<String, Any?>) {
        val event = mutableMapOf<String, Any?>("type" to type)
        event.putAll(payload)
        mainHandler.post {
            eventSink?.success(event)
        }
    }

    private fun sendError(code: String, message: String) {
        emit("Error", mapOf("code" to code, "message" to message))
    }

    private fun log(area: String, message: String) {
        if (debugLogging) {
            Log.d(HIGH_SPEED_TAG, "[$area] $message")
        } else {
            Log.i(HIGH_SPEED_TAG, "[$area] $message")
        }
    }

    private fun emitBufferState() {
        val config = activeConfig
        val targetFps = config?.targetFps ?: 120
        val metrics = rollingBuffer.metrics()
        val bufferWindowMs = rollingSeconds * 1000
        emit(
            "buffer_state",
            mapOf(
                "buffering" to (captureRunning || captureStarting),
                "completedSegmentCount" to 0,
                "segmentSliceMs" to bufferWindowMs,
                "queueFrameCapacity" to targetFps * rollingSeconds,
                "queueDurationMs" to bufferWindowMs,
                "bufferedFrameCount" to metrics.sampleCount,
                "bufferedDurationMs" to (metrics.durationUs / 1000L),
                "bufferedBytes" to metrics.sizeBytes,
                "keyFrameCount" to metrics.keyFrameCount,
                "videoFpsMode" to when {
                    targetFps >= 120 -> "fps120"
                    targetFps >= 60 -> "fps60"
                    else -> "standard"
                },
                "targetFps" to targetFps.toDouble(),
                "profileWidth" to (config?.size?.width ?: 0),
                "profileHeight" to (config?.size?.height ?: 0),
                "achievedFps" to metrics.achievedFps,
                "highSpeed" to (config?.constrainedHighSpeed == true),
                "segmentRecording" to captureRunning,
                "segmentStarting" to captureStarting,
            ),
        )
    }
}

internal class EncodedRollingBuffer {
    private val samples = ArrayDeque<EncodedVideoSample>()
    private var format: MediaFormat? = null
    private var windowUs: Long = DEFAULT_ROLLING_SECONDS * 1_000_000L
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
    ) {
        samples.clear()
        format = null
        this.windowUs = windowUs
        this.targetFps = targetFps
        this.width = width
        this.height = height
        this.orientationHintDegrees = orientationHintDegrees
    }

    @Synchronized
    fun clear() {
        samples.clear()
        format = null
    }

    @Synchronized
    fun setFormat(mediaFormat: MediaFormat) {
        format = mediaFormat
    }

    @Synchronized
    fun addSample(sample: EncodedVideoSample) {
        samples.addLast(sample)
        val cutoff = sample.presentationTimeUs - windowUs
        var latestKeyFrameIndexAtCutoff = 0
        var index = 0
        for (buffered in samples) {
            if (buffered.presentationTimeUs > cutoff) {
                break
            }
            if (buffered.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) {
                latestKeyFrameIndexAtCutoff = index
            }
            index += 1
        }
        repeat(latestKeyFrameIndexAtCutoff) {
            samples.removeFirst()
        }
    }

    @Synchronized
    fun metrics(): RollingBufferMetrics {
        if (samples.isEmpty()) {
            return RollingBufferMetrics(
                sampleCount = 0,
                durationUs = 0L,
                sizeBytes = 0L,
                keyFrameCount = 0,
                achievedFps = null,
            )
        }
        val durationUs =
            (samples.last().presentationTimeUs - samples.first().presentationTimeUs)
                .coerceAtLeast(0L)
        val achievedFps = if (samples.size > 1 && durationUs > 0L) {
            (samples.size - 1) * 1_000_000.0 / durationUs.toDouble()
        } else {
            null
        }
        return RollingBufferMetrics(
            sampleCount = samples.size,
            durationUs = durationUs,
            sizeBytes = samples.sumOf { it.data.size.toLong() },
            keyFrameCount = samples.count {
                it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
            },
            achievedFps = achievedFps,
        )
    }

    @Synchronized
    fun snapshot(): EncodedBufferSnapshot? {
        val mediaFormat = format ?: return null
        if (samples.isEmpty()) {
            return null
        }
        val sampleCopy = samples.toList()
        val keyIndex = sampleCopy.indexOfFirst {
            it.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0
        }
        if (keyIndex < 0) {
            return null
        }
        return EncodedBufferSnapshot(
            format = mediaFormat,
            samples = sampleCopy.drop(keyIndex),
            targetFps = targetFps,
            width = width,
            height = height,
            orientationHintDegrees = orientationHintDegrees,
        )
    }
}

private object NativeClipSaver {
    fun save(snapshot: EncodedBufferSnapshot, outputFile: File): SavedClipResult {
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }
        if (snapshot.samples.isEmpty()) {
            throw IllegalStateException("Rolling buffer has no keyframe-backed samples.")
        }
        val muxer = MediaMuxer(
            outputFile.absolutePath,
            MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
        )
        var muxerStarted = false
        var writtenFrameCount = 0
        try {
            snapshot.format.setInteger(MediaFormat.KEY_FRAME_RATE, snapshot.targetFps)
            val trackIndex = muxer.addTrack(snapshot.format)
            muxer.setOrientationHint(snapshot.orientationHintDegrees)
            muxer.start()
            muxerStarted = true
            val firstPtsUs = snapshot.samples.first().presentationTimeUs
            var previousPtsUs = firstPtsUs
            val info = MediaCodec.BufferInfo()
            for (sample in snapshot.samples) {
                if (sample.data.isEmpty()) {
                    continue
                }
                val ptsUs = (sample.presentationTimeUs - firstPtsUs).coerceAtLeast(0L)
                if (ptsUs < previousPtsUs - firstPtsUs) {
                    continue
                }
                val flags = sample.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME
                info.set(0, sample.data.size, ptsUs, flags)
                muxer.writeSampleData(trackIndex, ByteBuffer.wrap(sample.data), info)
                previousPtsUs = sample.presentationTimeUs
                writtenFrameCount += 1
            }
            if (writtenFrameCount == 0) {
                throw IllegalStateException("No encoded video samples were written.")
            }
        } finally {
            if (muxerStarted) {
                try {
                    muxer.stop()
                } catch (_: Exception) {
                }
            }
            try {
                muxer.release()
            } catch (_: Exception) {
            }
        }
        return inspectSavedClip(outputFile, writtenFrameCount)
    }

    private fun inspectSavedClip(
        outputFile: File,
        expectedFrameCount: Int,
    ): SavedClipResult {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(outputFile.absolutePath)
            val videoTrack = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index)
                    .getString(MediaFormat.KEY_MIME)
                    ?.startsWith("video/") == true
            } ?: throw IllegalStateException("Saved MP4 does not contain a video track.")
            extractor.selectTrack(videoTrack)
            var frameCount = 0
            var firstPtsUs = -1L
            var lastPtsUs = -1L
            while (true) {
                val ptsUs = extractor.sampleTime
                if (ptsUs < 0L) {
                    break
                }
                if (firstPtsUs < 0L) {
                    firstPtsUs = ptsUs
                }
                lastPtsUs = ptsUs
                frameCount += 1
                if (!extractor.advance()) {
                    break
                }
            }
            if (frameCount <= 0 || firstPtsUs < 0L || lastPtsUs < firstPtsUs) {
                throw IllegalStateException("Saved MP4 video track has no readable samples.")
            }
            if (frameCount != expectedFrameCount) {
                throw IllegalStateException(
                    "Saved MP4 sample count mismatch: wrote=$expectedFrameCount read=$frameCount.",
                )
            }
            val durationMs = (lastPtsUs - firstPtsUs) / 1000L
            return SavedClipResult(
                file = outputFile,
                durationMs = durationMs,
                frameCount = frameCount,
                achievedFps = if (frameCount > 1 && durationMs > 0L) {
                    (frameCount - 1) * 1000.0 / durationMs.toDouble()
                } else {
                    null
                },
            )
        } finally {
            extractor.release()
        }
    }
}

private data class MotionScore(
    val score: Double,
    val changedRatio: Double,
    val triggered: Boolean,
)

private class NativeMotionDetector(
    private val sampleWidth: Int,
    private val sampleHeight: Int,
    sensitivity: Double,
) {
    private val pixelBuffer = IntArray(sampleWidth * sampleHeight)
    private val previousLuma = IntArray(sampleWidth * sampleHeight)
    private var bitmap: Bitmap? = null
    private var hasPrevious = false
    private var consecutiveHits = 0
    private var sensitivityValue = DEFAULT_SENSITIVITY

    init {
        setSensitivity(sensitivity)
    }

    fun setSensitivity(value: Double) {
        sensitivityValue = value.coerceIn(0.0, 1.0)
    }

    fun reset() {
        hasPrevious = false
        consecutiveHits = 0
    }

    fun process(view: TextureView): MotionScore? {
        val localBitmap = bitmap
            ?.takeIf { !it.isRecycled && it.width == sampleWidth && it.height == sampleHeight }
            ?: Bitmap.createBitmap(sampleWidth, sampleHeight, Bitmap.Config.ARGB_8888).also {
                bitmap = it
            }
        try {
            view.getBitmap(localBitmap)
        } catch (_: Exception) {
            return null
        }
        localBitmap.getPixels(pixelBuffer, 0, sampleWidth, 0, 0, sampleWidth, sampleHeight)

        var changed = 0
        var total = 0
        var diffSum = 0L
        val xStart = sampleWidth / 10
        val xEnd = sampleWidth - xStart
        val yStart = sampleHeight / 8
        val yEnd = sampleHeight - yStart
        var index: Int
        for (y in yStart until yEnd step 2) {
            index = y * sampleWidth + xStart
            for (x in xStart until xEnd step 2) {
                val rgb = pixelBuffer[index]
                val r = rgb shr 16 and 0xff
                val g = rgb shr 8 and 0xff
                val b = rgb and 0xff
                val luma = (r * 30 + g * 59 + b * 11) / 100
                if (hasPrevious) {
                    val diff = abs(luma - previousLuma[index])
                    diffSum += diff.toLong()
                    if (diff > 28) {
                        changed += 1
                    }
                    total += 1
                }
                previousLuma[index] = luma
                index += 2
            }
        }

        if (!hasPrevious || total == 0) {
            hasPrevious = true
            return MotionScore(score = 0.0, changedRatio = 0.0, triggered = false)
        }

        val changedRatio = changed.toDouble() / total.toDouble()
        val averageDiff = diffSum.toDouble() / total.toDouble()
        val ratioThreshold = 0.16 - sensitivityValue * 0.10
        val diffThreshold = 16.0 - sensitivityValue * 8.0
        val hit = changedRatio >= ratioThreshold && averageDiff >= diffThreshold
        consecutiveHits = if (hit) consecutiveHits + 1 else 0
        val score = ((changedRatio / ratioThreshold) * 0.7 + (averageDiff / diffThreshold) * 0.3)
            .coerceIn(0.0, 3.0)
        return MotionScore(
            score = score,
            changedRatio = changedRatio,
            triggered = consecutiveHits >= 2,
        )
    }
}

private fun lensDirectionLabel(facing: Int?): String {
    return when (facing) {
        CameraCharacteristics.LENS_FACING_FRONT -> "front"
        CameraCharacteristics.LENS_FACING_BACK -> "back"
        CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
        else -> "camera"
    }
}
