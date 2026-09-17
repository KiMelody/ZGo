package org.songsong.zlinker

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Keep the latest deep-link intent so app_links / home_widget see it.
        setIntent(intent)
    }

    private companion object {
        const val KEEP_ALIVE_CHANNEL = "zlinker/keepalive"
    }
}
