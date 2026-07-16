package com.lumiaiq.MotionCapture

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraConstrainedHighSpeedCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CaptureFailure
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.Image
import android.media.MediaMuxer
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Range
import android.util.Size
import android.view.Surface
import android.view.TextureView
import android.view.View
import androidx.camera.camera2.interop.Camera2Interop
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.core.AspectRatio
import androidx.camera.core.Camera
import androidx.camera.core.CameraSelector
import androidx.camera.core.ExperimentalGetImage
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.ZoomState
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.PendingRecording
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.core.content.ContextCompat
import androidx.lifecycle.Observer
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseDetector
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.roundToInt

private const val ROLLING_BUFFER_TARGET_FPS = 120
private const val ROLLING_BUFFER_FRAME_CAPACITY = 480
private const val ROLLING_BUFFER_QUEUE_MS =
    ROLLING_BUFFER_FRAME_CAPACITY * 1000L / ROLLING_BUFFER_TARGET_FPS
private const val MIN_REQUIRED_HIGH_SPEED_EXPORT_FPS = 55.0
private const val HIGH_SPEED_EXPORT_FPS_TOLERANCE = 0.90
private const val ROLLING_BUFFER_LOG = "NativeRollingBuffer"
private const val STARTUP_BUFFER_TEST_LOG = "StartupBufferTest"
private const val HIGH_SPEED_SELF_TEST_LOG = "HighSpeedBufferSelfTest"

internal fun isCamera2OwnedCaptureMethod(method: String): Boolean {
    return method == "startPreview" ||
        method == "stopPreview" ||
        method == "switchCamera" ||
        method == "setZoomRatio" ||
        method == "getCapabilities" ||
        method == "startCapture" ||
        method == "stopCapture" ||
        method == "startBuffering" ||
        method == "stopBuffering" ||
        method == "saveBufferedClip" ||
        method == "setSensitivity" ||
        method == "getSavedClips"
}

internal fun isCaptureStartBlockedByRtmp(method: String): Boolean {
    return method == "startCapture" ||
        method == "startBuffering" ||
        method == "saveBufferedClip"
}

private class LoggingMethodResult(
    private val tag: String,
    private val operation: String,
) : MethodChannel.Result {
    override fun success(result: Any?) {
        Log.i(tag, "$operation succeeded: $result")
    }

    override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
        Log.e(tag, "$operation failed code=$errorCode message=$errorMessage")
    }

    override fun notImplemented() {
        Log.e(tag, "$operation not implemented")
    }
}

private data class BufferedSegment(
    val path: String,
    val startEpochMs: Long,
    val endEpochMs: Long,
    val targetFps: Int? = null,
)

private data class ZoomLens(
    val logicalCameraId: String,
    val physicalCameraId: String?,
    val baseZoom: Float,
    val maxDigitalZoom: Float,
) {
    val selectionId: String get() = physicalCameraId ?: logicalCameraId
}

private data class HighSpeedRecordingConfig(
    val cameraId: String,
    val fpsRange: Range<Int>,
    val targetFps: Int,
    val size: Size,
    val orientationHintDegrees: Int,
    val constrainedHighSpeed: Boolean,
) {
    val failureKey: String
        get() = "$cameraId:${size.width}x${size.height}:$targetFps:" +
            "${if (constrainedHighSpeed) "hfr" else "native"}:${fpsRange.lower}-${fpsRange.upper}"
}

private data class StartupEncoderDrainState(
    var trackIndex: Int = -1,
    var muxerStarted: Boolean = false,
    var frameCount: Int = 0,
    var firstPtsUs: Long = -1L,
    var lastPtsUs: Long = -1L,
)

private data class DebugVideoStats(
    val frameCount: Int,
    val durationMs: Long,
    val achievedFps: Double?,
)

class NativeCapturePipeline(
    private val activity: FlutterActivity,
) {
    private val clipsDirectory: File by lazy {
        File(activity.filesDir, "native_buffer").apply {
            if (!exists()) {
                mkdirs()
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val analysisExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainExecutor = ContextCompat.getMainExecutor(activity)
    private val poseDetector: PoseDetector = PoseDetection.getClient(
        PoseDetectorOptions.Builder()
            .setDetectorMode(PoseDetectorOptions.STREAM_MODE)
            .build(),
    )
    private val poseFrameIntervalMs = 50L
    private val maxPreviewPoseBitmapWidth = 640
    private val maxHighSpeedPreviewPoseBitmapWidth = 384
    private val highSpeedPoseSamplingRunnable = Runnable {
        sampleHighSpeedPreviewPoseFrame()
        scheduleHighSpeedPoseSamplingIfNeeded()
    }
    private val androidHighSpeedCaptureEngine = AndroidHighSpeedCaptureEngine(activity)

    private var eventSink: EventChannel.EventSink? = null
    private var previewView: TextureView? = null
    private var lastRenderedPreviewTexture: android.graphics.SurfaceTexture? = null
    private var previewRequested = false
    private var detectionEnabled = false
    private var isProcessingPose = false
    private var lastPoseAnalysisStartedMs = 0L
    @Volatile
    private var debugSelfTestActive = false
    @Volatile
    private var debugSelfTestPoseAttempts = 0
    @Volatile
    private var debugSelfTestPoseResults = 0
    private var lensFacing = CameraSelector.LENS_FACING_BACK
    private var selectedLensId: String? = null
    private var requestedZoomRatio = 1f

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var previewUseCase: Preview? = null
    private var analysisUseCase: ImageAnalysis? = null
    private var recorder: Recorder? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var highSpeedCameraDevice: CameraDevice? = null
    private var highSpeedSession: CameraConstrainedHighSpeedCaptureSession? = null
    private var nativeVideoSession: CameraCaptureSession? = null
    private var highSpeedRecorder: MediaRecorder? = null
    private var highSpeedPreviewSurface: Surface? = null
    private var highSpeedSegmentStarting = false
    private var currentHighSpeedSegmentActive = false
    private var highSpeedStopRequestedWhileStarting = false
    private var highSpeedCaptureFailureReported = false
    private var highSpeedFallbackActive = false
    private var activeHighSpeedTargetFps: Int? = null
    private var activeHighSpeedSize: Size? = null
    private var activeHighSpeedCameraId: String? = null
    private var activeHighSpeedConfigKey: String? = null
    private var startupBufferTestActive = false
    private val failedHighSpeedConfigKeys = mutableSetOf<String>()

    private var bufferingEnabled = false
    private var preRollMs = ROLLING_BUFFER_QUEUE_MS
    private var postRollMs = 0L
    /**
     * Wire value from Dart [VideoFpsMode] (`standard`, `fps60`, `fps120`, `fps240`, `maxSupported`).
     * Legacy `VideoFpsPreference` enum names are still accepted for rebinds.
     */
    private var videoFpsMode: String = "fps60"
    private var lastAchievedFps: Double? = null
    private var lastLoggedBufferStateKey: String? = null
    /** Wall-clock slice length for each rolling file; recomputed when buffering arms. */
    private var segmentDurationMs = 1000L

    private val mergeExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val clipRtmpExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val startupTestExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var rtmpLive: RtmpLiveBroadcaster? = null
    private val swingClipPublisher = SwingClipRtmpPublisher(activity, clipRtmpExecutor)

    private val zoomObserver = Observer<ZoomState> { sendCameraState() }
    private val completedSegments = ArrayDeque<BufferedSegment>()
    private var currentRecording: Recording? = null
    private var currentSegmentPath: String? = null
    private var currentSegmentStartEpochMs = 0L
    private var currentSegmentRestartAfterFinalize = false
    private var currentSegmentFinalizeCallback: ((BufferedSegment?) -> Unit)? = null

    private val segmentRotationRunnable = Runnable {
        sealCurrentSegment(restartAfterFinalize = bufferingEnabled, callback = null)
    }

    fun attachEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        androidHighSpeedCaptureEngine.attachEventSink(sink)
    }

    fun createPreviewFactory(): PlatformViewFactory {
        return NativePreviewViewFactory(this)
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (
            isDedicatedHighSpeedMethod(call.method) &&
            rtmpLive != null &&
            isCaptureStartBlockedByRtmp(call.method)
        ) {
            result.error(
                "camera_busy_rtmp",
                "Capture is unavailable while RTMP streaming owns the camera.",
                null,
            )
            return
        }
        val camera2HandlesMethod =
            rtmpLive == null ||
                (call.method != "startPreview" && call.method != "stopPreview")
        if (isDedicatedHighSpeedMethod(call.method) && camera2HandlesMethod) {
            if (androidHighSpeedCaptureEngine.handleMethodCall(call, result)) {
                when (call.method) {
                    "startPreview" -> previewRequested = true
                    "stopPreview" -> previewRequested = false
                }
                scheduleHighSpeedPoseSamplingIfNeeded()
                return
            }
        }
        when (call.method) {
            "startPreview" -> {
                previewRequested = true
                ensureCameraProvider()
                bindUseCasesIfReady()
                result.success(null)
            }
            "queryRecordingCapability" -> {
                result.success(queryRecordingCapability())
            }
            "stopPreview" -> {
                stopPreview()
                result.success(null)
            }
            "startDetection" -> {
                detectionEnabled = true
                scheduleHighSpeedPoseSamplingIfNeeded()
                result.success(null)
            }
            "stopDetection" -> {
                detectionEnabled = false
                mainHandler.removeCallbacks(highSpeedPoseSamplingRunnable)
                result.success(null)
            }
            "startBuffering" -> {
                val args = call.arguments as? Map<*, *>
                preRollMs = ROLLING_BUFFER_QUEUE_MS
                postRollMs = 0L
                val requestedFpsMode =
                    args?.get("videoFpsMode") as? String
                        ?: args?.get("videoFpsPreference") as? String
                val newMode = requestedFpsMode ?: videoFpsMode
                val modeChanged = newMode != videoFpsMode
                videoFpsMode = newMode
                if (modeChanged || videoFpsMode != "standard") {
                    failedHighSpeedConfigKeys.clear()
                    highSpeedFallbackActive = false
                }
                Log.i(
                    ROLLING_BUFFER_LOG,
                    "startBuffering mode=$videoFpsMode modeChanged=$modeChanged",
                )

                bufferingEnabled = true
                segmentDurationMs = computeSegmentSliceMs(preRollMs, postRollMs)

                val canRebuild =
                    previewRequested &&
                        previewView != null &&
                        (
                            isHighFpsRollingBuffer() ||
                                modeChanged ||
                                analysisUseCase != null
                            )

                if (canRebuild) {
                    if (hasActiveOrStartingSegment()) {
                        sealCurrentSegment(restartAfterFinalize = false) {
                            mainHandler.post {
                                bindUseCasesIfReady()
                                sendBufferState()
                            }
                        }
                    } else {
                        bindUseCasesIfReady()
                        sendBufferState()
                    }
                } else {
                    sendBufferState()
                    if (currentRecording == null) {
                        startNewSegment()
                    }
                }
                result.success(null)
            }
            "stopBuffering" -> {
                stopBuffering(discardSegments = true)
                result.success(null)
            }
            "saveBufferedClip" -> {
                val args = call.arguments as? Map<*, *>
                val outputPath = args?.get("outputPath") as? String
                val triggerEpochMs = (args?.get("triggerEpochMs") as? Number)?.toLong()
                if (
                    outputPath == null ||
                        triggerEpochMs == null
                ) {
                    result.error(
                        "invalid_args",
                        "saveBufferedClip requires outputPath/triggerEpochMs",
                        null
                    )
                    return
                }
                preRollMs = ROLLING_BUFFER_QUEUE_MS
                postRollMs = 0L
                saveBufferedClip(
                    outputPath = outputPath,
                    triggerEpochMs = triggerEpochMs,
                    result = result,
                )
            }
            "runStartupBufferTest" -> {
                val args = call.arguments as? Map<*, *>
                val durationMs = ((args?.get("durationMs") as? Number)?.toInt()
                    ?: ROLLING_BUFFER_QUEUE_MS.toInt())
                    .coerceIn(1000, 10_000)
                val requestedFpsMode = args?.get("videoFpsMode") as? String
                if (!requestedFpsMode.isNullOrBlank()) {
                    videoFpsMode = requestedFpsMode
                }
                runStartupBufferTest(durationMs, result)
            }
            "switchCamera" -> {
                lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
                    CameraSelector.LENS_FACING_FRONT
                } else {
                    CameraSelector.LENS_FACING_BACK
                }
                selectedLensId = null
                requestedZoomRatio = 1f
                failedHighSpeedConfigKeys.clear()
                highSpeedFallbackActive = false
                if (hasActiveOrStartingSegment()) {
                    sealCurrentSegment(restartAfterFinalize = false) {
                        mainHandler.post { bindUseCasesIfReady() }
                    }
                } else {
                    bindUseCasesIfReady()
                }
                result.success(mapOf("lensDirection" to lensDirectionLabel()))
            }
            "setZoomRatio" -> {
                val ratio = (call.arguments as? Number)?.toFloat() ?: 1f
                applyLogicalZoom(ratio)
                result.success(null)
            }
            "startRtmpStream" -> {
                val args = call.arguments as? Map<*, *>
                val url = args?.get("url") as? String
                val idleBr = (args?.get("idleBitrateBps") as? Number)?.toInt() ?: 2_500_000
                val swingBr = (args?.get("swingBitrateBps") as? Number)?.toInt() ?: 4_500_000
                if (url.isNullOrBlank()) {
                    result.error("invalid_args", "startRtmpStream requires url", null)
                    return
                }
                val tv = previewView
                if (tv == null) {
                    result.error("no_preview", "Preview TextureView not attached yet.", null)
                    return
                }
                mainHandler.post {
                    try {
                        stopBuffering(discardSegments = false)
                        androidHighSpeedCaptureEngine.stopCaptureForLegacyRebind()
                        cameraProvider?.unbindAll()
                        camera = null
                        previewUseCase = null
                        analysisUseCase = null
                        videoCapture = null
                        recorder = null
                        currentRecording = null
                        currentSegmentPath = null
                        currentSegmentFinalizeCallback = null

                        val checker = RtmpConnectChecker { m ->
                            mainHandler.post { eventSink?.success(m) }
                        }
                        rtmpLive?.stop()
                        val live = RtmpLiveBroadcaster(activity, checker)
                        rtmpLive = live
                        live.updateBitrates(idleBr, swingBr)
                        if (!live.start(tv, url, idleBr, swingBr)) {
                            rtmpLive = null
                            result.error("rtmp_start_failed", "Could not start RTMP encoder.", null)
                            androidHighSpeedCaptureEngine.resumeAfterExternalOwner()
                            return@post
                        }
                        live.attachPoseProcessor { image -> onRtmpPoseImage(image) }
                        result.success(null)
                    } catch (e: Exception) {
                        rtmpLive = null
                        result.error("rtmp_start_failed", e.message, null)
                        androidHighSpeedCaptureEngine.resumeAfterExternalOwner()
                    }
                }
            }
            "stopRtmpStream" -> {
                mainHandler.post {
                    rtmpLive?.stop()
                    rtmpLive = null
                    androidHighSpeedCaptureEngine.resumeAfterExternalOwner()
                    eventSink?.success(
                        mapOf(
                            "type" to "rtmp_state",
                            "state" to "stopped",
                        ),
                    )
                    result.success(null)
                }
            }
            "setRtmpSwingBitrate" -> {
                val args = call.arguments as? Map<*, *>
                val active = args?.get("swingActive") as? Boolean ?: false
                rtmpLive?.setSwingBitrateActive(active)
                result.success(null)
            }
            "sendSwingMarker" -> {
                val args = call.arguments as? Map<*, *>
                val phase = args?.get("phase") as? String ?: ""
                val swingId = args?.get("swingId") as? String ?: ""
                val weight = (args?.get("weight") as? Number)?.toDouble() ?: 0.0
                val triggerEpochMs = (args?.get("triggerEpochMs") as? Number)?.toLong() ?: 0L
                val preRollMs = (args?.get("preRollMs") as? Number)?.toInt() ?: 0
                val postRollMs = (args?.get("postRollMs") as? Number)?.toInt() ?: 0
                val score = (args?.get("score") as? Number)?.toDouble()
                val endedAt = (args?.get("endedAtEpochMs") as? Number)?.toLong()
                val w = weight.coerceIn(0.0, 1.0)
                val sc = (score ?: weight).coerceIn(0.0, 1.0)
                when (phase) {
                    "start" -> {
                        rtmpLive?.sendSwingDataFrame(
                            "onSwingStart",
                            mapOf(
                                "swingId" to swingId,
                                "weight" to w,
                                "score" to sc,
                                "triggerEpochMs" to triggerEpochMs.toDouble(),
                                "preRollMs" to preRollMs.toDouble(),
                                "postRollMs" to postRollMs.toDouble(),
                            ),
                        )
                    }
                    "end" -> {
                        rtmpLive?.sendSwingDataFrame(
                            "onSwingEnd",
                            mapOf(
                                "swingId" to swingId,
                                "weight" to w,
                                "endedAtEpochMs" to (endedAt ?: System.currentTimeMillis()).toDouble(),
                            ),
                        )
                    }
                }
                result.success(null)
            }
            "publishSwingClip" -> {
                val args = call.arguments as? Map<*, *>
                val url = args?.get("url") as? String
                val filePath = args?.get("filePath") as? String
                val swingId = args?.get("swingId") as? String ?: ""
                val weight = (args?.get("weight") as? Number)?.toDouble() ?: 0.0
                if (url.isNullOrBlank() || filePath.isNullOrBlank()) {
                    result.error("invalid_args", "publishSwingClip requires url and filePath", null)
                    return
                }
                swingClipPublisher.publish(
                    filePath = filePath,
                    url = url,
                    swingId = swingId,
                    weight = weight,
                ) { ok, err ->
                    mainHandler.post {
                        if (ok) {
                            result.success(null)
                        } else {
                            result.error("clip_rtmp_failed", err ?: "unknown", null)
                        }
                    }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun runDebugHighSpeedBufferSelfTest() {
        if (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) {
            Log.w(HIGH_SPEED_SELF_TEST_LOG, "Ignored outside a debug build.")
            return
        }
        val startEpochMs = System.currentTimeMillis()
        val requirePose = detectionEnabled
        debugSelfTestActive = true
        debugSelfTestPoseAttempts = 0
        debugSelfTestPoseResults = 0
        Log.i(HIGH_SPEED_SELF_TEST_LOG, "Starting 4-second encoded rolling-buffer test.")
        handleMethodCall(
            MethodCall(
                "startBuffering",
                mapOf(
                    "preRollMs" to 4000L,
                    "postRollMs" to 0L,
                    "sensitivity" to 0.55,
                    "debug" to true,
                ),
            ),
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    Log.i(HIGH_SPEED_SELF_TEST_LOG, "Capture started: $result")
                    val targetFps =
                        ((result as? Map<*, *>)?.get("fps") as? Number)?.toInt() ?: 0
                    mainHandler.postDelayed(
                        {
                            val outputFile = File(
                                activity.filesDir,
                                "high_speed_clips/selftest_$startEpochMs.mp4",
                            )
                            handleMethodCall(
                                MethodCall(
                                    "saveBufferedClip",
                                    mapOf(
                                        "outputPath" to outputFile.absolutePath,
                                        "triggerEpochMs" to System.currentTimeMillis(),
                                        "preRollMs" to 4000L,
                                        "postRollMs" to 0L,
                                    ),
                                ),
                                object : MethodChannel.Result {
                                    override fun success(result: Any?) {
                                        startupTestExecutor.execute {
                                            val stats = inspectDebugVideo(outputFile)
                                            val minimumFps = targetFps * 0.90
                                            val passed =
                                                stats != null &&
                                                    stats.durationMs >= 3800L &&
                                                    stats.frameCount > 0 &&
                                                    (stats.achievedFps ?: 0.0) >= minimumFps &&
                                                    outputFile.length() > 0L &&
                                                    (!requirePose ||
                                                        debugSelfTestPoseResults > 0)
                                            Log.i(
                                                HIGH_SPEED_SELF_TEST_LOG,
                                                "${if (passed) "PASS" else "FAIL"} " +
                                                    "path=$result targetFps=$targetFps " +
                                                    "frames=${stats?.frameCount} " +
                                                    "durationMs=${stats?.durationMs} " +
                                                    "fps=${stats?.achievedFps} " +
                                                    "bytes=${outputFile.length()} " +
                                                    "poseAttempts=$debugSelfTestPoseAttempts " +
                                                    "poseResults=$debugSelfTestPoseResults " +
                                                    "captureStillRunning=" +
                                                    androidHighSpeedCaptureEngine
                                                        .isRunningOrStarting,
                                            )
                                            stopDebugHighSpeedBufferTest()
                                        }
                                    }

                                    override fun error(
                                        errorCode: String,
                                        errorMessage: String?,
                                        errorDetails: Any?,
                                    ) {
                                        Log.e(
                                            HIGH_SPEED_SELF_TEST_LOG,
                                            "FAIL save code=$errorCode message=$errorMessage",
                                        )
                                        stopDebugHighSpeedBufferTest()
                                    }

                                    override fun notImplemented() {
                                        Log.e(HIGH_SPEED_SELF_TEST_LOG, "FAIL save not implemented")
                                    }
                                },
                            )
                        },
                        5200L,
                    )
                }

                override fun error(
                    errorCode: String,
                    errorMessage: String?,
                    errorDetails: Any?,
                ) {
                    Log.e(
                        HIGH_SPEED_SELF_TEST_LOG,
                        "FAIL start code=$errorCode message=$errorMessage",
                    )
                }

                override fun notImplemented() {
                    Log.e(HIGH_SPEED_SELF_TEST_LOG, "FAIL start not implemented")
                }
            },
        )
    }

    private fun stopDebugHighSpeedBufferTest() {
        debugSelfTestActive = false
        mainHandler.postDelayed(
            {
                androidHighSpeedCaptureEngine.handleMethodCall(
                    MethodCall("stopBuffering", null),
                    LoggingMethodResult(HIGH_SPEED_SELF_TEST_LOG, "stop"),
                )
            },
            500L,
        )
    }

    private fun inspectDebugVideo(file: File): DebugVideoStats? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(file.absolutePath)
            val videoTrack = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index)
                    .getString(MediaFormat.KEY_MIME)
                    ?.startsWith("video/") == true
            } ?: return null
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
                return null
            }
            val durationMs = (lastPtsUs - firstPtsUs) / 1000L
            return DebugVideoStats(
                frameCount = frameCount,
                durationMs = durationMs,
                achievedFps = if (frameCount > 1 && durationMs > 0L) {
                    (frameCount - 1) * 1000.0 / durationMs.toDouble()
                } else {
                    null
                },
            )
        } catch (_: Exception) {
            return null
        } finally {
            extractor.release()
        }
    }

    fun attachPreviewView(view: TextureView) {
        lastRenderedPreviewTexture = null
        previewView = view.apply {
            isOpaque = true
            surfaceTextureListener = object : TextureView.SurfaceTextureListener {
                override fun onSurfaceTextureAvailable(
                    surface: android.graphics.SurfaceTexture,
                    width: Int,
                    height: Int,
                ) {
                    androidHighSpeedCaptureEngine.onPreviewSurfaceAvailable(surface)
                    scheduleHighSpeedPoseSamplingIfNeeded()
                }

                override fun onSurfaceTextureSizeChanged(
                    surface: android.graphics.SurfaceTexture,
                    width: Int,
                    height: Int,
                ) = Unit

                override fun onSurfaceTextureDestroyed(surface: android.graphics.SurfaceTexture): Boolean {
                    if (
                        previewView === this@apply &&
                        lastRenderedPreviewTexture === surface
                    ) {
                        lastRenderedPreviewTexture = null
                    }
                    androidHighSpeedCaptureEngine.onPreviewSurfaceDestroyed(surface)
                    return true
                }

                override fun onSurfaceTextureUpdated(surface: android.graphics.SurfaceTexture) {
                    if (previewView !== this@apply) {
                        return
                    }
                    if (lastRenderedPreviewTexture === surface) {
                        return
                    }
                    lastRenderedPreviewTexture = surface
                    androidHighSpeedCaptureEngine.onPreviewFrameAvailable(surface)
                    scheduleHighSpeedPoseSamplingIfNeeded()
                }
            }
        }
        // Surface must exist before bind; Flutter may build the PlatformView slightly
        // after startPreview(), so always arm preview when the view attaches.
        previewRequested = true
        androidHighSpeedCaptureEngine.attachPreviewView(view)
    }

    fun detachPreviewView(view: TextureView) {
        androidHighSpeedCaptureEngine.detachPreviewView(view)
        if (previewView === view) {
            previewView = null
            lastRenderedPreviewTexture = null
        }
    }

    fun dispose() {
        rtmpLive?.stop()
        rtmpLive = null
        androidHighSpeedCaptureEngine.dispose()
        stopBuffering(discardSegments = true)
        previewRequested = false
        detectionEnabled = false
        isProcessingPose = false
        mainHandler.removeCallbacks(highSpeedPoseSamplingRunnable)
        eventSink = null
        previewView = null
        lastRenderedPreviewTexture = null
        camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
        cameraProvider?.unbindAll()
        poseDetector.close()
        analysisExecutor.shutdown()
        mergeExecutor.shutdown()
        clipRtmpExecutor.shutdown()
        startupTestExecutor.shutdown()
    }

    private fun stopPreview() {
        androidHighSpeedCaptureEngine.stopPreviewAndRelease()
        rtmpLive?.stop()
        rtmpLive = null
        previewRequested = false
        lastRenderedPreviewTexture = null
        stopBuffering(discardSegments = true)
        mainHandler.removeCallbacks(highSpeedPoseSamplingRunnable)
        camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
        cameraProvider?.unbindAll()
        previewUseCase = null
        analysisUseCase = null
        videoCapture = null
        recorder = null
        camera = null
    }

    private fun ensureCameraProvider() {
        if (cameraProvider != null) {
            return
        }
        val providerFuture = ProcessCameraProvider.getInstance(activity)
        providerFuture.addListener(
            {
                try {
                    cameraProvider = providerFuture.get()
                    bindUseCasesIfReady()
                } catch (error: Exception) {
                    sendError(
                        code = "camera_provider_failed",
                        message = error.message ?: "Unable to get camera provider.",
                    )
                }
            },
            mainExecutor,
        )
    }

    private fun isHighFpsRollingBuffer(): Boolean {
        return bufferingEnabled && videoFpsMode != "standard" && !highSpeedFallbackActive
    }

    private fun hasActiveOrStartingSegment(): Boolean {
        return currentRecording != null ||
            currentHighSpeedSegmentActive ||
            highSpeedSegmentStarting
    }

    private fun nominalTargetFpsForPreference(): Int {
        return when (videoFpsMode) {
            "fps60" -> 60
            "fps120" -> 120
            "fps240" -> 240
            "maxSupported" -> 240
            else -> 30
        }
    }

    private fun recommendedModeForMaxFps(maxFps: Int): String {
        return when {
            maxFps >= 240 -> "fps240"
            maxFps >= 120 -> "fps120"
            maxFps >= 60 -> "fps60"
            else -> "standard"
        }
    }

    private fun queryRecordingCapability(): Map<String, Any> {
        return try {
            val cameraManager =
                activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val lensCapabilities = zoomLensesForAllFacings().mapNotNull { lens ->
                val characteristics = cameraCharacteristicsForLens(cameraManager, lens)
                    ?: return@mapNotNull null
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                val supported = supportedFpsForCharacteristics(characteristics)
                val maxFps = supported.maxOrNull() ?: 30
                mutableMapOf<String, Any>(
                    "cameraId" to lens.selectionId,
                    "logicalCameraId" to lens.logicalCameraId,
                    "lensDirection" to lensDirectionLabel(facing),
                    "cameraLabel" to cameraCapabilityLabel(lens, facing),
                    "maxFps" to maxFps,
                    "supportedFps" to supported,
                ).also { payload ->
                    lens.physicalCameraId?.let { physicalId ->
                        payload["physicalCameraId"] = physicalId
                    }
                }
            }.sortedWith(
                compareBy<Map<String, Any>> {
                    when (it["lensDirection"] as? String) {
                        "back" -> 0
                        "front" -> 1
                        else -> 2
                    }
                }.thenBy {
                    (it["cameraLabel"] as? String).orEmpty()
                },
            )
            if (lensCapabilities.isEmpty()) {
                return mapOf(
                    "maxFps" to 30,
                    "supportedFps" to listOf(30),
                    "recommendedVideoFpsMode" to "standard",
                    "source" to "fallback",
                    "message" to "No camera devices were reported.",
                )
            }

            val normalized = commonSupportedFps(lensCapabilities)
            val maxFps = normalized.maxOrNull() ?: 30
            mapOf(
                "maxFps" to maxFps,
                "supportedFps" to normalized,
                "recommendedVideoFpsMode" to recommendedModeForMaxFps(maxFps),
                "source" to "camera2",
                "cameraLabel" to "across ${lensCapabilities.size} lenses",
                "lensCapabilities" to lensCapabilities,
            )
        } catch (error: Exception) {
            mapOf(
                "maxFps" to 30,
                "supportedFps" to listOf(30),
                "recommendedVideoFpsMode" to "standard",
                "source" to "fallback",
                "message" to (error.message ?: "Camera capability query failed."),
            )
        }
    }

    private fun supportedFpsForCharacteristics(
        characteristics: CameraCharacteristics,
    ): List<Int> {
        val supportedFps = mutableSetOf(30)
        characteristics
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.highSpeedVideoFpsRanges
            ?.forEach { range ->
                supportedFps.add(range.upper)
            }
        return normalizeFpsBuckets(supportedFps)
    }

    private fun normalizeFpsBuckets(values: Iterable<Int>): List<Int> {
        return values
            .filter { it > 0 }
            .map {
                when {
                    it >= 240 -> 240
                    it >= 120 -> 120
                    it >= 60 -> 60
                    else -> 30
                }
            }
            .toSet()
            .sorted()
    }

    @Suppress("UNCHECKED_CAST")
    private fun commonSupportedFps(
        lensCapabilities: List<Map<String, Any>>,
    ): List<Int> {
        var common: Set<Int>? = null
        for (capability in lensCapabilities) {
            val supported = capability["supportedFps"] as? List<Int> ?: listOf(30)
            common = common?.intersect(supported.toSet()) ?: supported.toSet()
        }
        return (common ?: setOf(30)).ifEmpty { setOf(30) }.sorted()
    }

    private fun cameraCapabilityLabel(lens: ZoomLens, facing: Int?): String {
        val direction = lensDirectionLabel(facing)
        if (direction == "back") {
            return "$direction ${String.format("%.1fx", lens.baseZoom)} lens"
        }
        return "$direction camera ${lens.selectionId}"
    }

    private fun lensDirectionLabel(facing: Int?): String {
        return when (facing) {
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "camera"
        }
    }

    private fun zoomLensesForAllFacings(): List<ZoomLens> {
        return listOf(
            CameraCharacteristics.LENS_FACING_BACK,
            CameraCharacteristics.LENS_FACING_FRONT,
            CameraCharacteristics.LENS_FACING_EXTERNAL,
        )
            .flatMap { facing -> zoomLensesForFacing(facing) }
            .distinctBy { it.selectionId }
    }

    private fun zoomLensesForFacing(facing: Int): List<ZoomLens> {
        return try {
            val cameraManager =
                activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val candidates = zoomLensCandidatesForFacing(cameraManager, facing)
            if (candidates.isEmpty()) {
                return emptyList()
            }
            val focalLengths = candidates
                .mapNotNull { (_, _, characteristics) ->
                    characteristics
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.firstOrNull()
                        ?.takeIf { it > 0f }
                }
            val referenceFocalLength = referenceFocalLengthForZoom(focalLengths)

            candidates
                .mapNotNull { (logicalCameraId, physicalCameraId, characteristics) ->
                    val focalLength = characteristics
                        .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
                        ?.firstOrNull()
                        ?.takeIf { it > 0f }
                        ?: return@mapNotNull null
                    val maxDigitalZoom = characteristics
                        .get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM)
                        ?.coerceAtLeast(1f)
                        ?: 1f
                    ZoomLens(
                        logicalCameraId = logicalCameraId,
                        physicalCameraId = physicalCameraId,
                        baseZoom = (focalLength / referenceFocalLength).coerceAtLeast(0.1f),
                        maxDigitalZoom = maxDigitalZoom,
                    )
                }
                .sortedBy { it.baseZoom }
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun zoomLensCandidatesForFacing(
        cameraManager: CameraManager,
        facing: Int,
    ): List<Triple<String, String?, CameraCharacteristics>> {
        val candidates = mutableListOf<Triple<String, String?, CameraCharacteristics>>()
        for (logicalCameraId in cameraManager.cameraIdList) {
            val logicalCharacteristics = cameraManager.getCameraCharacteristics(logicalCameraId)
            if (logicalCharacteristics.get(CameraCharacteristics.LENS_FACING) != facing) {
                continue
            }
            val physicalIds = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                logicalCharacteristics.physicalCameraIds
            } else {
                emptySet()
            }
            val physicalCandidates = physicalIds.mapNotNull { physicalId ->
                try {
                    Triple(
                        logicalCameraId,
                        physicalId,
                        cameraManager.getCameraCharacteristics(physicalId),
                    )
                } catch (_: Exception) {
                    null
                }
            }
            if (physicalCandidates.isNotEmpty()) {
                candidates.addAll(physicalCandidates)
            } else {
                candidates.add(Triple(logicalCameraId, null, logicalCharacteristics))
            }
        }
        return candidates
    }

    private fun referenceFocalLengthForZoom(focalLengths: List<Float>): Float {
        if (focalLengths.isEmpty()) {
            return 1f
        }
        return focalLengths
            .filter { it >= 3.5f }
            .minOrNull()
            ?: focalLengths.maxOrNull()
            ?: 1f
    }

    private fun cameraCharacteristicsForLens(
        cameraManager: CameraManager,
        lens: ZoomLens,
    ): CameraCharacteristics? {
        return try {
            cameraManager.getCameraCharacteristics(lens.physicalCameraId ?: lens.logicalCameraId)
        } catch (_: Exception) {
            try {
                cameraManager.getCameraCharacteristics(lens.logicalCameraId)
            } catch (_: Exception) {
                null
            }
        }
    }

    private fun selectedZoomLens(): ZoomLens? {
        val lenses = zoomLensesForFacing(lensFacing)
        if (lenses.isEmpty()) {
            return null
        }
        val selectedId = selectedLensId
        return lenses.firstOrNull { it.selectionId == selectedId }
            ?: lensForLogicalZoom(requestedZoomRatio, lenses)
    }

    private fun lensForLogicalZoom(
        ratio: Float,
        lenses: List<ZoomLens> = zoomLensesForFacing(lensFacing),
    ): ZoomLens? {
        if (lenses.isEmpty()) {
            return null
        }
        return lenses
            .filter { it.baseZoom <= ratio + 0.001f }
            .maxByOrNull { it.baseZoom }
            ?: lenses.first()
    }

    private fun logicalZoomRange(): Pair<Float, Float> {
        val lenses = zoomLensesForFacing(lensFacing)
        if (lenses.isEmpty()) {
            val zoomState = camera?.cameraInfo?.zoomState?.value
            return Pair(
                zoomState?.minZoomRatio ?: 1f,
                zoomState?.maxZoomRatio ?: 1f,
            )
        }
        val minZoom = lenses.minOf { it.baseZoom.toDouble() }.toFloat()
        val maxZoom = lenses
            .maxOf { (it.baseZoom * it.maxDigitalZoom).toDouble() }
            .toFloat()
            .coerceAtLeast(minZoom)
        return Pair(minZoom, maxZoom)
    }

    private fun applyLogicalZoom(ratio: Float) {
        val range = logicalZoomRange()
        requestedZoomRatio = ratio.coerceIn(range.first, range.second)
        val nextLens = lensForLogicalZoom(requestedZoomRatio)
        val nextLensId = nextLens?.selectionId
        if (nextLensId != null && nextLensId != selectedLensId) {
            selectedLensId = nextLensId
            failedHighSpeedConfigKeys.clear()
            highSpeedFallbackActive = false
            if (hasActiveOrStartingSegment()) {
                sealCurrentSegment(restartAfterFinalize = false) {
                    mainHandler.post {
                        bindUseCasesIfReady()
                        sendCameraState()
                    }
                }
            } else {
                bindUseCasesIfReady()
            }
            return
        }
        applyPhysicalZoomForSelectedLens()
        sendCameraState()
    }

    private fun applyPhysicalZoomForSelectedLens() {
        val activeCamera = camera ?: return
        val lens = selectedZoomLens()
        val baseZoom = lens?.baseZoom ?: 1f
        val zoomState = activeCamera.cameraInfo.zoomState.value
        val minPhysicalZoom = zoomState?.minZoomRatio ?: 1f
        val maxPhysicalZoom = zoomState?.maxZoomRatio
            ?: lens?.maxDigitalZoom
            ?: 1f
        val physicalZoom = (requestedZoomRatio / baseZoom)
            .coerceIn(minPhysicalZoom, maxPhysicalZoom)
        activeCamera.cameraControl.setZoomRatio(physicalZoom)
    }

    private fun buildCameraSelector(targetLens: ZoomLens?): CameraSelector {
        selectedLensId = targetLens?.selectionId
        val builder = CameraSelector.Builder().requireLensFacing(lensFacing)
        val targetLogicalCameraId = targetLens?.logicalCameraId
        if (targetLogicalCameraId != null) {
            builder.addCameraFilter { cameraInfos ->
                val matching = cameraInfos.filter { cameraInfo ->
                    Camera2CameraInfo.from(cameraInfo).cameraId == targetLogicalCameraId
                }
                matching.ifEmpty { cameraInfos }
            }
        }
        return builder.build()
    }

    private fun <T> applyPhysicalCameraId(
        builder: androidx.camera.core.ExtendableBuilder<T>,
        lens: ZoomLens?,
    ) {
        val physicalCameraId = lens?.physicalCameraId ?: return
        Camera2Interop.Extender(builder).setPhysicalCameraId(physicalCameraId)
    }

    /**
     * Requested fps [Range] for [VideoCapture]. Null keeps CameraX / device defaults (~30).
     */
    private fun videoFrameRateRange(): Range<Int>? {
        if (highSpeedFallbackActive) {
            return null
        }
        return when (videoFpsMode) {
            "standard" -> null
            "fps60" -> Range(60, 60)
            "fps120" -> Range(120, 120)
            "fps240" -> Range(240, 240)
            "maxSupported" -> Range(60, 240)
            else -> null
        }
    }

    private fun encoderBitrateBitsPerSecond(): Int {
        val fps = nominalTargetFpsForPreference()
        val base = 12_000_000
        return (base * fps / 30).coerceIn(8_000_000, 80_000_000)
    }

    private fun bindUseCasesIfReady() {
        if (androidHighSpeedCaptureEngine.isPreviewActive) {
            return
        }
        if (rtmpLive != null) {
            return
        }
        if (startupBufferTestActive) {
            return
        }
        val view = previewView ?: return
        if (!previewRequested) {
            return
        }
        if (bufferingEnabled && isHighFpsRollingBuffer()) {
            startHighSpeedBufferingIfReady(view)
            return
        }

        releaseHighSpeedResources()
        val provider = cameraProvider ?: return

        try {
            camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
            provider.unbindAll()

            val targetLens = lensForLogicalZoom(requestedZoomRatio)
            val previewBuilder = Preview.Builder()
                .setTargetAspectRatio(AspectRatio.RATIO_16_9)
            applyPhysicalCameraId(previewBuilder, targetLens)
            previewUseCase = previewBuilder
                .build()
                .also { preview ->
                    preview.setSurfaceProvider { request ->
                        val texture = view.surfaceTexture
                        if (texture == null) {
                            return@setSurfaceProvider
                        }
                        val size = request.resolution
                        texture.setDefaultBufferSize(size.width, size.height)
                        val surface = android.view.Surface(texture)
                        request.provideSurface(surface, mainExecutor) {
                            surface.release()
                        }
                    }
                }

            val bindAnalysis = !(bufferingEnabled && isHighFpsRollingBuffer())
            analysisUseCase = if (bindAnalysis) {
                val analysisBuilder = ImageAnalysis.Builder()
                    .setTargetAspectRatio(AspectRatio.RATIO_16_9)
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                applyPhysicalCameraId(analysisBuilder, targetLens)
                analysisBuilder
                    .build()
                    .also { analysis ->
                        analysis.setAnalyzer(analysisExecutor) { proxy ->
                            analyzeFrame(proxy)
                        }
                    }
            } else {
                null
            }

            val qualitySelector = if (videoFpsMode == "maxSupported") {
                QualitySelector.from(
                    Quality.FHD,
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.HD),
                )
            } else {
                QualitySelector.from(
                    Quality.HD,
                    FallbackStrategy.lowerQualityOrHigherThan(Quality.HD),
                )
            }
            val recorderBuilder = Recorder.Builder()
                .setQualitySelector(qualitySelector)
            if (isHighFpsRollingBuffer()) {
                recorderBuilder.setTargetVideoEncodingBitRate(encoderBitrateBitsPerSecond())
            }
            recorder = recorderBuilder.build()

            val videoBuilder = VideoCapture.Builder(recorder!!)
            videoFrameRateRange()?.let { range ->
                videoBuilder.setTargetFrameRate(range)
            }
            applyPhysicalCameraId(videoBuilder, targetLens)
            videoCapture = videoBuilder.build()

            val selector = buildCameraSelector(targetLens)

            val analysis = analysisUseCase
            camera = if (analysis != null) {
                provider.bindToLifecycle(
                    activity,
                    selector,
                    previewUseCase,
                    analysis,
                    videoCapture,
                )
            } else {
                provider.bindToLifecycle(
                    activity,
                    selector,
                    previewUseCase,
                    videoCapture,
                )
            }

            val boundLogicalCameraId = camera?.cameraInfo?.let { cameraInfo ->
                Camera2CameraInfo.from(cameraInfo).cameraId
            }
            selectedLensId = if (
                targetLens != null &&
                    targetLens.logicalCameraId == boundLogicalCameraId
            ) {
                targetLens.selectionId
            } else {
                boundLogicalCameraId
            }
            applyPhysicalZoomForSelectedLens()
            camera?.cameraInfo?.zoomState?.observe(activity, zoomObserver)
            sendCameraState()
            if (bufferingEnabled && !hasActiveOrStartingSegment()) {
                startNewSegment()
            }
        } catch (error: Exception) {
            sendError(
                code = "camera_bind_failed",
                message = error.message ?: "Unable to bind camera use cases.",
            )
        }
    }

    private fun isDedicatedHighSpeedMethod(method: String): Boolean {
        return isCamera2OwnedCaptureMethod(method)
    }

    /**
     * Finer slices improve pre-roll resolution; coarser slices reduce muxer churn.
     * Stopping a recording can still make the preview surface idle on some devices,
     * so all rolling-buffer slices need to be long enough to avoid periodic stutter.
     */
    private fun computeSegmentSliceMs(preRollMs: Long, postRollMs: Long): Long {
        val ringWindow = (preRollMs + postRollMs + 1500L).coerceAtLeast(3000L)
        val minSlice = if (isHighFpsRollingBuffer()) 120_000L else 90_000L
        val maxSlice = if (isHighFpsRollingBuffer()) 180_000L else 120_000L
        return (ringWindow + minSlice).coerceIn(minSlice, maxSlice)
    }

    private fun stopBuffering(discardSegments: Boolean) {
        bufferingEnabled = false
        mainHandler.removeCallbacks(segmentRotationRunnable)
        if (hasActiveOrStartingSegment()) {
            sealCurrentSegment(
                restartAfterFinalize = false,
                callback = {
                    if (discardSegments) {
                        clearCompletedSegments()
                    }
                    sendBufferState()
                    restoreAnalysisUseCaseIfNeeded()
                },
            )
            return
        }
        if (discardSegments) {
            clearCompletedSegments()
        }
        sendBufferState()
        restoreAnalysisUseCaseIfNeeded()
    }

    private fun restoreAnalysisUseCaseIfNeeded() {
        if (
            previewRequested &&
                detectionEnabled &&
                rtmpLive == null &&
                !hasActiveOrStartingSegment() &&
                analysisUseCase == null
        ) {
            bindUseCasesIfReady()
        }
    }

    private fun startNewSegment() {
        if (!bufferingEnabled || hasActiveOrStartingSegment()) {
            return
        }
        if (isHighFpsRollingBuffer()) {
            startNewHighSpeedSegment()
            return
        }
        val capture = videoCapture ?: return
        if (camera == null) {
            return
        }

        val outputFile = File(
            clipsDirectory,
            "segment_${System.currentTimeMillis()}.mp4",
        )
        val options = FileOutputOptions.Builder(outputFile).build()
        var pending: PendingRecording = capture.output.prepareRecording(activity, options)
        if (hasAudioPermission()) {
            pending = pending.withAudioEnabled()
        }

        currentSegmentPath = outputFile.absolutePath
        currentSegmentStartEpochMs = System.currentTimeMillis()
        currentRecording = pending.start(mainExecutor) { event ->
            when (event) {
                is VideoRecordEvent.Start -> {
                    mainHandler.removeCallbacks(segmentRotationRunnable)
                    mainHandler.postDelayed(segmentRotationRunnable, segmentDurationMs)
                }
                is VideoRecordEvent.Finalize -> {
                    onSegmentFinalized(event)
                }
                else -> Unit
            }
        }
    }

    private fun sealCurrentSegment(
        restartAfterFinalize: Boolean,
        callback: ((BufferedSegment?) -> Unit)?,
    ) {
        if (highSpeedSegmentStarting && !currentHighSpeedSegmentActive) {
            currentSegmentRestartAfterFinalize = restartAfterFinalize
            currentSegmentFinalizeCallback = callback
            highSpeedStopRequestedWhileStarting = true
            mainHandler.removeCallbacks(segmentRotationRunnable)
            return
        }
        if (currentHighSpeedSegmentActive || highSpeedRecorder != null) {
            stopHighSpeedSegment(
                restartAfterFinalize = restartAfterFinalize,
                callback = callback,
            )
            return
        }

        val recording = currentRecording
        if (recording == null) {
            callback?.invoke(null)
            if (restartAfterFinalize && bufferingEnabled) {
                startNewSegment()
            }
            return
        }

        currentSegmentRestartAfterFinalize = restartAfterFinalize
        currentSegmentFinalizeCallback = callback
        currentRecording = null
        mainHandler.removeCallbacks(segmentRotationRunnable)
        recording.stop()
    }

    private fun onSegmentFinalized(event: VideoRecordEvent.Finalize) {
        val path = currentSegmentPath
        val startedAt = currentSegmentStartEpochMs
        currentSegmentPath = null
        currentSegmentStartEpochMs = 0L

        val callback = currentSegmentFinalizeCallback
        currentSegmentFinalizeCallback = null
        val restartAfterFinalize = currentSegmentRestartAfterFinalize
        currentSegmentRestartAfterFinalize = false

        val segment = if (
            path != null &&
                event.error == VideoRecordEvent.Finalize.ERROR_NONE &&
                File(path).exists()
        ) {
            BufferedSegment(
                path = path,
                startEpochMs = startedAt,
                endEpochMs = System.currentTimeMillis(),
            ).also { completed ->
                lastAchievedFps = probeVideoTrackNominalFrameRate(path)
                completedSegments.addLast(completed)
                pruneSegments(nowEpochMs = completed.endEpochMs)
            }
        } else {
            path?.let { File(it).delete() }
            null
        }

        callback?.invoke(segment)
        if (restartAfterFinalize && bufferingEnabled) {
            startNewSegment()
        }
        sendBufferState()
    }

    private fun startHighSpeedBufferingIfReady(view: TextureView) {
        camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
        cameraProvider?.unbindAll()
        camera = null
        previewUseCase = null
        analysisUseCase = null
        videoCapture = null
        recorder = null

        if (!hasActiveOrStartingSegment()) {
            if (view.surfaceTexture == null) {
                return
            }
            startNewSegment()
        }
        sendCameraState()
        sendBufferState()
    }

    @SuppressLint("MissingPermission")
    private fun startNewHighSpeedSegment() {
        val view = previewView ?: return
        val texture = view.surfaceTexture ?: return
        if (
            ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            sendError("camera_permission_missing", "Camera permission is required.")
            return
        }

        val config = selectHighSpeedRecordingConfig()
        if (config == null) {
            failRequiredHighSpeedBuffer(
                code = "high_speed_required_unavailable",
                message = "High-speed rolling buffer is unavailable on this lens.",
            )
            return
        }
        Log.i(
            ROLLING_BUFFER_LOG,
            "Starting high-speed segment camera=${config.cameraId} " +
                "fps=${config.fpsRange} size=${config.size} " +
                "mode=${if (config.constrainedHighSpeed) "hfr" else "native"}",
        )

        val outputFile = File(
            clipsDirectory,
            "segment_${System.currentTimeMillis()}.mp4",
        )
        activeHighSpeedTargetFps = config.targetFps
        activeHighSpeedSize = config.size
        activeHighSpeedCameraId = config.cameraId
        activeHighSpeedConfigKey = config.failureKey
        highSpeedSegmentStarting = true
        currentHighSpeedSegmentActive = false
        highSpeedStopRequestedWhileStarting = false
        highSpeedCaptureFailureReported = false
        sendBufferState()

        try {
            cameraProvider?.unbindAll()
            val mediaRecorder = prepareHighSpeedMediaRecorder(config, outputFile)
            texture.setDefaultBufferSize(config.size.width, config.size.height)
            val previewSurface = Surface(texture)

            highSpeedRecorder = mediaRecorder
            highSpeedPreviewSurface = previewSurface
            currentSegmentPath = outputFile.absolutePath
            currentSegmentStartEpochMs = 0L

            val cameraManager =
                activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            cameraManager.openCamera(
                config.cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        highSpeedCameraDevice = device
                        configureHighSpeedSession(
                            device = device,
                            config = config,
                            previewSurface = previewSurface,
                            recorderSurface = mediaRecorder.surface,
                        )
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        device.close()
                        failHighSpeedSegment(
                            code = "high_speed_camera_disconnected",
                            message = "High-speed camera disconnected.",
                        )
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        device.close()
                        failHighSpeedSegment(
                            code = "high_speed_camera_error",
                            message = "High-speed camera open failed: $error",
                        )
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            outputFile.delete()
            failHighSpeedSegment(
                code = "high_speed_start_failed",
                message = error.message ?: "Unable to start high-speed recording.",
            )
        }
    }

    private fun configureHighSpeedSession(
        device: CameraDevice,
        config: HighSpeedRecordingConfig,
        previewSurface: Surface,
        recorderSurface: Surface,
    ) {
        if (!config.constrainedHighSpeed) {
            configureNativeVideoSession(
                device = device,
                config = config,
                previewSurface = previewSurface,
                recorderSurface = recorderSurface,
            )
            return
        }
        try {
            device.createConstrainedHighSpeedCaptureSession(
                listOf(previewSurface, recorderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        val highSpeed = session as? CameraConstrainedHighSpeedCaptureSession
                        if (highSpeed == null) {
                            failHighSpeedSegment(
                                code = "high_speed_session_failed",
                                message = "Camera did not create a constrained high-speed session.",
                            )
                            return
                        }
                        highSpeedSession = highSpeed
                        try {
                            val requestBuilder =
                                device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                            requestBuilder.addTarget(previewSurface)
                            requestBuilder.addTarget(recorderSurface)
                            requestBuilder.set(
                                CaptureRequest.CONTROL_MODE,
                                CaptureRequest.CONTROL_MODE_AUTO,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_CAPTURE_INTENT,
                                CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_MODE,
                                CaptureRequest.CONTROL_AE_MODE_ON,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                                config.fpsRange,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AF_MODE,
                                CaptureRequest.CONTROL_AF_MODE_OFF,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                            )
                            requestBuilder.set(
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
                            )
                            val requests = highSpeed.createHighSpeedRequestList(
                                requestBuilder.build(),
                            )
                            highSpeed.setRepeatingBurst(
                                requests,
                                object : CameraCaptureSession.CaptureCallback() {
                                    override fun onCaptureFailed(
                                        session: CameraCaptureSession,
                                        request: CaptureRequest,
                                        failure: CaptureFailure,
                                    ) {
                                        reportHighSpeedCaptureFailure(
                                            message =
                                                "High-speed camera capture failed: " +
                                                    "reason=${failure.reason}, " +
                                                    "frame=${failure.frameNumber}, " +
                                                    "captured=${failure.wasImageCaptured()}.",
                                        )
                                    }

                                    override fun onCaptureSequenceAborted(
                                        session: CameraCaptureSession,
                                        sequenceId: Int,
                                    ) {
                                        reportHighSpeedCaptureFailure(
                                            message = "High-speed camera capture was aborted.",
                                        )
                                    }
                                },
                                mainHandler,
                            )
                            highSpeedRecorder?.start()
                            currentSegmentStartEpochMs = System.currentTimeMillis()
                            highSpeedSegmentStarting = false
                            currentHighSpeedSegmentActive = true
                            scheduleHighSpeedPoseSamplingIfNeeded()

                            if (highSpeedStopRequestedWhileStarting) {
                                val restart = currentSegmentRestartAfterFinalize
                                val callback = currentSegmentFinalizeCallback
                                currentSegmentRestartAfterFinalize = false
                                currentSegmentFinalizeCallback = null
                                highSpeedStopRequestedWhileStarting = false
                                stopHighSpeedSegment(
                                    restartAfterFinalize = restart,
                                    callback = callback,
                                )
                                return
                            }

                            mainHandler.removeCallbacks(segmentRotationRunnable)
                            mainHandler.postDelayed(
                                segmentRotationRunnable,
                                segmentDurationMs,
                            )
                            sendBufferState()
                        } catch (error: Exception) {
                            failHighSpeedSegment(
                                code = "high_speed_session_failed",
                                message = error.message ?: "Unable to configure high-speed session.",
                            )
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        failHighSpeedSegment(
                            code = "high_speed_session_failed",
                            message = "Unable to configure high-speed camera session.",
                        )
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failHighSpeedSegment(
                code = "high_speed_session_failed",
                message = error.message ?: "Unable to create high-speed camera session.",
            )
        }
    }

    private fun configureNativeVideoSession(
        device: CameraDevice,
        config: HighSpeedRecordingConfig,
        previewSurface: Surface,
        recorderSurface: Surface,
    ) {
        try {
            device.createCaptureSession(
                listOf(previewSurface, recorderSurface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        nativeVideoSession = session
                        try {
                            val requestBuilder =
                                device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                            requestBuilder.addTarget(previewSurface)
                            requestBuilder.addTarget(recorderSurface)
                            requestBuilder.set(
                                CaptureRequest.CONTROL_MODE,
                                CaptureRequest.CONTROL_MODE_AUTO,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_CAPTURE_INTENT,
                                CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_MODE,
                                CaptureRequest.CONTROL_AE_MODE_ON,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                                config.fpsRange,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AF_MODE,
                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                            )
                            requestBuilder.set(
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
                            )
                            session.setRepeatingRequest(
                                requestBuilder.build(),
                                object : CameraCaptureSession.CaptureCallback() {
                                    override fun onCaptureFailed(
                                        session: CameraCaptureSession,
                                        request: CaptureRequest,
                                        failure: CaptureFailure,
                                    ) {
                                        reportHighSpeedCaptureFailure(
                                            message =
                                                "Native ${config.targetFps}fps camera capture failed: " +
                                                    "reason=${failure.reason}, " +
                                                    "frame=${failure.frameNumber}, " +
                                                    "captured=${failure.wasImageCaptured()}.",
                                        )
                                    }
                                },
                                mainHandler,
                            )
                            highSpeedRecorder?.start()
                            currentSegmentStartEpochMs = System.currentTimeMillis()
                            highSpeedSegmentStarting = false
                            currentHighSpeedSegmentActive = true
                            scheduleHighSpeedPoseSamplingIfNeeded()

                            if (highSpeedStopRequestedWhileStarting) {
                                val restart = currentSegmentRestartAfterFinalize
                                val callback = currentSegmentFinalizeCallback
                                currentSegmentRestartAfterFinalize = false
                                currentSegmentFinalizeCallback = null
                                highSpeedStopRequestedWhileStarting = false
                                stopHighSpeedSegment(
                                    restartAfterFinalize = restart,
                                    callback = callback,
                                )
                                return
                            }

                            mainHandler.removeCallbacks(segmentRotationRunnable)
                            mainHandler.postDelayed(
                                segmentRotationRunnable,
                                segmentDurationMs,
                            )
                            sendBufferState()
                        } catch (error: Exception) {
                            failHighSpeedSegment(
                                code = "native_video_session_failed",
                                message = error.message ?: "Unable to configure native video session.",
                            )
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        failHighSpeedSegment(
                            code = "native_video_session_failed",
                            message = "Unable to configure native video camera session.",
                        )
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            failHighSpeedSegment(
                code = "native_video_session_failed",
                message = error.message ?: "Unable to create native video camera session.",
            )
        }
    }

    private fun stopHighSpeedSegment(
        restartAfterFinalize: Boolean,
        callback: ((BufferedSegment?) -> Unit)?,
    ) {
        if (highSpeedSegmentStarting && !currentHighSpeedSegmentActive) {
            currentSegmentRestartAfterFinalize = restartAfterFinalize
            currentSegmentFinalizeCallback = callback
            highSpeedStopRequestedWhileStarting = true
            mainHandler.removeCallbacks(segmentRotationRunnable)
            return
        }

        mainHandler.removeCallbacks(segmentRotationRunnable)
        val path = currentSegmentPath
        val startedAt = currentSegmentStartEpochMs
        val configKey = activeHighSpeedConfigKey
        val targetFps = activeHighSpeedTargetFps
        val shouldContinueBuffering = bufferingEnabled && !highSpeedFallbackActive
        currentSegmentPath = null
        currentSegmentStartEpochMs = 0L
        highSpeedSegmentStarting = false
        currentHighSpeedSegmentActive = false
        highSpeedStopRequestedWhileStarting = false
        highSpeedCaptureFailureReported = false

        var stoppedCleanly = false
        try {
            highSpeedSession?.stopRepeating()
        } catch (_: Exception) {
            // The recorder stop below is the source of truth for whether the file is valid.
        }
        try {
            nativeVideoSession?.stopRepeating()
        } catch (_: Exception) {
            // The recorder stop below is the source of truth for whether the file is valid.
        }
        try {
            highSpeedRecorder?.stop()
            stoppedCleanly = true
        } catch (_: RuntimeException) {
            stoppedCleanly = false
        } finally {
            releaseHighSpeedResources()
        }

        val outputFile = path?.let { File(it) }
        val segment = if (
            stoppedCleanly &&
                outputFile != null &&
                outputFile.exists() &&
                outputFile.length() > 4096L &&
                startedAt > 0L
        ) {
            BufferedSegment(
                path = outputFile.absolutePath,
                startEpochMs = startedAt,
                endEpochMs = System.currentTimeMillis(),
                targetFps = targetFps,
            ).takeIf {
                val achievedFps = probeVideoTrackNominalFrameRate(outputFile.absolutePath)
                lastAchievedFps = achievedFps
                val valid = isRecordedSegmentFpsValid(
                    targetFps = targetFps,
                    achievedFps = achievedFps,
                )
                if (!valid) {
                    Log.w(
                        ROLLING_BUFFER_LOG,
                        "Discarding segment below target fps target=$targetFps " +
                            "achieved=$achievedFps key=$configKey",
                    )
                }
                valid
            }?.also { completed ->
                completedSegments.addLast(completed)
                pruneSegments(nowEpochMs = completed.endEpochMs)
            }
        } else {
            configKey?.let { failedHighSpeedConfigKeys.add(it) }
            outputFile?.delete()
            null
        }
        if (
            stoppedCleanly &&
                segment == null &&
                outputFile != null &&
                outputFile.exists()
        ) {
            configKey?.let { failedHighSpeedConfigKeys.add(it) }
            outputFile.delete()
        }

        callback?.invoke(segment)
        if (restartAfterFinalize && bufferingEnabled) {
            startNewSegment()
        } else if (segment == null && shouldContinueBuffering) {
            startNewSegment()
        }
        sendBufferState()
    }

    private fun reportHighSpeedCaptureFailure(message: String) {
        if (highSpeedCaptureFailureReported) {
            return
        }
        if (!currentHighSpeedSegmentActive && !highSpeedSegmentStarting) {
            return
        }
        highSpeedCaptureFailureReported = true
        mainHandler.post {
            failHighSpeedSegment(
                code = "high_speed_capture_failed",
                message = message,
            )
        }
    }

    private fun failHighSpeedSegment(code: String, message: String) {
        Log.w(
            ROLLING_BUFFER_LOG,
            "High-speed segment failed code=$code message=$message",
        )
        val path = currentSegmentPath
        val shouldContinueBuffering = bufferingEnabled && !highSpeedFallbackActive
        activeHighSpeedConfigKey?.let { failedHighSpeedConfigKeys.add(it) }
        val shouldRetryNextHighSpeedProfile =
            shouldContinueBuffering && currentSegmentFinalizeCallback == null
        currentSegmentPath = null
        currentSegmentStartEpochMs = 0L
        highSpeedSegmentStarting = false
        currentHighSpeedSegmentActive = false
        highSpeedStopRequestedWhileStarting = false
        highSpeedCaptureFailureReported = false
        releaseHighSpeedResources()
        path?.let { File(it).delete() }

        val callback = currentSegmentFinalizeCallback
        val restartAfterFinalize = currentSegmentRestartAfterFinalize
        currentSegmentFinalizeCallback = null
        currentSegmentRestartAfterFinalize = false
        callback?.invoke(null)
        if (restartAfterFinalize && bufferingEnabled) {
            startNewSegment()
        } else if (shouldRetryNextHighSpeedProfile) {
            startNewSegment()
        }
        if (!shouldRetryNextHighSpeedProfile) {
            sendError(code, message)
        }
        sendBufferState()
    }

    private fun failRequiredHighSpeedBuffer(code: String, message: String) {
        Log.w(
            ROLLING_BUFFER_LOG,
            "Required high-speed buffer unavailable code=$code mode=$videoFpsMode message=$message",
        )
        failedHighSpeedConfigKeys.clear()
        mainHandler.removeCallbacks(segmentRotationRunnable)
        releaseHighSpeedResources()
        clearCompletedSegments()
        if (videoFpsMode == "standard") {
            bufferingEnabled = true
            highSpeedFallbackActive = true
            bindUseCasesIfReady()
            sendBufferState()
            return
        }
        bufferingEnabled = false
        highSpeedFallbackActive = false
        sendError(code, message)
        sendBufferState()
        bindUseCasesIfReady()
    }

    private fun releaseHighSpeedResources() {
        highSpeedSegmentStarting = false
        currentHighSpeedSegmentActive = false
        highSpeedStopRequestedWhileStarting = false
        highSpeedCaptureFailureReported = false
        mainHandler.removeCallbacks(highSpeedPoseSamplingRunnable)

        try {
            highSpeedSession?.close()
        } catch (_: Exception) {
        }
        highSpeedSession = null

        try {
            nativeVideoSession?.close()
        } catch (_: Exception) {
        }
        nativeVideoSession = null

        try {
            highSpeedCameraDevice?.close()
        } catch (_: Exception) {
        }
        highSpeedCameraDevice = null

        try {
            highSpeedRecorder?.reset()
        } catch (_: Exception) {
        }
        try {
            highSpeedRecorder?.release()
        } catch (_: Exception) {
        }
        highSpeedRecorder = null

        try {
            highSpeedPreviewSurface?.release()
        } catch (_: Exception) {
        }
        highSpeedPreviewSurface = null

        activeHighSpeedTargetFps = null
        activeHighSpeedSize = null
        activeHighSpeedCameraId = null
        activeHighSpeedConfigKey = null
    }

    @Suppress("DEPRECATION")
    private fun prepareHighSpeedMediaRecorder(
        config: HighSpeedRecordingConfig,
        outputFile: File,
    ): MediaRecorder {
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }
        val mediaRecorder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(activity)
        } else {
            MediaRecorder()
        }
        mediaRecorder.setVideoSource(MediaRecorder.VideoSource.SURFACE)
        mediaRecorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
        mediaRecorder.setOutputFile(outputFile.absolutePath)
        mediaRecorder.setVideoEncodingBitRate(encoderBitrateBitsPerSecond())
        mediaRecorder.setVideoFrameRate(config.targetFps)
        mediaRecorder.setVideoSize(config.size.width, config.size.height)
        mediaRecorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264)
        mediaRecorder.setOrientationHint(config.orientationHintDegrees)
        mediaRecorder.prepare()
        return mediaRecorder
    }

    private fun selectHighSpeedRecordingConfig(
        ignoreFailedConfigs: Boolean = false,
        requireFixedFps: Boolean = false,
    ): HighSpeedRecordingConfig? {
        val cameraManager =
            activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        val targetLens = selectedZoomLens()
        val cameraIds = highSpeedCameraCandidateIds(cameraManager, targetLens)
        val profiles = highSpeedProfilePriority()
        for ((desiredSize, desiredFps) in profiles) {
            Log.i(
                ROLLING_BUFFER_LOG,
                "Checking profile ${desiredSize.width}x${desiredSize.height}@$desiredFps",
            )
            for (cameraId in cameraIds) {
                val characteristics = try {
                    cameraManager.getCameraCharacteristics(cameraId)
                } catch (_: Exception) {
                    continue
                }
                val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
                    ?: continue
                val availableSize = map.highSpeedVideoSizes
                    ?.firstOrNull {
                        it.width == desiredSize.width && it.height == desiredSize.height
                    }
                if (availableSize != null && desiredFps >= 60) {
                    val ranges = try {
                        map.getHighSpeedVideoFpsRangesFor(availableSize).toList()
                    } catch (_: Exception) {
                        map.highSpeedVideoFpsRanges?.toList().orEmpty()
                    }
                    val range = selectHighSpeedFpsRange(
                        ranges = ranges,
                        requestedFps = desiredFps,
                        requireFixedFps = requireFixedFps || desiredFps >= 120,
                    )
                    if (range != null) {
                        val config = HighSpeedRecordingConfig(
                            cameraId = cameraId,
                            fpsRange = range,
                            targetFps = range.upper,
                            size = availableSize,
                            orientationHintDegrees = videoOrientationHintForCamera(characteristics),
                            constrainedHighSpeed = true,
                        )
                        if (!ignoreFailedConfigs && failedHighSpeedConfigKeys.contains(config.failureKey)) {
                            continue
                        }
                        return config
                    }
                }

                if (desiredFps == 60 || desiredFps == 30) {
                    val standardConfig = selectNativeVideoRecordingConfig(
                        cameraId = cameraId,
                        characteristics = characteristics,
                        desiredSize = desiredSize,
                        desiredFps = desiredFps,
                    )
                    if (standardConfig != null) {
                        if (
                            !ignoreFailedConfigs &&
                            failedHighSpeedConfigKeys.contains(standardConfig.failureKey)
                        ) {
                            continue
                        }
                        return standardConfig
                    }
                }
            }
        }
        return null
    }

    private fun selectNativeVideoRecordingConfig(
        cameraId: String,
        characteristics: CameraCharacteristics,
        desiredSize: Size,
        desiredFps: Int,
    ): HighSpeedRecordingConfig? {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?: return null
        val supportsRecorderSize = map.getOutputSizes(MediaRecorder::class.java)
            ?.any { it.width == desiredSize.width && it.height == desiredSize.height }
            ?: false
        if (!supportsRecorderSize) {
            return null
        }
        val range = selectHighSpeedFpsRange(
            ranges = characteristics
                .get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
                ?.toList()
                .orEmpty(),
            requestedFps = desiredFps,
            requireFixedFps = false,
        ) ?: return null
        return HighSpeedRecordingConfig(
            cameraId = cameraId,
            fpsRange = range,
            targetFps = desiredFps,
            size = desiredSize,
            orientationHintDegrees = videoOrientationHintForCamera(characteristics),
            constrainedHighSpeed = false,
        )
    }

    private fun highSpeedProfilePriority(): List<Pair<Size, Int>> {
        return listOf(
            Size(1920, 1080) to 120,
            Size(1280, 720) to 120,
            Size(1920, 1080) to 60,
            Size(1280, 720) to 60,
            Size(1920, 1080) to 30,
        )
    }

    private fun highSpeedCameraCandidateIds(
        cameraManager: CameraManager,
        targetLens: ZoomLens?,
    ): List<String> {
        val availableIds = cameraManager.cameraIdList.toSet()
        val candidates = mutableListOf<String>()
        targetLens?.physicalCameraId
            ?.takeIf { availableIds.contains(it) }
            ?.let { candidates.add(it) }
        targetLens?.logicalCameraId
            ?.takeIf { availableIds.contains(it) }
            ?.let { candidates.add(it) }

        for (cameraId in cameraManager.cameraIdList) {
            val characteristics = try {
                cameraManager.getCameraCharacteristics(cameraId)
            } catch (_: Exception) {
                continue
            }
            if (characteristics.get(CameraCharacteristics.LENS_FACING) == lensFacing) {
                candidates.add(cameraId)
            }
        }
        return candidates.distinct()
    }

    private fun selectHighSpeedFpsRange(
        ranges: List<Range<Int>>,
        requestedFps: Int,
        requireFixedFps: Boolean = false,
    ): Range<Int>? {
        if (ranges.isEmpty()) {
            return null
        }
        if (requireFixedFps) {
            return ranges
                .filter { it.lower == it.upper && it.upper == requestedFps }
                .sortedWith(
                    compareBy<Range<Int>> { abs(it.upper - requestedFps) }
                        .thenByDescending { it.upper },
                )
                .firstOrNull()
        }

        return ranges
            .filter { it.upper == requestedFps }
            .sortedWith(
                compareBy<Range<Int>> { abs(it.upper - requestedFps) }
                    .thenBy { if (it.lower == it.upper) 0 else 1 }
                    .thenByDescending { it.lower },
            )
            .firstOrNull()
    }

    private fun selectHighSpeedVideoSize(sizes: List<Size>): Size? {
        if (sizes.isEmpty()) {
            return null
        }
        val maxArea = if (videoFpsMode == "maxSupported") {
            1920 * 1080
        } else {
            1280 * 720
        }
        val sameAspect = sizes.filter { abs(it.width * 9 - it.height * 16) <= it.width }
        val candidates = sameAspect.ifEmpty { sizes }
        return candidates
            .filter { it.width * it.height <= maxArea }
            .maxByOrNull { it.width * it.height }
            ?: candidates.minByOrNull { it.width * it.height }
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

    private fun scheduleHighSpeedPoseSamplingIfNeeded() {
        mainHandler.removeCallbacks(highSpeedPoseSamplingRunnable)
        val view = previewView
        if (
            detectionEnabled &&
                (currentHighSpeedSegmentActive ||
                    androidHighSpeedCaptureEngine.isPreviewActive) &&
                view != null &&
                canSamplePreviewBitmap(
                    viewAvailable = view.isAvailable,
                    currentTexture = view.surfaceTexture,
                    lastRenderedTexture = lastRenderedPreviewTexture,
                )
        ) {
            mainHandler.postDelayed(highSpeedPoseSamplingRunnable, poseFrameIntervalMs)
        }
    }

    private fun canStartPoseAnalysis(nowMs: Long = System.currentTimeMillis()): Boolean {
        if (!detectionEnabled || isProcessingPose) {
            return false
        }
        return nowMs - lastPoseAnalysisStartedMs >= poseFrameIntervalMs
    }

    private fun markPoseAnalysisStarted(nowMs: Long = System.currentTimeMillis()) {
        lastPoseAnalysisStartedMs = nowMs
        isProcessingPose = true
    }

    private fun sampleHighSpeedPreviewPoseFrame() {
        val view = previewView ?: return
        if (
            (!currentHighSpeedSegmentActive &&
                !androidHighSpeedCaptureEngine.isPreviewActive) ||
            !canSamplePreviewBitmap(
                viewAvailable = view.isAvailable,
                currentTexture = view.surfaceTexture,
                lastRenderedTexture = lastRenderedPreviewTexture,
            )
        ) {
            return
        }
        val nowMs = System.currentTimeMillis()
        if (!canStartPoseAnalysis(nowMs)) {
            return
        }
        val viewWidth = view.width
        val viewHeight = view.height
        if (viewWidth <= 0 || viewHeight <= 0) {
            return
        }

        val maxBitmapWidth = if (
            isHighFpsRollingBuffer() ||
                androidHighSpeedCaptureEngine.isRunningOrStarting
        ) {
            maxHighSpeedPreviewPoseBitmapWidth
        } else {
            maxPreviewPoseBitmapWidth
        }
        val sampleWidth = minOf(viewWidth, maxBitmapWidth)
        val sampleHeight = maxOf(1, viewHeight * sampleWidth / viewWidth)
        val bitmap = try {
            view.getBitmap(sampleWidth, sampleHeight)
        } catch (_: Exception) {
            null
        } ?: return

        if (debugSelfTestActive) {
            debugSelfTestPoseAttempts += 1
        }
        markPoseAnalysisStarted(nowMs)
        val rotationDegrees = displayRotationDegrees()
        val inputImage = InputImage.fromBitmap(bitmap, rotationDegrees)
        poseDetector.process(inputImage)
            .addOnSuccessListener(mainExecutor) { pose ->
                if (debugSelfTestActive) {
                    debugSelfTestPoseResults += 1
                }
                sendPoseEvent(
                    pose = pose,
                    imageWidth = bitmap.width,
                    imageHeight = bitmap.height,
                    rotationDegrees = rotationDegrees,
                )
            }
            .addOnFailureListener(mainExecutor) { error ->
                sendError(
                    code = "pose_detection_failed",
                    message = error.message ?: "Pose detection failed.",
                )
            }
            .addOnCompleteListener(mainExecutor) {
                isProcessingPose = false
                bitmap.recycle()
            }
    }

    @OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(imageProxy: ImageProxy) {
        val nowMs = System.currentTimeMillis()
        if (!canStartPoseAnalysis(nowMs)) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        markPoseAnalysisStarted(nowMs)
        val rotationDegrees = imageProxy.imageInfo.rotationDegrees
        val inputImage = InputImage.fromMediaImage(mediaImage, rotationDegrees)
        poseDetector.process(inputImage)
            .addOnSuccessListener(mainExecutor) { pose ->
                sendPoseEvent(
                    pose = pose,
                    imageWidth = imageProxy.width,
                    imageHeight = imageProxy.height,
                    rotationDegrees = rotationDegrees,
                )
            }
            .addOnFailureListener(mainExecutor) { error ->
                sendError(
                    code = "pose_detection_failed",
                    message = error.message ?: "Pose detection failed.",
                )
            }
            .addOnCompleteListener(mainExecutor) {
                isProcessingPose = false
                imageProxy.close()
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

    private fun onRtmpPoseImage(image: Image) {
        val nowMs = System.currentTimeMillis()
        if (!canStartPoseAnalysis(nowMs)) {
            image.close()
            return
        }
        markPoseAnalysisStarted(nowMs)
        val rotationDegrees = displayRotationDegrees()
        val inputImage = InputImage.fromMediaImage(image, rotationDegrees)
        val w = image.width
        val h = image.height
        poseDetector.process(inputImage)
            .addOnSuccessListener(mainExecutor) { pose ->
                sendPoseEvent(
                    pose = pose,
                    imageWidth = w,
                    imageHeight = h,
                    rotationDegrees = rotationDegrees,
                )
            }
            .addOnFailureListener(mainExecutor) { error ->
                sendError(
                    code = "pose_detection_failed",
                    message = error.message ?: "Pose detection failed.",
                )
            }
            .addOnCompleteListener(mainExecutor) {
                isProcessingPose = false
                image.close()
            }
    }

    private fun sendPoseEvent(
        pose: Pose?,
        imageWidth: Int,
        imageHeight: Int,
        rotationDegrees: Int,
    ) {
        val orientedWidth = if (rotationDegrees == 90 || rotationDegrees == 270) {
            imageHeight.toDouble()
        } else {
            imageWidth.toDouble()
        }
        val orientedHeight = if (rotationDegrees == 90 || rotationDegrees == 270) {
            imageWidth.toDouble()
        } else {
            imageHeight.toDouble()
        }

        val landmarks = if (pose == null) {
            emptyList()
        } else {
            buildList {
                addLandmark(this, pose, PoseLandmark.NOSE, "nose", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_SHOULDER, "leftShoulder", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_SHOULDER, "rightShoulder", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_ELBOW, "leftElbow", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_ELBOW, "rightElbow", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_WRIST, "leftWrist", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_WRIST, "rightWrist", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_HIP, "leftHip", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_HIP, "rightHip", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_KNEE, "leftKnee", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_KNEE, "rightKnee", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.LEFT_ANKLE, "leftAnkle", orientedWidth, orientedHeight)
                addLandmark(this, pose, PoseLandmark.RIGHT_ANKLE, "rightAnkle", orientedWidth, orientedHeight)
            }
        }

        eventSink?.success(
            mapOf(
                "type" to "pose",
                "timestampMs" to System.currentTimeMillis(),
                "landmarks" to landmarks,
            ),
        )
    }

    private fun addLandmark(
        out: MutableList<Map<String, Any>>,
        pose: Pose,
        type: Int,
        name: String,
        orientedWidth: Double,
        orientedHeight: Double,
    ) {
        val landmark = pose.getPoseLandmark(type) ?: return
        var normalizedX = (landmark.position.x / orientedWidth).coerceIn(0.0, 1.0)
        val normalizedY = (landmark.position.y / orientedHeight).coerceIn(0.0, 1.0)
        if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            normalizedX = 1.0 - normalizedX
        }
        out.add(
            mapOf(
                "name" to name,
                "x" to normalizedX,
                "y" to normalizedY,
                "confidence" to landmark.inFrameLikelihood.toDouble(),
            ),
        )
    }

    private fun runStartupBufferTest(
        durationMs: Int,
        result: MethodChannel.Result,
    ) {
        if (startupBufferTestActive) {
            result.error(
                "startup_buffer_busy",
                "Startup high-speed buffer test is already running.",
                null,
            )
            return
        }
        if (
            ContextCompat.checkSelfPermission(activity, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.error("camera_permission_missing", "Camera permission is required.", null)
            return
        }

        startupBufferTestActive = true
        Log.i(STARTUP_BUFFER_TEST_LOG, "Starting startup buffer test durationMs=$durationMs")
        startupTestExecutor.execute {
            try {
                val payload = runStartupBufferTestBlocking(durationMs)
                Log.i(STARTUP_BUFFER_TEST_LOG, "Startup buffer test succeeded: $payload")
                mainHandler.post { result.success(payload) }
            } catch (error: Exception) {
                Log.w(
                    STARTUP_BUFFER_TEST_LOG,
                    "Startup buffer test failed: ${error.message}",
                    error,
                )
                mainHandler.post {
                    result.error(
                        "startup_buffer_failed",
                        error.message ?: "Startup high-speed buffer test failed.",
                        null,
                    )
                }
            } finally {
                mainHandler.post {
                    startupBufferTestActive = false
                    if (previewRequested) {
                        bindUseCasesIfReady()
                    }
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun runStartupBufferTestBlocking(durationMs: Int): Map<String, Any?> {
        val config = selectHighSpeedRecordingConfig(
            ignoreFailedConfigs = true,
            requireFixedFps = false,
        ) ?: throw IllegalStateException(
            "No high-speed camera mode is available.",
        )
        Log.i(
            STARTUP_BUFFER_TEST_LOG,
            "Using camera=${config.cameraId} fps=${config.fpsRange} size=${config.size}",
        )

        val outputFile = File(
            clipsDirectory,
            "startup_buffer_${System.currentTimeMillis()}.mp4",
        )

        var codec: MediaCodec? = null
        var inputSurface: Surface? = null
        var previewSurface: Surface? = null
        var muxer: MediaMuxer? = null
        var codecStarted = false
        val drainState = StartupEncoderDrainState()
        val cameraRef = AtomicReference<CameraDevice?>(null)
        val sessionRef = AtomicReference<CameraConstrainedHighSpeedCaptureSession?>(null)
        val captureFailure = AtomicReference<String?>(null)

        try {
            runOnMainSync {
                stopBuffering(discardSegments = false)
                camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
                cameraProvider?.unbindAll()
                releaseHighSpeedResources()
                camera = null
                previewUseCase = null
                analysisUseCase = null
                videoCapture = null
                recorder = null
            }

            outputFile.parentFile?.mkdirs()
            if (outputFile.exists()) {
                outputFile.delete()
            }

            codec = MediaCodec.createEncoderByType("video/avc")
            val format = MediaFormat.createVideoFormat(
                "video/avc",
                config.size.width,
                config.size.height,
            )
            format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, encoderBitrateBitsPerSecond())
            format.setInteger(MediaFormat.KEY_FRAME_RATE, config.targetFps)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = codec.createInputSurface()
            codec.start()
            codecStarted = true

            muxer = MediaMuxer(
                outputFile.absolutePath,
                MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4,
            )
            muxer.setOrientationHint(config.orientationHintDegrees)
            previewSurface = createStartupPreviewSurface(config)

            startStartupCameraSession(
                config = config,
                encoderSurface = inputSurface,
                previewSurface = previewSurface,
                cameraRef = cameraRef,
                sessionRef = sessionRef,
                captureFailure = captureFailure,
            )

            val deadlineNs = System.nanoTime() + durationMs * 1_000_000L
            while (System.nanoTime() < deadlineNs) {
                captureFailure.get()?.let { throw IllegalStateException(it) }
                drainStartupEncoder(codec, muxer, drainState, timeoutUs = 10_000L)
            }

            stopStartupCameraSession(sessionRef, cameraRef)
            codec.signalEndOfInputStream()
            val eosDeadlineNs = System.nanoTime() + 2_000_000_000L
            var sawEos = false
            while (!sawEos && System.nanoTime() < eosDeadlineNs) {
                sawEos = drainStartupEncoder(
                    codec,
                    muxer,
                    drainState,
                    timeoutUs = 100_000L,
                )
            }
            if (!sawEos) {
                throw IllegalStateException("Timed out while finalizing startup buffer test.")
            }

            if (drainState.frameCount < 2) {
                throw IllegalStateException("Startup buffer test did not produce a valid video.")
            }

            if (drainState.muxerStarted) {
                muxer.stop()
                drainState.muxerStarted = false
            }
            muxer.release()
            muxer = null

            if (!outputFile.exists() || outputFile.length() <= 4096L) {
                throw IllegalStateException("Startup buffer test did not produce a valid video.")
            }

            val measuredFps = if (
                drainState.frameCount >= 2 &&
                    drainState.lastPtsUs > drainState.firstPtsUs
            ) {
                (drainState.frameCount - 1) * 1_000_000.0 /
                    (drainState.lastPtsUs - drainState.firstPtsUs)
            } else {
                null
            }
            val achievedFps =
                deriveVideoFrameRateFromSamples(outputFile.absolutePath) ?: measuredFps
            val measuredDurationMs = if (drainState.lastPtsUs > drainState.firstPtsUs) {
                ((drainState.lastPtsUs - drainState.firstPtsUs) / 1000L).toInt()
            } else {
                durationMs
            }

            return mapOf(
                "outputPath" to outputFile.absolutePath,
                "durationMs" to measuredDurationMs,
                "targetFps" to config.targetFps,
                "sizeBytes" to outputFile.length(),
                "frameCount" to drainState.frameCount,
                "achievedFps" to achievedFps,
            )
        } catch (error: Exception) {
            outputFile.delete()
            throw error
        } finally {
            stopStartupCameraSession(sessionRef, cameraRef)
            if (codecStarted) {
                try {
                    codec?.stop()
                } catch (_: Exception) {
                }
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
            try {
                inputSurface?.release()
            } catch (_: Exception) {
            }
            try {
                if (drainState.muxerStarted) {
                    muxer?.stop()
                }
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
            try {
                previewSurface?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun createStartupPreviewSurface(config: HighSpeedRecordingConfig): Surface? {
        var previewSurface: Surface? = null
        runOnMainSync {
            val texture = previewView?.surfaceTexture ?: return@runOnMainSync
            texture.setDefaultBufferSize(config.size.width, config.size.height)
            previewSurface = Surface(texture)
        }
        return previewSurface
    }

    @SuppressLint("MissingPermission")
    private fun startStartupCameraSession(
        config: HighSpeedRecordingConfig,
        encoderSurface: Surface,
        previewSurface: Surface?,
        cameraRef: AtomicReference<CameraDevice?>,
        sessionRef: AtomicReference<CameraConstrainedHighSpeedCaptureSession?>,
        captureFailure: AtomicReference<String?>,
    ) {
        val readyLatch = CountDownLatch(1)
        val readyError = AtomicReference<String?>(null)
        val cameraManager =
            activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager

        mainHandler.post {
            try {
                cameraManager.openCamera(
                    config.cameraId,
                    object : CameraDevice.StateCallback() {
                        override fun onOpened(device: CameraDevice) {
                            cameraRef.set(device)
                            createStartupHighSpeedSession(
                                device = device,
                                config = config,
                                encoderSurface = encoderSurface,
                                previewSurface = previewSurface,
                                sessionRef = sessionRef,
                                readyLatch = readyLatch,
                                readyError = readyError,
                                captureFailure = captureFailure,
                            )
                        }

                        override fun onDisconnected(device: CameraDevice) {
                            device.close()
                            readyError.compareAndSet(
                                null,
                                "Startup high-speed camera disconnected.",
                            )
                            readyLatch.countDown()
                        }

                        override fun onError(device: CameraDevice, error: Int) {
                            device.close()
                            readyError.compareAndSet(
                                null,
                                "Startup high-speed camera open failed: $error.",
                            )
                            readyLatch.countDown()
                        }
                    },
                    mainHandler,
                )
            } catch (error: Exception) {
                readyError.compareAndSet(
                    null,
                    error.message ?: "Unable to open startup high-speed camera.",
                )
                readyLatch.countDown()
            }
        }

        if (!readyLatch.await(6, TimeUnit.SECONDS)) {
            throw IllegalStateException("Timed out opening startup high-speed camera.")
        }
        readyError.get()?.let { throw IllegalStateException(it) }
    }

    private fun createStartupHighSpeedSession(
        device: CameraDevice,
        config: HighSpeedRecordingConfig,
        encoderSurface: Surface,
        previewSurface: Surface?,
        sessionRef: AtomicReference<CameraConstrainedHighSpeedCaptureSession?>,
        readyLatch: CountDownLatch,
        readyError: AtomicReference<String?>,
        captureFailure: AtomicReference<String?>,
    ) {
        try {
            val outputs = if (previewSurface == null) {
                listOf(encoderSurface)
            } else {
                listOf(previewSurface, encoderSurface)
            }
            device.createConstrainedHighSpeedCaptureSession(
                outputs,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        val highSpeed =
                            session as? CameraConstrainedHighSpeedCaptureSession
                        if (highSpeed == null) {
                            readyError.compareAndSet(
                                null,
                                "Camera did not create a startup high-speed session.",
                            )
                            readyLatch.countDown()
                            return
                        }
                        sessionRef.set(highSpeed)
                        try {
                            val requestBuilder =
                                device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD)
                            previewSurface?.let { requestBuilder.addTarget(it) }
                            requestBuilder.addTarget(encoderSurface)
                            requestBuilder.set(
                                CaptureRequest.CONTROL_MODE,
                                CaptureRequest.CONTROL_MODE_AUTO,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_CAPTURE_INTENT,
                                CaptureRequest.CONTROL_CAPTURE_INTENT_VIDEO_RECORD,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_MODE,
                                CaptureRequest.CONTROL_AE_MODE_ON,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE,
                                config.fpsRange,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_AF_MODE,
                                CaptureRequest.CONTROL_AF_MODE_OFF,
                            )
                            requestBuilder.set(
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE,
                                CaptureRequest.CONTROL_VIDEO_STABILIZATION_MODE_OFF,
                            )
                            requestBuilder.set(
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE,
                                CaptureRequest.LENS_OPTICAL_STABILIZATION_MODE_OFF,
                            )
                            val requests = highSpeed.createHighSpeedRequestList(
                                requestBuilder.build(),
                            )
                            highSpeed.setRepeatingBurst(
                                requests,
                                object : CameraCaptureSession.CaptureCallback() {
                                    override fun onCaptureFailed(
                                        session: CameraCaptureSession,
                                        request: CaptureRequest,
                                        failure: CaptureFailure,
                                    ) {
                                        captureFailure.compareAndSet(
                                            null,
                                            "Startup high-speed capture failed: " +
                                                "reason=${failure.reason}, " +
                                                "frame=${failure.frameNumber}, " +
                                                "captured=${failure.wasImageCaptured()}.",
                                        )
                                    }

                                    override fun onCaptureSequenceAborted(
                                        session: CameraCaptureSession,
                                        sequenceId: Int,
                                    ) {
                                        captureFailure.compareAndSet(
                                            null,
                                            "Startup high-speed capture was aborted.",
                                        )
                                    }
                                },
                                mainHandler,
                            )
                            readyLatch.countDown()
                        } catch (error: Exception) {
                            readyError.compareAndSet(
                                null,
                                error.message ?: "Unable to start startup high-speed request.",
                            )
                            readyLatch.countDown()
                        }
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        readyError.compareAndSet(
                            null,
                            "Unable to configure startup high-speed camera session.",
                        )
                        readyLatch.countDown()
                    }
                },
                mainHandler,
            )
        } catch (error: Exception) {
            readyError.compareAndSet(
                null,
                error.message ?: "Unable to create startup high-speed camera session.",
            )
            readyLatch.countDown()
        }
    }

    private fun drainStartupEncoder(
        codec: MediaCodec,
        muxer: MediaMuxer,
        state: StartupEncoderDrainState,
        timeoutUs: Long,
    ): Boolean {
        val bufferInfo = MediaCodec.BufferInfo()
        var waitUs = timeoutUs
        while (true) {
            when (val index = codec.dequeueOutputBuffer(bufferInfo, waitUs)) {
                MediaCodec.INFO_TRY_AGAIN_LATER -> return false
                MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    if (state.muxerStarted) {
                        throw IllegalStateException("Startup encoder format changed twice.")
                    }
                    state.trackIndex = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    state.muxerStarted = true
                }
                MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> {
                    // No-op on API levels that still report this signal.
                }
                else -> {
                    if (index < 0) {
                        return false
                    }
                    val encodedBuffer = codec.getOutputBuffer(index)
                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                        bufferInfo.size = 0
                    }
                    if (bufferInfo.size > 0) {
                        if (!state.muxerStarted || state.trackIndex < 0) {
                            throw IllegalStateException(
                                "Startup encoder emitted data before muxer start.",
                            )
                        }
                        if (encodedBuffer == null) {
                            throw IllegalStateException("Startup encoder output buffer was null.")
                        }
                        encodedBuffer.position(bufferInfo.offset)
                        encodedBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(state.trackIndex, encodedBuffer, bufferInfo)
                        if (bufferInfo.presentationTimeUs >= 0) {
                            if (state.firstPtsUs < 0) {
                                state.firstPtsUs = bufferInfo.presentationTimeUs
                            }
                            state.lastPtsUs = bufferInfo.presentationTimeUs
                        }
                        state.frameCount += 1
                    }
                    val sawEos =
                        (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                    codec.releaseOutputBuffer(index, false)
                    if (sawEos) {
                        return true
                    }
                }
            }
            waitUs = 0L
        }
    }

    private fun stopStartupCameraSession(
        sessionRef: AtomicReference<CameraConstrainedHighSpeedCaptureSession?>,
        cameraRef: AtomicReference<CameraDevice?>,
    ) {
        runOnMainSync {
            val session = sessionRef.getAndSet(null)
            try {
                session?.stopRepeating()
            } catch (_: Exception) {
            }
            try {
                session?.abortCaptures()
            } catch (_: Exception) {
            }
            try {
                session?.close()
            } catch (_: Exception) {
            }
            val cameraDevice = cameraRef.getAndSet(null)
            try {
                cameraDevice?.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun runOnMainSync(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            block()
            return
        }
        val latch = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        mainHandler.post {
            try {
                block()
            } catch (error: Throwable) {
                failure.set(error)
            } finally {
                latch.countDown()
            }
        }
        if (!latch.await(3, TimeUnit.SECONDS)) {
            throw IllegalStateException("Timed out waiting for camera main thread.")
        }
        failure.get()?.let { throw IllegalStateException(it.message, it) }
    }

    private fun saveBufferedClip(
        outputPath: String,
        triggerEpochMs: Long,
        result: MethodChannel.Result,
    ) {
        if (!bufferingEnabled) {
            result.error("buffer_inactive", "Rolling buffer is not active.", null)
            return
        }

        val clipStartEpochMs = triggerEpochMs - ROLLING_BUFFER_QUEUE_MS
        val clipEndEpochMs = triggerEpochMs
        sealCurrentSegment(
            restartAfterFinalize = true,
            callback = {
                val selectedSegments = completedSegments.filter { segment ->
                    segment.endEpochMs > clipStartEpochMs &&
                        segment.startEpochMs < clipEndEpochMs
                }
                if (selectedSegments.isEmpty()) {
                    mainHandler.post {
                        result.error(
                            "buffer_empty",
                            "No buffered segments overlap the requested clip window.",
                            null,
                        )
                    }
                    return@sealCurrentSegment
                }

                mergeExecutor.execute {
                    try {
                        validateRequiredHighSpeedSegments(selectedSegments)
                        mergeSegments(
                            segments = selectedSegments,
                            outputPath = outputPath,
                            clipStartEpochMs = clipStartEpochMs,
                            clipEndEpochMs = clipEndEpochMs,
                        )
                        mainHandler.post { result.success(outputPath) }
                    } catch (error: Exception) {
                        mainHandler.post {
                            result.error(
                                "buffer_export_failed",
                                error.message ?: "Unable to export buffered clip.",
                                null,
                            )
                        }
                    }
                }
            },
        )
    }

    private fun validateRequiredHighSpeedSegments(segments: List<BufferedSegment>) {
        for (segment in segments) {
            val targetFps = segment.targetFps ?: continue
            val fps = probeVideoTrackNominalFrameRate(segment.path)
                ?: throw IllegalStateException(
                    "Unable to verify ${targetFps}fps rolling-buffer segment.",
                )
            val minimumFps = minimumRecordedFpsForTarget(targetFps)
            if (fps < minimumFps) {
                throw IllegalStateException(
                    "Rolling-buffer segment is ${"%.1f".format(fps)}fps, expected ${targetFps}fps.",
                )
            }
        }
    }

    private fun isRecordedSegmentFpsValid(targetFps: Int?, achievedFps: Double?): Boolean {
        if (targetFps == null) {
            return true
        }
        val fps = achievedFps ?: return false
        return fps >= minimumRecordedFpsForTarget(targetFps)
    }

    private fun minimumRecordedFpsForTarget(targetFps: Int): Double {
        val toleranceFloor = targetFps * HIGH_SPEED_EXPORT_FPS_TOLERANCE
        return if (targetFps >= 60) {
            maxOf(MIN_REQUIRED_HIGH_SPEED_EXPORT_FPS, toleranceFloor)
        } else {
            toleranceFloor
        }
    }

    private fun mergeSegments(
        segments: List<BufferedSegment>,
        outputPath: String,
        clipStartEpochMs: Long,
        clipEndEpochMs: Long,
    ) {
        val outputFile = File(outputPath)
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) {
            outputFile.delete()
        }

        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var started = false

        try {
            val firstPath = segments.first().path
            var videoFormat: MediaFormat? = null
            var audioFormat: MediaFormat? = null
            val probe = MediaExtractor()
            try {
                probe.setDataSource(firstPath)
                for (i in 0 until probe.trackCount) {
                    val format = probe.getTrackFormat(i)
                    val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                    if (mime.startsWith("video/") && videoFormat == null) {
                        videoFormat = format
                    } else if (mime.startsWith("audio/") && audioFormat == null) {
                        audioFormat = format
                    }
                }
            } finally {
                probe.release()
            }

            if (videoFormat == null) {
                throw IllegalStateException("No video track in buffered segments.")
            }

            val vFmt = videoFormat!!
            writeFrameRateIntoFormat(vFmt, probeVideoTrackNominalFrameRate(firstPath))
            val outputVideoTrack = muxer.addTrack(vFmt)
            val outputAudioTrack = audioFormat?.let { muxer.addTrack(it) } ?: -1

            applyOrientationHint(firstPath, muxer)

            var bufferSize = 1024 * 1024
            if (vFmt.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                bufferSize = maxOf(
                    bufferSize,
                    vFmt.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE),
                )
            }
            val aFmt = audioFormat
            if (aFmt != null && aFmt.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                bufferSize = maxOf(
                    bufferSize,
                    aFmt.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE),
                )
            }

            muxer.start()
            started = true

            val buffer = ByteBuffer.allocate(bufferSize)
            val bufferInfo = MediaCodec.BufferInfo()

            var outputSegmentStartUs = 0L
            for (segment in segments.sortedBy { it.startEpochMs }) {
                val segmentClipStartUs =
                    (maxOf(clipStartEpochMs, segment.startEpochMs) - segment.startEpochMs) * 1000L
                val segmentClipEndUs =
                    (minOf(clipEndEpochMs, segment.endEpochMs) - segment.startEpochMs) * 1000L
                if (segmentClipEndUs <= segmentClipStartUs) {
                    continue
                }
                muxInterleavedSegmentSamples(
                    segment = segment,
                    muxer = muxer,
                    outputVideoTrack = outputVideoTrack,
                    outputAudioTrack = outputAudioTrack,
                    clipStartEpochMs = clipStartEpochMs,
                    clipEndEpochMs = clipEndEpochMs,
                    outputSegmentStartUs = outputSegmentStartUs,
                    buffer = buffer,
                    bufferInfo = bufferInfo,
                )
                outputSegmentStartUs += segmentClipEndUs - segmentClipStartUs
            }
        } finally {
            if (started) {
                muxer.stop()
            }
            muxer.release()
        }
    }

    /**
     * Interleaves video/audio by presentation time using two extractors so behavior is correct
     * on API 21 where only one [MediaExtractor] track may be selected at a time.
     */
    private fun muxInterleavedSegmentSamples(
        segment: BufferedSegment,
        muxer: MediaMuxer,
        outputVideoTrack: Int,
        outputAudioTrack: Int,
        clipStartEpochMs: Long,
        clipEndEpochMs: Long,
        outputSegmentStartUs: Long,
        buffer: ByteBuffer,
        bufferInfo: MediaCodec.BufferInfo,
    ) {
        val segmentClipStartUs =
            (maxOf(clipStartEpochMs, segment.startEpochMs) - segment.startEpochMs) * 1000L
        val segmentClipEndUs =
            (minOf(clipEndEpochMs, segment.endEpochMs) - segment.startEpochMs) * 1000L

        val videoEx = MediaExtractor()
        val audioEx = MediaExtractor()
        try {
            videoEx.setDataSource(segment.path)
            audioEx.setDataSource(segment.path)

            val videoIndex = findTrackIndexForMimePrefix(videoEx, "video/")
            val audioIndex = findTrackIndexForMimePrefix(audioEx, "audio/")

            if (videoIndex >= 0) {
                videoEx.selectTrack(videoIndex)
                videoEx.seekTo(segmentClipStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }
            val hasAudio = outputAudioTrack >= 0 && audioIndex >= 0
            if (hasAudio) {
                audioEx.selectTrack(audioIndex)
                audioEx.seekTo(segmentClipStartUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            }

            var videoDone = videoIndex < 0
            var audioDone = !hasAudio

            while (!videoDone || !audioDone) {
                val vTime = if (!videoDone && videoEx.sampleTrackIndex == videoIndex) {
                    videoEx.sampleTime
                } else {
                    Long.MAX_VALUE
                }
                val aTime = if (!audioDone && audioEx.sampleTrackIndex == audioIndex) {
                    audioEx.sampleTime
                } else {
                    Long.MAX_VALUE
                }

                if (vTime == Long.MAX_VALUE && aTime == Long.MAX_VALUE) {
                    break
                }

                val useVideo = when {
                    videoDone -> false
                    audioDone -> true
                    else -> vTime <= aTime
                }

                val ex = if (useVideo) videoEx else audioEx
                val muxTrack = if (useVideo) outputVideoTrack else outputAudioTrack
                val selected = if (useVideo) videoIndex else audioIndex

                if (ex.sampleTrackIndex != selected) {
                    if (useVideo) {
                        videoDone = true
                    } else {
                        audioDone = true
                    }
                    continue
                }

                val sampleTimeUs = ex.sampleTime
                if (sampleTimeUs < segmentClipStartUs) {
                    if (!ex.advance()) {
                        if (useVideo) videoDone = true else audioDone = true
                    }
                    continue
                }
                if (sampleTimeUs > segmentClipEndUs) {
                    if (useVideo) videoDone = true else audioDone = true
                    continue
                }

                bufferInfo.offset = 0
                bufferInfo.size = ex.readSampleData(buffer, 0)
                if (bufferInfo.size < 0) {
                    if (useVideo) videoDone = true else audioDone = true
                    continue
                }
                bufferInfo.presentationTimeUs =
                    outputSegmentStartUs + sampleTimeUs - segmentClipStartUs
                bufferInfo.flags = ex.sampleFlags
                muxer.writeSampleData(muxTrack, buffer, bufferInfo)
                if (!ex.advance()) {
                    if (useVideo) videoDone = true else audioDone = true
                }
            }
        } finally {
            videoEx.release()
            audioEx.release()
        }
    }

    private fun findTrackIndexForMimePrefix(
        extractor: MediaExtractor,
        mimePrefix: String,
    ): Int {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith(mimePrefix)) {
                return i
            }
        }
        return -1
    }

    private fun applyOrientationHint(sourcePath: String, muxer: MediaMuxer) {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(sourcePath)
            val rotation =
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull()
            if (rotation != null) {
                muxer.setOrientationHint(rotation)
            }
        } finally {
            retriever.release()
        }
    }

    private fun pruneRetentionExtraMs(): Long {
        if (!isHighFpsRollingBuffer()) {
            return 4000L
        }
        val nominal = nominalTargetFpsForPreference()
        return (4000L + (nominal / 30) * 2000L).coerceAtMost(22_000L)
    }

    private fun pruneSegments(nowEpochMs: Long) {
        val cutoff = nowEpochMs - (ROLLING_BUFFER_QUEUE_MS + pruneRetentionExtraMs())
        while (completedSegments.isNotEmpty() && completedSegments.first().endEpochMs < cutoff) {
            val expired = completedSegments.removeFirst()
            File(expired.path).delete()
        }
    }

    private fun clearCompletedSegments() {
        while (completedSegments.isNotEmpty()) {
            val segment = completedSegments.removeFirst()
            File(segment.path).delete()
        }
    }

    private fun hasAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            activity,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun sendCameraState() {
        val range = logicalZoomRange()
        requestedZoomRatio = requestedZoomRatio.coerceIn(range.first, range.second)
        eventSink?.success(
            mapOf(
                "type" to "camera_state",
                "lensDirection" to lensDirectionLabel(),
                "minZoom" to range.first.toDouble(),
                "maxZoom" to range.second.toDouble(),
                "zoom" to requestedZoomRatio.toDouble(),
            ),
        )
    }

    private fun sendBufferState() {
        val segmentRecording = currentRecording != null || currentHighSpeedSegmentActive
        val targetFps = when {
            highSpeedFallbackActive -> 30
            activeHighSpeedTargetFps != null -> activeHighSpeedTargetFps!!
            else -> nominalTargetFpsForPreference()
        }
        val profileSize = activeHighSpeedSize
        val bufferFrameCapacity = ((targetFps * ROLLING_BUFFER_QUEUE_MS) / 1000L)
            .toInt()
            .coerceAtLeast(1)
        val profileWidth = profileSize?.width ?: 0
        val profileHeight = profileSize?.height ?: 0
        val stateKey = listOf(
            bufferingEnabled,
            segmentRecording,
            highSpeedSegmentStarting,
            completedSegments.size,
            targetFps,
            profileWidth,
            profileHeight,
            bufferFrameCapacity,
        ).joinToString(separator = ":")
        if (lastLoggedBufferStateKey != stateKey) {
            Log.i(
                ROLLING_BUFFER_LOG,
                "Buffer state buffering=$bufferingEnabled recording=$segmentRecording " +
                    "starting=$highSpeedSegmentStarting profile=${profileWidth}x$profileHeight " +
                    "fps=$targetFps frames=$bufferFrameCapacity durationMs=$ROLLING_BUFFER_QUEUE_MS " +
                    "completed=${completedSegments.size}",
            )
            lastLoggedBufferStateKey = stateKey
        }
        eventSink?.success(
            mapOf(
                "type" to "buffer_state",
                "buffering" to bufferingEnabled,
                "completedSegmentCount" to completedSegments.size,
                "segmentSliceMs" to segmentDurationMs,
                "queueFrameCapacity" to bufferFrameCapacity,
                "queueDurationMs" to ROLLING_BUFFER_QUEUE_MS,
                "videoFpsMode" to videoFpsMode,
                "targetFps" to targetFps.toDouble(),
                "profileWidth" to profileWidth,
                "profileHeight" to profileHeight,
                "achievedFps" to lastAchievedFps,
                "highSpeed" to isHighFpsRollingBuffer(),
                "segmentRecording" to segmentRecording,
                "segmentStarting" to highSpeedSegmentStarting,
            ),
        )
    }

    private fun probeVideoTrackNominalFrameRate(path: String): Double? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("video/") && format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    return format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                }
            }
        } catch (_: Exception) {
            return deriveVideoFrameRateFromSamples(path)
        } finally {
            extractor.release()
        }
        return deriveVideoFrameRateFromSamples(path)
    }

    private fun deriveVideoFrameRateFromSamples(path: String): Double? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(path)
            var videoTrack = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    ?: continue
                if (mime.startsWith("video/")) {
                    videoTrack = i
                    break
                }
            }
            if (videoTrack < 0) {
                return null
            }

            extractor.selectTrack(videoTrack)
            var firstTimeUs = -1L
            var lastTimeUs = -1L
            var frames = 0
            while (frames < 1200 && extractor.sampleTrackIndex == videoTrack) {
                val sampleTimeUs = extractor.sampleTime
                if (sampleTimeUs < 0) {
                    break
                }
                if (firstTimeUs < 0) {
                    firstTimeUs = sampleTimeUs
                }
                lastTimeUs = sampleTimeUs
                frames += 1
                if (!extractor.advance()) {
                    break
                }
            }
            if (frames >= 2 && lastTimeUs > firstTimeUs) {
                return (frames - 1) * 1_000_000.0 / (lastTimeUs - firstTimeUs)
            }
        } catch (_: Exception) {
            return null
        } finally {
            extractor.release()
        }
        return null
    }

    private fun writeFrameRateIntoFormat(format: MediaFormat, frameRate: Double?) {
        if (frameRate == null || frameRate <= 0.0 || frameRate.isNaN() || frameRate.isInfinite()) {
            return
        }
        format.setInteger(
            MediaFormat.KEY_FRAME_RATE,
            frameRate.roundToInt().coerceAtLeast(1),
        )
    }

    private fun sendError(code: String, message: String) {
        eventSink?.success(
            mapOf(
                "type" to "error",
                "code" to code,
                "message" to message,
            ),
        )
    }

    private fun lensDirectionLabel(): String {
        return if (lensFacing == CameraSelector.LENS_FACING_FRONT) {
            "front"
        } else {
            "back"
        }
    }
}

private class NativePreviewViewFactory(
    private val pipeline: NativeCapturePipeline,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        return NativePreviewPlatformView(context, pipeline)
    }
}

private class NativePreviewPlatformView(
    context: Context,
    private val pipeline: NativeCapturePipeline,
) : PlatformView {
    private val textureView = TextureView(context)

    init {
        pipeline.attachPreviewView(textureView)
    }

    override fun getView(): View = textureView

    override fun dispose() {
        pipeline.detachPreviewView(textureView)
    }
}
