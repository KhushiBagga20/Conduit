package com.khushi.conduit.link

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.IntentCompat
import com.khushi.conduit.core.link.LinkSharing

/**
 * "Send to Mac" in the share sheet. Photos, videos and other files go to the
 * Mac's folder for this phone's files; a web link opens on the Mac; any other
 * text lands on the Mac's clipboard, ready to paste — the way to send this
 * phone's clipboard, since Android lets no app read it in the background.
 * It has no screen of its own, and it keeps nothing.
 */
class ShareToMacActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        val files = intent?.let(::sharedFiles).orEmpty()
        val shared = intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val link = shared?.let(LinkSharing::firstLink)
        when {
            LinkedMacs(this).all().isEmpty() -> toast("Link a Mac in Conduit first.")
            files.isNotEmpty() -> LinkService.sendFiles(this, files)
            shared.isNullOrBlank() -> toast("There's nothing in what you shared that Conduit can send.")
            link != null -> LinkService.sendLink(this, link)
            else -> LinkService.sendClipboard(this, shared, sensitive = false)
        }
        finish()
    }

    /** One file or several, from EXTRA_STREAM. */
    private fun sharedFiles(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
        Intent.ACTION_SEND_MULTIPLE ->
            IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        else -> emptyList()
    }

    private fun toast(text: String) = Toast.makeText(applicationContext, text, Toast.LENGTH_LONG).show()
}
