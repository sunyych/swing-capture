package com.lumiaiq.MotionCapture

import com.pedro.common.ConnectChecker

/**
 * Forwards RootEncoder connection lifecycle to Flutter [EventChannel] as [rtmp_state].
 */
internal class RtmpConnectChecker(
    private val emit: (Map<String, Any?>) -> Unit,
) : ConnectChecker {
    override fun onConnectionStarted(url: String) {
        emit(
            mapOf(
                "type" to "rtmp_state",
                "state" to "connecting",
                "message" to url,
            ),
        )
    }

    override fun onConnectionSuccess() {
        emit(
            mapOf(
                "type" to "rtmp_state",
                "state" to "live",
            ),
        )
    }

    override fun onConnectionFailed(reason: String) {
        emit(
            mapOf(
                "type" to "rtmp_state",
                "state" to "error",
                "message" to reason,
            ),
        )
    }

    override fun onDisconnect() {
        emit(
            mapOf(
                "type" to "rtmp_state",
                "state" to "stopped",
            ),
        )
    }

    override fun onAuthError() {
        emit(
            mapOf(
                "type" to "rtmp_state",
                "state" to "error",
                "message" to "RTMP auth error",
            ),
        )
    }

    override fun onAuthSuccess() = Unit
}
