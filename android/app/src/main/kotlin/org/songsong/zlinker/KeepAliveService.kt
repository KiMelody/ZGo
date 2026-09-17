package org.songsong.zlinker

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject

/**
 * Foreground service behind the "keep receiving notifications in the
 * background" toggle: it holds a foreground slot so the process is not
 * frozen, letting the relay WebSocket and the notification hub timers keep
 * running. It knows nothing about the protocol or about notifications — the
 * persistent notice is only the price of the foreground slot.
 *
 * The notice copy is localized on the Dart side and cached here, so a
 * START_STICKY restart (process killed, intent == null) rebuilds it without
 * a second translation table. Importance is OEM-adaptive: aggressive
 * manufacturers need a *visible* notice to spare the process, everyone else
 * gets a silent one with no status-bar icon.
 */
class KeepAliveService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val fromIntent = copyFrom(intent)
        if (fromIntent != null) writeCopy(fromIntent)
        // Never skip the promotion: a startForegroundService() that does not
        // promote itself within a few seconds gets the app killed.
        promote(buildNotification(fromIntent ?: readCopy() ?: fallbackCopy()))
        running = true
        return START_STICKY
    }

    override fun onDestroy() {
        running = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    /**
     * Promotes to foreground with one explicit type: 14+ uses specialUse only,
     * so the dataSync allowances (Android 15 caps dataSync at 6h/day) never
     * apply. Below 14 the typed overload does not exist — 10+ takes dataSync,
     * older versions take the untyped call.
     */
    private fun promote(notification: Notification) {
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE -> startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )

            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )

            else -> startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(copy: Copy): Notification {
        ensureChannel(copy.channelName)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(copy.title)
            .setContentText(copy.body)
            .setOngoing(true)
            .setContentIntent(openAppIntent())
            // Ignored on 26+ (the channel owns importance); keeps pre-26
            // devices at the same visibility as the channel below.
            .setPriority(
                if (oemVisible) NotificationCompat.PRIORITY_DEFAULT
                else NotificationCompat.PRIORITY_MIN
            )
            .build()
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        this,
        0,
        Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        },
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
    )

    /**
     * Created once and never updated: channel importance is frozen at
     * creation time, so the OEM verdict (and the channel name) is fixed for
     * the install — same accepted limitation as the task channels.
     */
    private fun ensureChannel(channelName: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            channelName,
            if (oemVisible) NotificationManager.IMPORTANCE_DEFAULT
            else NotificationManager.IMPORTANCE_MIN
        )
        channel.setSound(null, null)
        channel.enableVibration(false)
        manager.createNotificationChannel(channel)
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readCopy(): Copy? {
        val raw = prefs().getString(KEY_COPY, null) ?: return null
        return try {
            val json = JSONObject(raw)
            Copy(
                title = json.optString("title", FALLBACK_COPY),
                body = json.optString("body"),
                channelName = json.optString("channelName", FALLBACK_COPY)
            )
        } catch (e: Exception) {
            Log.w(TAG, "unreadable notification copy", e)
            null
        }
    }

    private fun writeCopy(copy: Copy) {
        val json = JSONObject()
            .put("title", copy.title)
            .put("body", copy.body)
            .put("channelName", copy.channelName)
        // commit(), not apply(): surviving a process kill is the reason this
        // cache exists, and this runs once per service start.
        prefs().edit().putString(KEY_COPY, json.toString()).commit()
    }

    /** Copy carried by [start]; null when the intent has no extras (STICKY). */
    private fun copyFrom(intent: Intent?): Copy? {
        if (intent == null) return null
        val title = intent.getStringExtra(EXTRA_TITLE).orEmpty()
        val body = intent.getStringExtra(EXTRA_BODY).orEmpty()
        val channelName = intent.getStringExtra(EXTRA_CHANNEL_NAME).orEmpty()
        if (title.isEmpty() && body.isEmpty() && channelName.isEmpty()) return null
        return Copy(
            title = title.ifEmpty { FALLBACK_COPY },
            body = body,
            channelName = channelName.ifEmpty { FALLBACK_COPY }
        )
    }

    private fun fallbackCopy() = Copy(FALLBACK_COPY, "", FALLBACK_COPY)

    private data class Copy(val title: String, val body: String, val channelName: String)

    companion object {
        private const val TAG = "ZLinkerKeepAlive"
        private const val CHANNEL_ID = "zlinker_keepalive"
        private const val NOTIFICATION_ID = 1
        private const val PREFS = "zlinker_keepalive_service"
        private const val KEY_COPY = "zlinker_keepalive_copy"
        private const val FALLBACK_COPY = "ZLinker"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_BODY = "body"
        private const val EXTRA_CHANNEL_NAME = "channelName"

        /**
         * Manufacturers that freeze background apps hardest — there the
         * notice must be visible (IMPORTANCE_DEFAULT) to buy survival.
         */
        private val AGGRESSIVE_MANUFACTURERS = setOf(
            "xiaomi", "redmi", "poco", "huawei", "honor", "oppo",
            "oneplus", "realme", "vivo", "iqoo", "meizu"
        )

        /** One process, one service — a plain boolean is the whole state. */
        private var running = false

        val isRunning: Boolean
            get() = running

        val oemVisible: Boolean
            get() = AGGRESSIVE_MANUFACTURERS.contains(Build.MANUFACTURER.orEmpty().lowercase())

        /**
         * Called from the method channel while the app is in the foreground
         * (settings toggle / app start), so the 12+ background-FGS-start
         * restriction does not apply.
         */
        fun start(context: Context, title: String, body: String, channelName: String): Boolean =
            try {
                val intent = Intent(context, KeepAliveService::class.java)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_BODY, body)
                    .putExtra(EXTRA_CHANNEL_NAME, channelName)
                ContextCompat.startForegroundService(context, intent)
                // Optimistic: the Dart side queries isRunning right after
                // start, but onCreate/onStartCommand still have to be
                // scheduled across processes, so onStartCommand's own
                // running = true always loses that race. Reporting "on" from
                // here is safe because the only two ways to diverge are
                // catches above (we never set it) and teardown, which
                // onDestroy/stop correct.
                running = true
                true
            } catch (e: Exception) {
                Log.w(TAG, "start failed", e)
                false
            }

        /** Stops the service; onDestroy removes the notice (no residue). */
        fun stop(context: Context): Boolean {
            running = false
            return context.stopService(Intent(context, KeepAliveService::class.java))
        }
    }
}
