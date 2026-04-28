package com.example.swingcapture

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Handler
import android.os.Looper
import android.view.View
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
import androidx.camera.view.PreviewView
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
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

private data class BufferedSegment(
    val path: String,
    val startEpochMs: Long,
    val endEpochMs: Long,
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

    private var eventSink: EventChannel.EventSink? = null
    private var previewView: PreviewView? = null
    private var previewRequested = false
    private var detectionEnabled = false
    private var isProcessingPose = false
    private var lensFacing = CameraSelector.LENS_FACING_BACK

    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var previewUseCase: Preview? = null
    private var analysisUseCase: ImageAnalysis? = null
    private var recorder: Recorder? = null
    private var videoCapture: VideoCapture<Recorder>? = null

    private var bufferingEnabled = false
    private var preRollMs = 2000L
    private var postRollMs = 2000L
    /** Wall-clock slice length for each rolling file; recomputed when buffering arms. */
    private var segmentDurationMs = 1000L

    private val mergeExecutor: ExecutorService = Executors.newSingleThreadExecutor()

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
    }

    fun createPreviewFactory(): PlatformViewFactory {
        return NativePreviewViewFactory(this)
    }

    fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startPreview" -> {
                previewRequested = true
                ensureCameraProvider()
                bindUseCasesIfReady()
                result.success(null)
            }
            "stopPreview" -> {
                stopPreview()
                result.success(null)
            }
            "startDetection" -> {
                detectionEnabled = true
                result.success(null)
            }
            "stopDetection" -> {
                detectionEnabled = false
                result.success(null)
            }
            "startBuffering" -> {
                val args = call.arguments as? Map<*, *>
                val requestedPreRollMs = (args?.get("preRollMs") as? Number)?.toLong()
                val requestedPostRollMs = (args?.get("postRollMs") as? Number)?.toLong()
                if (requestedPreRollMs != null) {
                    preRollMs = requestedPreRollMs.coerceAtLeast(0L)
                }
                if (requestedPostRollMs != null) {
                    postRollMs = requestedPostRollMs.coerceAtLeast(0L)
                }
                startBuffering()
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
                val requestedPreRollMs = (args?.get("preRollMs") as? Number)?.toLong()
                val requestedPostRollMs = (args?.get("postRollMs") as? Number)?.toLong()
                if (
                    outputPath == null ||
                        triggerEpochMs == null ||
                        requestedPreRollMs == null ||
                        requestedPostRollMs == null
                ) {
                    result.error(
                        "invalid_args",
                        "saveBufferedClip requires outputPath/triggerEpochMs/preRollMs/postRollMs",
                        null,
                    )
                    return
                }
                preRollMs = requestedPreRollMs.coerceAtLeast(0L)
                postRollMs = requestedPostRollMs.coerceAtLeast(0L)
                saveBufferedClip(
                    outputPath = outputPath,
                    triggerEpochMs = triggerEpochMs,
                    result = result,
                )
            }
            "switchCamera" -> {
                lensFacing = if (lensFacing == CameraSelector.LENS_FACING_BACK) {
                    CameraSelector.LENS_FACING_FRONT
                } else {
                    CameraSelector.LENS_FACING_BACK
                }
                bindUseCasesIfReady()
                result.success(mapOf("lensDirection" to lensDirectionLabel()))
            }
            "setZoomRatio" -> {
                val ratio = (call.arguments as? Number)?.toFloat()?.coerceAtLeast(1f) ?: 1f
                camera?.cameraControl?.setZoomRatio(ratio)
                sendCameraState()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun attachPreviewView(view: PreviewView) {
        previewView = view.apply {
            implementationMode = PreviewView.ImplementationMode.COMPATIBLE
            scaleType = PreviewView.ScaleType.FILL_CENTER
        }
        // Surface must exist before bind; Flutter may build the PlatformView slightly
        // after startPreview(), so always arm preview when the view attaches.
        previewRequested = true
        ensureCameraProvider()
        bindUseCasesIfReady()
    }

    fun detachPreviewView(view: PreviewView) {
        if (previewView === view) {
            previewView = null
        }
    }

    fun dispose() {
        stopBuffering(discardSegments = true)
        previewRequested = false
        detectionEnabled = false
        isProcessingPose = false
        eventSink = null
        previewView = null
        camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
        cameraProvider?.unbindAll()
        poseDetector.close()
        analysisExecutor.shutdown()
        mergeExecutor.shutdown()
    }

    private fun stopPreview() {
        previewRequested = false
        stopBuffering(discardSegments = true)
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

    private fun bindUseCasesIfReady() {
        val provider = cameraProvider ?: return
        val view = previewView ?: return
        if (!previewRequested) {
            return
        }

        try {
            camera?.cameraInfo?.zoomState?.removeObserver(zoomObserver)
            provider.unbindAll()

            previewUseCase = Preview.Builder()
                .setTargetAspectRatio(AspectRatio.RATIO_16_9)
                .build()
                .also { preview ->
                    preview.surfaceProvider = view.surfaceProvider
                }

            analysisUseCase = ImageAnalysis.Builder()
                .setTargetAspectRatio(AspectRatio.RATIO_16_9)
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .build()
                .also { analysis ->
                    analysis.setAnalyzer(analysisExecutor) { proxy ->
                        analyzeFrame(proxy)
                    }
                }

            recorder = Recorder.Builder()
                .setQualitySelector(
                    QualitySelector.from(
                        Quality.HD,
                        FallbackStrategy.lowerQualityOrHigherThan(Quality.HD),
                    ),
                )
                .build()

            videoCapture = VideoCapture.withOutput(recorder!!)

            val selector = CameraSelector.Builder()
                .requireLensFacing(lensFacing)
                .build()

            camera = provider.bindToLifecycle(
                activity,
                selector,
                previewUseCase,
                analysisUseCase,
                videoCapture,
            )

            camera?.cameraInfo?.zoomState?.observe(activity, zoomObserver)
            sendCameraState()
            if (bufferingEnabled && currentRecording == null) {
                startNewSegment()
            }
        } catch (error: Exception) {
            sendError(
                code = "camera_bind_failed",
                message = error.message ?: "Unable to bind camera use cases.",
            )
        }
    }

    private fun startBuffering() {
        bufferingEnabled = true
        segmentDurationMs = computeSegmentSliceMs(preRollMs, postRollMs)
        sendBufferState()
        if (currentRecording == null) {
            startNewSegment()
        }
    }

    /**
     * Finer slices improve pre-roll resolution; coarser slices reduce muxer churn.
     * Targets ~4–6 segments covering the full ring window.
     */
    private fun computeSegmentSliceMs(preRollMs: Long, postRollMs: Long): Long {
        val ringWindow = (preRollMs + postRollMs + 1500L).coerceAtLeast(3000L)
        val slice = (ringWindow / 5).coerceIn(600L, 2800L)
        return slice
    }

    private fun stopBuffering(discardSegments: Boolean) {
        bufferingEnabled = false
        mainHandler.removeCallbacks(segmentRotationRunnable)
        if (currentRecording != null) {
            sealCurrentSegment(
                restartAfterFinalize = false,
                callback = {
                    if (discardSegments) {
                        clearCompletedSegments()
                    }
                    sendBufferState()
                },
            )
            return
        }
        if (discardSegments) {
            clearCompletedSegments()
        }
        sendBufferState()
    }

    private fun startNewSegment() {
        if (!bufferingEnabled || currentRecording != null) {
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

    @OptIn(ExperimentalGetImage::class)
    private fun analyzeFrame(imageProxy: ImageProxy) {
        if (!detectionEnabled || isProcessingPose) {
            imageProxy.close()
            return
        }

        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        isProcessingPose = true
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

    private fun saveBufferedClip(
        outputPath: String,
        triggerEpochMs: Long,
        result: MethodChannel.Result,
    ) {
        if (!bufferingEnabled) {
            result.error("buffer_inactive", "Rolling buffer is not active.", null)
            return
        }

        val clipStartEpochMs = triggerEpochMs - preRollMs
        val clipEndEpochMs = triggerEpochMs + postRollMs
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

            for (segment in segments) {
                muxInterleavedSegmentSamples(
                    segment = segment,
                    muxer = muxer,
                    outputVideoTrack = outputVideoTrack,
                    outputAudioTrack = outputAudioTrack,
                    clipStartEpochMs = clipStartEpochMs,
                    clipEndEpochMs = clipEndEpochMs,
                    buffer = buffer,
                    bufferInfo = bufferInfo,
                )
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
        buffer: ByteBuffer,
        bufferInfo: MediaCodec.BufferInfo,
    ) {
        val clipStartUs = clipStartEpochMs * 1000L
        val segmentStartUs = segment.startEpochMs * 1000L
        val segmentClipStartUs = (clipStartUs - segmentStartUs).coerceAtLeast(0L)
        val segmentClipEndUs = (clipEndEpochMs * 1000L - segmentStartUs).coerceAtLeast(0L)

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
                bufferInfo.presentationTimeUs = segmentStartUs + sampleTimeUs - clipStartUs
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

    private fun pruneSegments(nowEpochMs: Long) {
        val cutoff = nowEpochMs - (preRollMs + postRollMs + 4000L)
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
        val zoomState = camera?.cameraInfo?.zoomState?.value
        eventSink?.success(
            mapOf(
                "type" to "camera_state",
                "lensDirection" to lensDirectionLabel(),
                "minZoom" to (zoomState?.minZoomRatio?.toDouble() ?: 1.0),
                "maxZoom" to (zoomState?.maxZoomRatio?.toDouble() ?: 1.0),
                "zoom" to (zoomState?.zoomRatio?.toDouble() ?: 1.0),
            ),
        )
    }

    private fun sendBufferState() {
        eventSink?.success(
            mapOf(
                "type" to "buffer_state",
                "buffering" to bufferingEnabled,
                "completedSegmentCount" to completedSegments.size,
                "segmentSliceMs" to segmentDurationMs,
            ),
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
    private val previewView = PreviewView(context)

    init {
        pipeline.attachPreviewView(previewView)
    }

    override fun getView(): View = previewView

    override fun dispose() {
        pipeline.detachPreviewView(previewView)
    }
}
