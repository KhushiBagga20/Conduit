package com.khushi.conduit.link

import android.app.Activity
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.Build
import android.widget.Toast

/**
 * Sends this phone's clipboard to the linked Mac, from the Quick Settings
 * tile. Android lets an app read the clipboard only while one of its
 * windows has focus, so this invisible screen takes focus for a moment,
 * reads once, hands the text to [LinkService], and goes. It keeps nothing.
 */
class SendClipboardActivity : Activity() {

    private var sent = false

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || sent) return
        sent = true

        val clip = getSystemService(ClipboardManager::class.java)?.primaryClip
        val text = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(this)?.toString()
        // A clip a password manager marked sensitive still goes — the person
        // asked for it — but the Mac is told, so its clipboard managers skip it.
        val sensitive = Build.VERSION.SDK_INT >= 33 &&
            clip?.description?.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true

        when {
            LinkedMacs(this).all().isEmpty() -> toast("Link a Mac in Conduit first.")
            text.isNullOrEmpty() -> toast("The clipboard is empty.")
            else -> LinkService.sendClipboard(this, text, sensitive)
        }
        finish()
    }

    private fun toast(text: String) = Toast.makeText(applicationContext, text, Toast.LENGTH_SHORT).show()
}
