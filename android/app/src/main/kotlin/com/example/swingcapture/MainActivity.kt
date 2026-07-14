package com.lumiaiq.MotionCapture

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.Manifest
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.view.KeyEvent
import android.webkit.MimeTypeMap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.pose.Pose
import com.google.mlkit.vision.pose.PoseDetection
import com.google.mlkit.vision.pose.PoseLandmark
import com.google.mlkit.vision.pose.defaults.PoseDetectorOptions
import java.io.File
import java.nio.ByteBuffer
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val ACTION_RUN_HIGH_SPEED_BUFFER_SELF_TEST =
            "com.lumiaiq.MotionCapture.RUN_HIGH_SPEED_BUFFER_SELF_TEST"
    }

    private val channelName = "swingcapture/capture"
    private val captureEventChannelName = "swingcapture/capture_events"
    private val dualCameraBleChannelName = "swingcapture/dual_camera_ble"
    private val dualCameraBleEventChannelName = "swingcapture/dual_camera_ble_events"
    private val volumeKeyChannelName = "swingcapture/volume_keys"
    private val nativePreviewViewType = "swingcapture/native_preview"
    private val pickVideoRequestCode = 8401
    private val notificationPermissionRequestCode = 8402
    private val videoProgressNotificationId = 8403
    private val videoProgressChannelId = "video_pose_processing"

    private var volumeKeySink: EventChannel.EventSink? = null
    private var captureEventSink: EventChannel.EventSink? = null
    private var consumeVolumeKeys: Boolean = false
    private var pendingVideoPickResult: MethodChannel.Result? = null
    private var pendingVideoPickDestinationDirectory: String? = null
    private var pendingVideoPickFilePrefix: String? = null
    private val videoImportExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private lateinit var nativeCapturePipeline: NativeCapturePipeline
    private lateinit var dualCameraBleControl: DualCameraBleControl

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeCapturePipeline = NativeCapturePipeline(this)
        dualCameraBleControl = DualCameraBleControl(this)

        flutterEngine.platformViewsController.registry.registerViewFactory(
            nativePreviewViewType,
            nativeCapturePipeline.createPreviewFactory(),
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            volumeKeyChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    volumeKeySink = events
                }

                override fun onCancel(arguments: Any?) {
                    volumeKeySink = null
                }
            },
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            captureEventChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    captureEventSink = events
                    nativeCapturePipeline.attachEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    captureEventSink = null
                    nativeCapturePipeline.attachEventSink(null)
                }
            },
        )

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            dualCameraBleEventChannelName,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    dualCameraBleControl.setEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    dualCameraBleControl.setEventSink(null)
                }
            },
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            dualCameraBleChannelName,
        ).setMethodCallHandler { call, result ->
            dualCameraBleControl.handleMethodCall(call, result)
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "createAlbumIfNeeded",
                "saveToGallery" -> result.success(null)
                "pickVideoFromLibrary" -> pickVideoFromLibrary(call, result)
                "readVideoMetadata" -> readVideoMetadata(call, result)
                "extractPoseFramesFromVideo" -> extractPoseFramesFromVideo(call, result)
                "setVolumeKeysConsumed" -> {
                    consumeVolumeKeys = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                "saveClip" -> saveClip(call, result)
                "getCapabilities",
                "startCapture",
                "stopCapture",
                "setSensitivity",
                "getSavedClips",
                "startPreview",
                "queryRecordingCapability",
                "stopPreview",
                "startDetection",
                "stopDetection",
                "startBuffering",
                "stopBuffering",
                "saveBufferedClip",
                "runStartupBufferTest",
                "switchCamera",
                "setZoomRatio",
                "startRtmpStream",
                "stopRtmpStream",
                "setRtmpSwingBitrate",
                "sendSwingMarker",
                "publishSwingClip" -> nativeCapturePipeline.handleMethodCall(call, result)
                "getAlbums" -> result.success(listOf("SwingCapture"))
                else -> result.notImplemented()
            }
        }
        maybeRunHighSpeedBufferSelfTest(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        maybeRunHighSpeedBufferSelfTest(intent)
    }

    override fun onDestroy() {
        dualCameraBleControl.stop()
        nativeCapturePipeline.dispose()
        videoImportExecutor.shutdown()
        super.onDestroy()
    }

    private fun maybeRunHighSpeedBufferSelfTest(intent: Intent?) {
        if (
            applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0 ||
            intent?.action != ACTION_RUN_HIGH_SPEED_BUFFER_SELF_TEST
        ) {
            return
        }
        intent.action = null
        Handler(Looper.getMainLooper()).postDelayed(
            { nativeCapturePipeline.runDebugHighSpeedBufferSelfTest() },
            1500L,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickVideoRequestCode) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val pendingResult = pendingVideoPickResult
        val destinationDirectory = pendingVideoPickDestinationDirectory
        val filePrefix = pendingVideoPickFilePrefix ?: "imported_video"
        pendingVideoPickResult = null
        pendingVideoPickDestinationDirectory = null
        pendingVideoPickFilePrefix = null

        if (pendingResult == null) {
            return
        }
        if (resultCode != Activity.RESULT_OK || data?.data == null || destinationDirectory == null) {
            pendingResult.success(null)
            return
        }

        val uri = data.data!!
        videoImportExecutor.execute {
            try {
                val copied = copyPickedVideoToAppStorage(
                    uri = uri,
                    destinationDirectory = destinationDirectory,
                    filePrefix = filePrefix,
                )
                val durationMs = readDurationMs(copied.path)
                val response = mapOf(
                    "videoPath" to copied.path,
                    "durationMs" to durationMs,
                    "displayName" to copied.name,
                )
                runOnUiThread { pendingResult.success(response) }
            } catch (error: Exception) {
                runOnUiThread {
                    pendingResult.error(
                        "video_import_failed",
                        error.message ?: "Failed to import selected video.",
                        null,
                    )
                }
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (consumeVolumeKeys &&
            volumeKeySink != null &&
            event.action == KeyEvent.ACTION_DOWN &&
            (event.keyCode == KeyEvent.KEYCODE_VOLUME_UP ||
                event.keyCode == KeyEvent.KEYCODE_VOLUME_DOWN)
        ) {
            volumeKeySink?.success("toggle")
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    private fun pickVideoFromLibrary(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        if (pendingVideoPickResult != null) {
            result.error("picker_busy", "A video picker is already open.", null)
            return
        }
        val destinationDirectory = call.argument<String>("destinationDirectory")
        if (destinationDirectory == null) {
            result.error(
                "invalid_args",
                "pickVideoFromLibrary requires destinationDirectory.",
                null,
            )
            return
        }

        pendingVideoPickResult = result
        pendingVideoPickDestinationDirectory = destinationDirectory
        pendingVideoPickFilePrefix = call.argument<String>("filePrefix")

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "video/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivityForResult(
                Intent.createChooser(intent, "Select video"),
                pickVideoRequestCode,
            )
        } catch (error: Exception) {
            pendingVideoPickResult = null
            pendingVideoPickDestinationDirectory = null
            pendingVideoPickFilePrefix = null
            result.error(
                "picker_unavailable",
                error.message ?: "No video picker is available.",
                null,
            )
        }
    }

    private fun extractPoseFramesFromVideo(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val videoPath = call.argument<String>("videoPath")
        if (videoPath == null) {
            result.error(
                "invalid_args",
                "extractPoseFramesFromVideo requires videoPath.",
                null,
            )
            return
        }
        val targetFps = (
            call.argument<Number>("targetFps")?.toDouble() ?: 12.0
            ).coerceIn(1.0, 30.0)
        val maxFrames = (
            call.argument<Number>("maxFrames")?.toInt() ?: 1800
            ).coerceIn(1, 10000)
        val jobId = call.argument<String>("jobId") ?: "video_pose_import"
        requestNotificationPermissionIfNeeded()

        videoImportExecutor.execute {
            val detector = PoseDetection.getClient(
                PoseDetectorOptions.Builder()
                    .setDetectorMode(PoseDetectorOptions.SINGLE_IMAGE_MODE)
                    .build(),
            )
            val retriever = MediaMetadataRetriever()
            try {
                retriever.setDataSource(videoPath)
                val durationMs = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_DURATION,
                )?.toLongOrNull() ?: 0L
                if (durationMs <= 0L) {
                    throw IllegalStateException("Could not read video duration.")
                }
                val rotationDegrees = retriever.extractMetadata(
                    MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION,
                )?.toIntOrNull() ?: 0
                val durationUs = durationMs * 1000L
                val stepUs = (1_000_000.0 / targetFps).toLong().coerceAtLeast(1L)
                val totalSamples = minOf(((durationUs / stepUs) + 1L).toInt(), maxFrames)
                    .coerceAtLeast(1)
                val frames = mutableListOf<Map<String, Any>>()
                var poseFrameCount = 0
                var timeUs = 0L
                var processedSamples = 0
                var lastProgressUpdateMs = 0L

                emitVideoImportProgress(
                    jobId = jobId,
                    phase = "extracting",
                    progress = 0.0,
                    processedFrames = 0,
                    totalFrames = totalSamples,
                    message = "Extracting pose JSON... 0%",
                )
                updateVideoProgressNotification(
                    progressPercent = 0,
                    text = "Plug in power if this is a long video.",
                    ongoing = true,
                )

                while (timeUs <= durationUs && processedSamples < totalSamples) {
                    processedSamples += 1
                    val bitmap = retriever.getFrameAtTime(
                        timeUs,
                        MediaMetadataRetriever.OPTION_CLOSEST,
                    )
                    if (bitmap != null) {
                        val inputImage = InputImage.fromBitmap(bitmap, rotationDegrees)
                        val pose = Tasks.await(detector.process(inputImage))
                        val landmarks = poseLandmarksForVideoFrame(
                            pose = pose,
                            imageWidth = bitmap.width,
                            imageHeight = bitmap.height,
                            rotationDegrees = rotationDegrees,
                        )
                        if (landmarks.isNotEmpty()) {
                            poseFrameCount += 1
                        }
                        frames.add(
                            mapOf(
                                "offsetMs" to (timeUs / 1000L).coerceAtMost(durationMs),
                                "landmarks" to landmarks,
                            ),
                        )
                        bitmap.recycle()
                    }
                    val nowMs = System.currentTimeMillis()
                    if (nowMs - lastProgressUpdateMs >= 300L ||
                        processedSamples >= totalSamples
                    ) {
                        lastProgressUpdateMs = nowMs
                        val progress = (processedSamples.toDouble() / totalSamples.toDouble())
                            .coerceIn(0.0, 1.0)
                        val percent = (progress * 100).toInt().coerceIn(0, 100)
                        val message = "Extracting pose JSON... $percent%"
                        emitVideoImportProgress(
                            jobId = jobId,
                            phase = "extracting",
                            progress = progress,
                            processedFrames = processedSamples,
                            totalFrames = totalSamples,
                            message = message,
                        )
                        updateVideoProgressNotification(
                            progressPercent = percent,
                            text = message,
                            ongoing = true,
                        )
                    }
                    timeUs += stepUs
                }

                val response = mapOf(
                    "durationMs" to durationMs,
                    "frameCount" to frames.size,
                    "poseFrameCount" to poseFrameCount,
                    "frames" to frames,
                )
                emitVideoImportProgress(
                    jobId = jobId,
                    phase = "completed",
                    progress = 1.0,
                    processedFrames = processedSamples,
                    totalFrames = totalSamples,
                    message = "Pose JSON ready.",
                )
                updateVideoProgressNotification(
                    progressPercent = 100,
                    text = "Pose JSON ready.",
                    ongoing = false,
                )
                runOnUiThread { result.success(response) }
            } catch (error: Exception) {
                emitVideoImportProgress(
                    jobId = jobId,
                    phase = "failed",
                    progress = 0.0,
                    processedFrames = 0,
                    totalFrames = null,
                    message = "Pose extraction failed.",
                )
                updateVideoProgressNotification(
                    progressPercent = null,
                    text = "Pose extraction failed.",
                    ongoing = false,
                )
                runOnUiThread {
                    result.error(
                        "pose_extraction_failed",
                        error.message ?: "Failed to extract pose from video.",
                        null,
                    )
                }
            } finally {
                retriever.release()
                detector.close()
            }
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        runOnUiThread {
            requestPermissions(
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationPermissionRequestCode,
            )
        }
    }

    private fun canPostProgressNotification(): Boolean {
        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun updateVideoProgressNotification(
        progressPercent: Int?,
        text: String,
        ongoing: Boolean,
    ) {
        if (!canPostProgressNotification()) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                videoProgressChannelId,
                "Video pose processing",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Progress while imported videos are converted to pose JSON."
            }
            manager.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, videoProgressChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Processing video pose")
            .setContentText(text)
            .setOngoing(ongoing)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_PROGRESS)
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            builder.setPriority(Notification.PRIORITY_LOW)
        }
        if (progressPercent != null) {
            builder.setProgress(100, progressPercent.coerceIn(0, 100), false)
        } else {
            builder.setProgress(0, 0, false)
        }
        if (!ongoing) {
            builder.setAutoCancel(true)
        }
        try {
            manager.notify(videoProgressNotificationId, builder.build())
        } catch (_: SecurityException) {
            // Notification permission may be denied while the in-app progress remains active.
        }
    }

    private fun emitVideoImportProgress(
        jobId: String,
        phase: String,
        progress: Double,
        processedFrames: Int,
        totalFrames: Int?,
        message: String,
    ) {
        runOnUiThread {
            val payload = mutableMapOf<String, Any>(
                "type" to "video_import_progress",
                "jobId" to jobId,
                "phase" to phase,
                "progress" to progress.coerceIn(0.0, 1.0),
                "processedFrames" to processedFrames,
                "message" to message,
            )
            if (totalFrames != null) {
                payload["totalFrames"] = totalFrames
            }
            captureEventSink?.success(payload)
        }
    }

    private fun copyPickedVideoToAppStorage(
        uri: Uri,
        destinationDirectory: String,
        filePrefix: String,
    ): File {
        val destination = File(destinationDirectory).apply {
            if (!exists()) {
                mkdirs()
            }
        }
        val displayName = queryDisplayName(uri) ?: "imported_video"
        val extension = videoFileExtension(uri, displayName)
        val prefix = sanitizeFileSegment(filePrefix).ifBlank { "imported_video" }
        var outFile = File(destination, "$prefix$extension")
        var suffix = 1
        while (outFile.exists()) {
            outFile = File(destination, "${prefix}_$suffix$extension")
            suffix += 1
        }

        val input = contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Could not open selected video.")
        input.use { source ->
            outFile.outputStream().use { target ->
                source.copyTo(target)
            }
        }
        return outFile
    }

    private fun queryDisplayName(uri: Uri): String? {
        return contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0 && cursor.moveToFirst()) {
                cursor.getString(index)
            } else {
                null
            }
        }
    }

    private fun videoFileExtension(uri: Uri, displayName: String): String {
        val fromName = displayName.substringAfterLast('.', missingDelimiterValue = "")
        if (fromName.isNotBlank() && fromName.length <= 8) {
            return ".${sanitizeFileSegment(fromName.lowercase(Locale.US))}"
        }
        val mime = contentResolver.getType(uri)
        val fromMime = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime)
        return if (fromMime.isNullOrBlank()) ".mp4" else ".$fromMime"
    }

    private fun sanitizeFileSegment(value: String): String {
        return value.replace(Regex("[^A-Za-z0-9._-]"), "_")
    }

    private fun poseLandmarksForVideoFrame(
        pose: Pose,
        imageWidth: Int,
        imageHeight: Int,
        rotationDegrees: Int,
    ): List<Map<String, Any>> {
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
        return buildList {
            addVideoLandmark(this, pose, PoseLandmark.NOSE, "nose", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_SHOULDER, "leftShoulder", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_SHOULDER, "rightShoulder", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_ELBOW, "leftElbow", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_ELBOW, "rightElbow", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_WRIST, "leftWrist", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_WRIST, "rightWrist", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_HIP, "leftHip", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_HIP, "rightHip", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_KNEE, "leftKnee", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_KNEE, "rightKnee", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.LEFT_ANKLE, "leftAnkle", orientedWidth, orientedHeight)
            addVideoLandmark(this, pose, PoseLandmark.RIGHT_ANKLE, "rightAnkle", orientedWidth, orientedHeight)
        }
    }

    private fun addVideoLandmark(
        out: MutableList<Map<String, Any>>,
        pose: Pose,
        type: Int,
        name: String,
        orientedWidth: Double,
        orientedHeight: Double,
    ) {
        val landmark = pose.getPoseLandmark(type) ?: return
        out.add(
            mapOf(
                "name" to name,
                "x" to (landmark.position.x / orientedWidth).coerceIn(0.0, 1.0),
                "y" to (landmark.position.y / orientedHeight).coerceIn(0.0, 1.0),
                "confidence" to landmark.inFrameLikelihood.toDouble(),
            ),
        )
    }

    private fun saveClip(call: io.flutter.plugin.common.MethodCall, result: MethodChannel.Result) {
        val sourcePath = call.argument<String>("sourcePath")
        val outputPath = call.argument<String>("outputPath")
        val triggerMs = call.argument<Number>("triggerMs")?.toLong()
        val preRollMs = call.argument<Number>("preRollMs")?.toLong()
        val postRollMs = call.argument<Number>("postRollMs")?.toLong()

        if (
            sourcePath == null ||
            outputPath == null ||
            triggerMs == null ||
            preRollMs == null ||
            postRollMs == null
        ) {
            result.error(
                "invalid_args",
                "saveClip requires sourcePath/outputPath/triggerMs/preRollMs/postRollMs",
                null
            )
            return
        }

        try {
            val durationMs = readDurationMs(sourcePath)
            val clipStartMs = maxOf(0L, triggerMs - preRollMs)
            val clipEndMs = minOf(durationMs, triggerMs + postRollMs)
            if (clipEndMs <= clipStartMs) {
                result.success(sourcePath)
                return
            }

            trimVideo(
                sourcePath = sourcePath,
                outputPath = outputPath,
                startMs = clipStartMs,
                endMs = clipEndMs
            )
            result.success(outputPath)
        } catch (_: Exception) {
            result.success(sourcePath)
        }
    }

    private fun readVideoMetadata(
        call: io.flutter.plugin.common.MethodCall,
        result: MethodChannel.Result,
    ) {
        val videoPath = call.argument<String>("videoPath")
        if (videoPath.isNullOrBlank()) {
            result.error(
                "invalid_args",
                "readVideoMetadata requires videoPath",
                null
            )
            return
        }

        val durationMs = try {
            readDurationMs(videoPath)
        } catch (_: Exception) {
            0L
        }
        result.success(
            mapOf(
                "durationMs" to durationMs,
                "frameRate" to probeVideoTrackFrameRate(videoPath),
            )
        )
    }

    private fun readDurationMs(sourcePath: String): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(sourcePath)
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 0L
        } finally {
            retriever.release()
        }
    }

    private fun probeVideoTrackFrameRate(sourcePath: String): Double? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sourcePath)
            for (trackIndex in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(trackIndex)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) {
                    continue
                }
                if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                    continue
                }
                val frameRate = try {
                    format.getInteger(MediaFormat.KEY_FRAME_RATE).toDouble()
                } catch (_: Exception) {
                    try {
                        format.getFloat(MediaFormat.KEY_FRAME_RATE).toDouble()
                    } catch (_: Exception) {
                        null
                    }
                }
                if (frameRate != null && frameRate > 0) {
                    return frameRate
                }
            }
        } catch (_: Exception) {
            return deriveVideoFrameRateFromSamples(sourcePath)
        } finally {
            extractor.release()
        }
        return deriveVideoFrameRateFromSamples(sourcePath)
    }

    private fun deriveVideoFrameRateFromSamples(sourcePath: String): Double? {
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(sourcePath)
            var videoTrack = -1
            for (trackIndex in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(trackIndex).getString(MediaFormat.KEY_MIME)
                    ?: continue
                if (mime.startsWith("video/")) {
                    videoTrack = trackIndex
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

    private fun trimVideo(
        sourcePath: String,
        outputPath: String,
        startMs: Long,
        endMs: Long,
    ) {
        val outputFile = File(outputPath)
        if (outputFile.exists()) {
            outputFile.delete()
        }

        val extractor = MediaExtractor()
        extractor.setDataSource(sourcePath)
        val sourceFrameRate = probeVideoTrackFrameRate(sourcePath)

        val trackIndexMap = mutableMapOf<Int, Int>()
        val muxer = MediaMuxer(outputPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)

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

        var bufferSize = 1 * 1024 * 1024
        for (track in 0 until extractor.trackCount) {
            val format = extractor.getTrackFormat(track)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("video/") || mime.startsWith("audio/")) {
                extractor.selectTrack(track)
                if (mime.startsWith("video/")) {
                    writeFrameRateIntoFormat(format, sourceFrameRate)
                }
                trackIndexMap[track] = muxer.addTrack(format)
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    bufferSize = maxOf(bufferSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
        }

        muxer.start()

        val startUs = startMs * 1000
        val endUs = endMs * 1000
        extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

        val buffer = ByteBuffer.allocate(bufferSize)
        val bufferInfo = MediaCodec.BufferInfo()

        while (true) {
            val sampleTrackIndex = extractor.sampleTrackIndex
            if (sampleTrackIndex < 0) {
                break
            }

            val sampleTimeUs = extractor.sampleTime
            if (sampleTimeUs < startUs) {
                extractor.advance()
                continue
            }
            if (sampleTimeUs > endUs) {
                break
            }

            bufferInfo.offset = 0
            bufferInfo.size = extractor.readSampleData(buffer, 0)
            if (bufferInfo.size < 0) {
                break
            }

            bufferInfo.presentationTimeUs = sampleTimeUs - startUs
            bufferInfo.flags = extractor.sampleFlags

            val mappedTrackIndex = trackIndexMap[sampleTrackIndex]
            if (mappedTrackIndex != null) {
                muxer.writeSampleData(mappedTrackIndex, buffer, bufferInfo)
            }
            extractor.advance()
        }

        muxer.stop()
        muxer.release()
        extractor.release()
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
}
