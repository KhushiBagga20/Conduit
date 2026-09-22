package com.khushi.conduit.link

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import com.khushi.conduit.core.link.LinkSharing

/**
 * "Send to Mac" in the share sheet: hands the web link in whatever was
 * shared to [LinkService], which sends it to the linked Mac to open. It has
 * no screen of its own, and it keeps nothing.
 */
class ShareToMacActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val shared = intent?.takeIf { it.action == Intent.ACTION_SEND }
            ?.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val link = shared?.let(LinkSharing::firstLink)
        when {
            link == null -> toast("Conduit sends web links, and there isn't one in what you shared.")
            LinkedMacs(this).all().isEmpty() -> toast("Link a Mac in Conduit first.")
            else -> LinkService.sendLink(this, link)
        }
        finish()
    }

    private fun toast(text: String) = Toast.makeText(applicationContext, text, Toast.LENGTH_LONG).show()
}
