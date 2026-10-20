package com.khushi.conduit.notifications

import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import com.khushi.conduit.core.protocol.PhoneNotification
import com.khushi.conduit.link.LinkHub
import com.khushi.conduit.link.LinkService

/**
 * Sends this phone's notifications to the linked Mac — Shared/Protocol
 * README.md §6, `notification.posted`.
 *
 * Android only runs this service once the person has allowed Conduit under
 * notification access, and it decides here what may leave the phone at all:
 * nothing ongoing, no group summaries, nothing from an app switched off, and
 * nothing an app marked secret. A private one travels without its contents.
 *
 * Nothing is written down. Notifications live in the system's own list and
 * in whatever the Mac is showing; Conduit keeps no copy and logs no text.
 */
class NotificationRelay : NotificationListenerService() {

    override fun onListenerConnected() {
        instance = this
        LinkHub.update { it.copy(notificationsOn = true) }
        LinkService.refreshFeatures()
        Log.i(TAG, "notification access granted")
        // The Mac may already be linked and waiting.
        active().forEach(LinkService::notificationPosted)
    }

    override fun onListenerDisconnected() {
        instance = null
        LinkHub.update { it.copy(notificationsOn = false) }
        LinkService.refreshFeatures()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        relayed(sbn)?.let(LinkService::notificationPosted)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        // A key the Mac never saw is one it ignores.
        LinkService.notificationRemoved(sbn.key)
    }

    /** What is showing right now, for a Mac that has just linked. */
    private fun active(): List<PhoneNotification> =
        runCatching { activeNotifications.orEmpty().mapNotNull(::relayed) }.getOrDefault(emptyList())

    /** The notification as the Mac may see it, or null if it must not leave. */
    private fun relayed(sbn: StatusBarNotification): PhoneNotification? {
        if (sbn.packageName == packageName) return null
        val notification = sbn.notification ?: return null
        val flags = notification.flags
        if (flags and Notification.FLAG_ONGOING_EVENT != 0) return null
        if (flags and Notification.FLAG_GROUP_SUMMARY != 0) return null
        if (notification.visibility == Notification.VISIBILITY_SECRET) return null
        if (!NotificationApps.allowed(this, sbn.packageName)) return null

        val label = appName(sbn.packageName)
        NotificationApps.remember(this, sbn.packageName, label)

        val private = notification.visibility == Notification.VISIBILITY_PRIVATE
        return PhoneNotification(
            key = sbn.key,
            appID = sbn.packageName,
            appName = label,
            title = if (private) null else notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString(),
            text = if (private) null else notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString(),
            postedAt = sbn.postTime,
            clearable = sbn.isClearable,
            redacted = private,
        )
    }

    private fun appName(packageName: String): String = runCatching {
        packageManager.getApplicationLabel(packageManager.getApplicationInfo(packageName, 0)).toString()
    }.getOrDefault(packageName)

    companion object {
        private const val TAG = "ConduitNotifications"

        @Volatile
        private var instance: NotificationRelay? = null

        /** Whether Android is handing Conduit notifications right now. */
        fun isListening(context: Context): Boolean {
            if (instance != null) return true
            // The service starts when Android feels like it; the setting is
            // the truth before then.
            val allowed = runCatching {
                Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
            }.getOrNull().orEmpty()
            return allowed.split(':').any { it.substringBefore('/') == context.packageName }
        }

        /** What is showing on the phone now, for `notification.sync`. */
        fun showing(): List<PhoneNotification> = instance?.active().orEmpty()

        /** Dismiss it on the phone, as swiping it away would. */
        fun dismiss(key: String): Boolean {
            val service = instance ?: return false
            return runCatching { service.cancelNotification(key) }.isSuccess
        }

        /**
         * Open what the notification points at. Android may refuse to bring
         * an app forward from the background, so this says only that the
         * phone tried.
         */
        fun open(key: String): Boolean {
            val service = instance ?: return false
            val sbn = runCatching { service.activeNotifications.orEmpty().firstOrNull { it.key == key } }.getOrNull()
                ?: return false
            val intent = sbn.notification?.contentIntent ?: return false
            return runCatching {
                intent.send()
                service.cancelNotification(key)
            }.isSuccess
        }

        /** Package names Android needs to name the app in its own settings. */
        fun label(context: Context, packageName: String): String = runCatching {
            val manager: PackageManager = context.packageManager
            manager.getApplicationLabel(manager.getApplicationInfo(packageName, 0)).toString()
        }.getOrDefault(packageName)
    }
}
