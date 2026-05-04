package com.example.swingcapture

import android.util.Log
import com.pedro.common.TimeUtils
import com.pedro.rtmp.amf.v0.AmfEcmaArray
import com.pedro.rtmp.amf.v0.AmfString
import com.pedro.rtmp.rtmp.CommandsManager
import com.pedro.rtmp.rtmp.RtmpClient
import com.pedro.rtmp.rtmp.message.data.DataAmf0
import com.pedro.rtmp.utils.socket.RtmpSocket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Sends RTMP AMF0 `@setDataFrame` messages (onSwingStart / onSwingEnd / onSwingClip) using the same
 * mutex/socket path as [CommandsManager.sendMetadata].
 */
internal fun Any.reflectRtmpClient(): RtmpClient? {
    return try {
        val f = this.javaClass.getDeclaredField("rtmpClient")
        f.isAccessible = true
        f.get(this) as? RtmpClient
    } catch (_: Exception) {
        null
    }
}

internal object RtmpSwingAmf {
    private const val TAG = "RtmpSwingAmf"

    private fun RtmpClient.reflectSocket(): RtmpSocket? {
        return try {
            val f = RtmpClient::class.java.getDeclaredField("socket")
            f.isAccessible = true
            f.get(this) as? RtmpSocket
        } catch (_: Exception) {
            null
        }
    }

    private fun RtmpClient.reflectCommandsManager(): CommandsManager? {
        return try {
            val f = RtmpClient::class.java.getDeclaredField("commandsManager")
            f.isAccessible = true
            f.get(this) as? CommandsManager
        } catch (_: Exception) {
            null
        }
    }

    private fun CommandsManager.reflectWriteMutex(): Mutex? {
        return try {
            val f = CommandsManager::class.java.getDeclaredField("writeSync")
            f.isAccessible = true
            f.get(this) as? Mutex
        } catch (_: Exception) {
            null
        }
    }

    /**
     * @param props Values must be String, Double, Boolean, or null (omitted).
     */
    suspend fun sendSetDataFrame(
        rtmpClient: RtmpClient,
        eventName: String,
        props: Map<String, Any?>,
    ): Boolean = withContext(Dispatchers.IO) {
        try {
            val cm = rtmpClient.reflectCommandsManager() ?: return@withContext false
            val socket = rtmpClient.reflectSocket() ?: return@withContext false
            val mutex = cm.reflectWriteMutex() ?: return@withContext false
            val streamIdField = CommandsManager::class.java.getDeclaredField("streamId")
            streamIdField.isAccessible = true
            val streamId = streamIdField.getInt(cm)
            val ts = TimeUtils.getCurrentTimeMillis().toInt()
            val ecma = AmfEcmaArray()
            for ((k, v) in props) {
                if (v == null) continue
                when (v) {
                    is String -> ecma.setProperty(k, v)
                    is Double -> ecma.setProperty(k, v)
                    is Float -> ecma.setProperty(k, v.toDouble())
                    is Int -> ecma.setProperty(k, v.toDouble())
                    is Long -> ecma.setProperty(k, v.toDouble())
                    is Boolean -> ecma.setProperty(k, v)
                    else -> ecma.setProperty(k, v.toString())
                }
            }
            mutex.withLock {
                val data = DataAmf0("@setDataFrame", ts, streamId)
                data.addData(AmfString(eventName))
                data.addData(ecma)
                data.writeHeader(socket)
                data.writeBody(socket)
                socket.flush()
            }
            true
        } catch (e: Exception) {
            Log.e(TAG, "sendSetDataFrame $eventName", e)
            false
        }
    }
}
