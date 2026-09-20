package org.songsong.zlinker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * The quota notice's two inline buttons (refresh icon, reset pill) tap
 * broadcasts, not activities: the shade stays open and the app is never
 * yanked to the foreground (that is the activity-pending-intent behavior
 * the user rejected). Never starts an activity (Android 12+ trampoline
 * ban). A dead engine is served by the next app open — the resumed
 * lifecycle re-polls (refresh), the takePendingReset pull serves the
 * held reset.
 */
class QuotaWatchActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_REFRESH -> MainActivity.pushRefresh()
            ACTION_RESET -> MainActivity.pushResetFromNotice()
        }
    }

    companion object {
        const val ACTION_REFRESH = "org.songsong.zlinker.QUOTA_REFRESH"
        const val ACTION_RESET = "org.songsong.zlinker.QUOTA_RESET"
    }
}
