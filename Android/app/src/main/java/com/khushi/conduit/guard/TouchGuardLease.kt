package com.khushi.conduit.guard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock

/**
 * The lease that keeps [TouchGuardService] running. Conduit for Mac renews it
 * while the phone's screen is off:
 *
 *     am broadcast -f 32 -n com.khushi.conduit/.guard.TouchGuardLease --el for_ms 60000
 *
 * When renewals stop — the Mac quit, slept or lost the phone — the lease runs
 * out and the guard turns itself off. `for_ms 0` ends it at once.
 *
 * Only senders holding WRITE_SECURE_SETTINGS, such as the adb shell, can
 * deliver it (see the manifest). The result data tells the Mac where things
 * stand: `guarding`, `armed`, `released` or `unsupported`.
 *
 * The lease lives in memory on purpose: after a restart or reboot there is
 * none, so a guard that is still switched on in settings stands down at once.
 */
class TouchGuardLease : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val duration = intent.getLongExtra(EXTRA_FOR_MS, 0L).coerceIn(0L, MAX_LEASE_MS)
        leaseEndsAt = if (duration > 0) SystemClock.elapsedRealtime() + duration else 0L
        if (duration == 0L) TouchGuardService.release()

        resultData = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU -> "unsupported"
            TouchGuardService.isGuarding -> "guarding"
            duration > 0 -> "armed"
            else -> "released"
        }
    }

    companion object {
        const val EXTRA_FOR_MS = "for_ms"

        /** The Mac renews every 20 seconds; a lease never outlives a few missed renewals. */
        private const val MAX_LEASE_MS = 120_000L

        @Volatile
        private var leaseEndsAt = 0L

        fun isActive(): Boolean = leaseEndsAt > SystemClock.elapsedRealtime()
    }
}
