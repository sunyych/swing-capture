package com.lumiaiq.MotionCapture

import android.content.Context
import android.media.MediaMetadataRetriever
import android.util.Log
import com.pedro.encoder.input.decoder.AudioDecoderInterface
import com.pedro.encoder.input.decoder.VideoDecoderInterface
import com.pedro.library.generic.GenericFromFile
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService

/**
 * Republishes a saved MP4 to a secondary RTMP URL (e.g. …/swings/&lt;id&gt;).
 */
internal class SwingClipRtmpPublisher(
    private val context: Context,
    private val executor: ExecutorService,
) {
    fun publish(
        filePath: String,
        url: String,
        swingId: String,
        weight: Double,
        onDone: (Boolean, String?) -> Unit,
    ) {
        executor.execute {
            val checker = object : com.pedro.common.ConnectChecker {
                override fun onConnectionStarted(url: String) = Unit
                override fun onConnectionSuccess() = Unit
                override fun onConnectionFailed(reason: String) = Unit
                override fun onDisconnect() = Unit
                override fun onAuthError() = Unit
                override fun onAuthSuccess() = Unit
            }
            val videoIf = VideoDecoderInterface { }
            val audioIf = AudioDecoderInterface { }
            val fromFile = GenericFromFile(context, checker, videoIf, audioIf)
            val file = File(filePath)
            val durationMs = probeDurationMs(filePath)
            val w = weight.coerceIn(0.0, 1.0)
            try {
                if (!fromFile.prepareVideo(filePath)) {
                    onDone(false, "prepareVideo failed")
                    return@execute
                }
                if (!fromFile.prepareAudio(filePath)) {
                    onDone(false, "prepareAudio failed")
                    return@execute
                }
                fromFile.startStream(url)
                Thread.sleep(600)
                val rc = fromFile.reflectRtmpClient()
                if (rc != null) {
                    runBlocking {
                        RtmpSwingAmf.sendSetDataFrame(
                            rc,
                            "onSwingClip",
                            mapOf(
                                "swingId" to swingId,
                                "weight" to w,
                                "durationMs" to durationMs.toDouble(),
                                "filename" to file.name,
                            ),
                        )
                    }
                }
                val deadline = System.currentTimeMillis() + 15 * 60_000L
                while (fromFile.isStreaming && System.currentTimeMillis() < deadline) {
                    Thread.sleep(250)
                }
                try {
                    fromFile.stopStream()
                } catch (_: Exception) {
                }
                onDone(true, null)
            } catch (e: IOException) {
                Log.e(TAG, "clip rtmp", e)
                onDone(false, e.message)
            } catch (e: Exception) {
                Log.e(TAG, "clip rtmp", e)
                onDone(false, e.message)
            }
        }
    }

    private fun probeDurationMs(path: String): Long {
        val retriever = MediaMetadataRetriever()
        try {
            retriever.setDataSource(path)
            val dur = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
            return dur?.toLongOrNull() ?: 0L
        } catch (_: Exception) {
            return 0L
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    companion object {
        private const val TAG = "SwingClipRtmp"
    }
}
