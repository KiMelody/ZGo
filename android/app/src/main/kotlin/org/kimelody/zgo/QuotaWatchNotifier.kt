package org.kimelody.zgo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject

/**
 * Builds and posts the persistent quota-watch notice: a custom RemoteViews
 * (ring percentage + same-row action — the system template can draw
 * neither), fed by the Dart presenter over the `zgo/quota_watch`
 * channel. It knows no copy: every string arrives pre-localized in the
 * payload, and colors come from the resources so the system light/dark
 * theme is honored.
 *
 * The notice id is independent of KeepAliveService's (id=1). The
 * `zgo_quota` channel itself is created by the Dart notification
 * plugin (localized name); a bare fallback here only covers a missing
 * registration. Payload shape (all fields optional unless noted):
 * `ring {progress, warn}` (null → no ring) · `pct` · `title` (required) ·
 * `sub` · `button` · `buttonWarn` · `expanded [line, line]` (big view).
 */
object QuotaWatchNotifier {
    const val CHANNEL_ID = "zgo_quota"
    const val NOTIFICATION_ID = 2

    fun update(context: Context, data: JSONObject) {
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(context, manager)
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setCustomContentView(views(context, data, expanded = false))
            .setCustomBigContentView(views(context, data, expanded = true))
            .setContentIntent(openAppIntent(context))
            .setOngoing(true)
            // The channel owns alerting for the one-shots; the persistent
            // notice must not re-alert on every poll refresh.
            .setOnlyAlertOnce(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    fun cancel(context: Context) {
        val manager =
            context.getSystemService(NotificationManager::class.java) ?: return
        manager.cancel(NOTIFICATION_ID)
    }

    private fun ensureChannel(context: Context, manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "ZGo",
                NotificationManager.IMPORTANCE_DEFAULT
            )
        )
    }

    private fun openAppIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            2002,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /**
     * The inline reset button taps a broadcast (same shape as the refresh
     * icon): QuotaWatchActionReceiver holds the pending flag for a dead
     * engine (the next app open pulls it via takePendingReset) and pushes
     * `resetPressed` to a live one, which runs the direct reset while the
     * process stays in place.
     */
    private fun resetIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            2001,
            Intent(context, QuotaWatchActionReceiver::class.java).apply {
                action = QuotaWatchActionReceiver.ACTION_RESET
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /**
     * The manual-refresh icon taps a broadcast, not an activity: the shade
     * stays open and the app is not opened. QuotaWatchActionReceiver
     * pushes `refreshPressed` to a live engine; a dead engine is served by
     * the next app open (resumed lifecycle re-polls), so unlike the reset
     * no pending flag needs to hold the tap.
     */
    private fun refreshIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            2003,
            Intent(context, QuotaWatchActionReceiver::class.java).apply {
                action = QuotaWatchActionReceiver.ACTION_REFRESH
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    /**
     * optString returns the literal "null" for JSON null (JSONObject.NULL),
     * so nullable payload fields go through this instead.
     */
    private fun text(data: JSONObject, key: String): String {
        val v = data.opt(key)
        return if (v == null || v == JSONObject.NULL) "" else v.toString()
    }

    private fun views(
        context: Context,
        data: JSONObject,
        expanded: Boolean
    ): RemoteViews {
        val v = RemoteViews(
            context.packageName,
            R.layout.zgo_quota_notification
        )

        val ring = data.optJSONObject("ring")
        if (ring == null) {
            v.setViewVisibility(R.id.quota_ring_box, View.GONE)
        } else {
            v.setViewVisibility(R.id.quota_ring_box, View.VISIBLE)
            v.setProgressBar(
                R.id.quota_ring,
                100,
                ring.optInt("progress", 0),
                false
            )
            // setColorStateList is the API 31+ reflection action; RemoteViews
            // has no direct setProgressTintList.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val warn = ring.optBoolean("warn")
                v.setColorStateList(
                    R.id.quota_ring,
                    "setProgressTintList",
                    ColorStateList.valueOf(
                        ContextCompat.getColor(
                            context,
                            if (warn) R.color.quota_warn
                            else R.color.quota_accent
                        )
                    )
                )
            }
            v.setTextViewText(R.id.quota_ring_pct, text(data, "pct"))
            v.setTextColor(
                R.id.quota_ring_pct,
                ContextCompat.getColor(context, R.color.quota_text_primary)
            )
        }

        val warnTitle =
            ring != null && ring.optBoolean("warn")
        v.setTextViewText(R.id.quota_title, text(data, "title"))
        v.setTextColor(
            R.id.quota_title,
            ContextCompat.getColor(
                context,
                if (warnTitle) R.color.quota_warn
                else R.color.quota_text_primary
            )
        )

        val sub = text(data, "sub")
        if (sub.isEmpty()) {
            v.setViewVisibility(R.id.quota_sub, View.GONE)
        } else {
            v.setViewVisibility(R.id.quota_sub, View.VISIBLE)
            v.setTextViewText(R.id.quota_sub, sub)
            v.setTextColor(
                R.id.quota_sub,
                ContextCompat.getColor(context, R.color.quota_text_muted)
            )
        }

        val button = text(data, "button")
        if (button.isEmpty()) {
            v.setViewVisibility(R.id.quota_action, View.GONE)
        } else {
            val warn = data.optBoolean("buttonWarn")
            v.setViewVisibility(R.id.quota_action, View.VISIBLE)
            v.setTextViewText(R.id.quota_action, button)
            v.setTextColor(
                R.id.quota_action,
                ContextCompat.getColor(
                    context,
                    if (warn) R.color.quota_warn else R.color.quota_accent
                )
            )
            v.setInt(
                R.id.quota_action,
                "setBackgroundResource",
                if (warn) R.drawable.zgo_quota_pill_warn
                else R.drawable.zgo_quota_pill
            )
            v.setOnClickPendingIntent(R.id.quota_action, resetIntent(context))
        }

        // Always visible (any phase can go stale) → unconditional bind.
        v.setOnClickPendingIntent(R.id.quota_refresh, refreshIntent(context))

        val lines: JSONArray? = data.optJSONArray("expanded")
        if (expanded && lines != null && lines.length() > 0) {
            v.setViewVisibility(R.id.quota_detail_box, View.VISIBLE)
            for (i in 0 until lines.length()) {
                val id = if (i == 0) R.id.quota_detail_1
                else R.id.quota_detail_2
                v.setViewVisibility(id, View.VISIBLE)
                v.setTextViewText(id, lines.optString(i))
                v.setTextColor(
                    id,
                    ContextCompat.getColor(
                        context,
                        R.color.quota_text_secondary
                    )
                )
            }
            if (lines.length() < 2) {
                v.setViewVisibility(R.id.quota_detail_2, View.GONE)
            }
        } else {
            v.setViewVisibility(R.id.quota_detail_box, View.GONE)
        }
        return v
    }
}
