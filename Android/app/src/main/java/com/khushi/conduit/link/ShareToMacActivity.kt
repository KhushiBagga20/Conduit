package com.khushi.conduit.link

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.khushi.conduit.core.link.LinkSharing

/**
 * "Send to Mac" in the share sheet. A web link opens on the Mac; any other
 * text lands on the Mac's clipboard, ready to paste — the way to send this
 * phone's clipboard, since Android lets no app read it in the background.
 * It has no screen of its own, and it keeps nothing.
 */
class ShareToMacActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val link = shared?.let(LinkSharing::firstLink)
        when {
            shared.isNullOrBlank() -> toast("There's no text in what you shared.")
            LinkedMacs(this).all().isEmpty() -> toast("Link a Mac in Conduit first.")
            link != null -> LinkService.sendLink(this, link)
            else -> LinkService.sendClipboard(this, shared, sensitive = false)
        }
        finish()
    }

    private fun toast(text: String) = Toast.makeText(applicationContext, text, Toast.LENGTH_LONG).show()
}
