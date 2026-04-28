package com.example.swingcapture

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.view.KeyEvent
import java.io.File
import java.nio.ByteBuffer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "swingcapture/capture"
    private val captureEventChannelName = "swingcapture/capture_events"
    private val volumeKeyChannelName = "swingcapture/volume_keys"
    private val nativePreviewViewType = "swingcapture/native_preview"

    private var volumeKeySink: EventChannel.EventSink? = null
    private var consumeVolumeKeys: Boolean = false
    private lateinit var nativeCapturePipeline: NativeCapturePipeline

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        nativeCapturePipeline = NativeCapturePipeline(this)

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
                    nativeCapturePipeline.attachEventSink(events)
                }

                override fun onCancel(arguments: Any?) {
                    nativeCapturePipeline.attachEventSink(null)
                }
            },
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            channelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "createAlbumIfNeeded",
                "saveToGallery" -> result.success(null)
                "setVolumeKeysConsumed" -> {
                    consumeVolumeKeys = call.arguments as? Boolean ?: false
                    result.success(null)
                }
                "saveClip" -> saveClip(call, result)
                "startPreview",
                "stopPreview",
                "startDetection",
                "stopDetection",
                "startBuffering",
                "stopBuffering",
                "saveBufferedClip",
                "switchCamera",
                "setZoomRatio" -> nativeCapturePipeline.handleMethodCall(call, result)
                "getAlbums" -> result.success(listOf("SwingCapture"))
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        nativeCapturePipeline.dispose()
        super.onDestroy()
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
}
