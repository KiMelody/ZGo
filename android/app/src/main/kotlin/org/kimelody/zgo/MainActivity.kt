package org.kimelody.zgo

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        engine = flutterEngine
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KEEP_ALIVE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> result.success(
                        KeepAliveService.start(
                            this,
                            call.argument<String>("title").orEmpty(),
                            call.argument<String>("body").orEmpty(),
                            call.argument<String>("channelName").orEmpty()
                        )
                    )

                    "stop" -> result.success(KeepAliveService.stop(this))
                    "isRunning" -> result.success(KeepAliveService.isRunning)
                    else -> result.notImplemented()
                }
            }
        // Quota-watch notice surface (QuotaWatchNotifier) + the reset tap
        // hand-off. "resetPressed" replies true once Dart handled the tap,
        // which clears the pending flag; a dead engine leaves it set for
        // the next boot's takePendingReset pull.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, QUOTA_WATCH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "update" -> {
                        val data = parsePayload(call.argument<String>("data"))
                        if (data == null) {
                            result.error("bad_payload", "unreadable quota payload", null)
                        } else {
                            QuotaWatchNotifier.update(this, data)
                            result.success(true)
                        }
                    }

                    "cancel" -> {
                        QuotaWatchNotifier.cancel(this)
                        result.success(true)
                    }

                    "takePendingReset" -> result.success(
                        pendingReset.also { pendingReset = false }
                    )

                    else -> result.notImplemented()
                }
            }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keep the latest deep-link intent so app_links / home_widget see it.
        setIntent(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        engine = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun parsePayload(raw: String?): JSONObject? {
        if (raw.isNullOrEmpty()) return null
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }

    // Internal, not private: QuotaWatchActionReceiver pokes pushRefresh /
    // pushResetFromNotice.
    internal companion object {
        const val KEEP_ALIVE_CHANNEL = "zgo/keepalive"
        const val QUOTA_WATCH_CHANNEL = "zgo/quota_watch"

        /** One process, one engine/activity — plain statics are the state. */
        var engine: FlutterEngine? = null
        var pendingReset = false

        /**
         * The quota notice's refresh broadcast: push `refreshPressed` to a
         * live engine; with no engine this is a no-op (the next app open
         * re-polls through the resumed lifecycle), so nothing is held.
         */
        fun pushRefresh() {
            val current = engine ?: return
            MethodChannel(
                current.dartExecutor.binaryMessenger,
                QUOTA_WATCH_CHANNEL
            ).invokeMethod("refreshPressed", null)
        }

        /**
         * The quota notice's reset broadcast: "resetPressed" replies true
         * once Dart handled the tap, which clears the pending flag; a dead
         * engine leaves it set for the next boot's takePendingReset pull.
         */
        fun pushResetFromNotice() {
            pendingReset = true
            val current = engine ?: return
            MethodChannel(
                current.dartExecutor.binaryMessenger,
                QUOTA_WATCH_CHANNEL
            ).invokeMethod(
                "resetPressed",
                null,
                object : MethodChannel.Result {
                    override fun success(result: Any?) {
                        if (result == true) pendingReset = false
                    }

                    override fun error(
                        errorCode: String,
                        errorMessage: String?,
                        errorDetails: Any?
                    ) {
                    }

                    override fun notImplemented() {}
                }
            )
        }
    }
}
