package com.khushi.conduit.link

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.khushi.conduit.core.protocol.ActionName
import com.khushi.conduit.core.protocol.FileChunk
import com.khushi.conduit.core.protocol.Outcome
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException
import java.io.InputStream
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/**
 * Sends files from this phone to the linked Mac over Conduit Link: one at a
 * time, each offered with `file.offer`, streamed in 256 KiB pieces on the file
 * channel, and finished with its SHA-256, which the Mac checks before it keeps
 * the file (spec §6 Files, §7).
 *
 * It runs on a thread of its own, because reading files and waiting for the
 * Mac both block. The log says how many files went and how large they were,
 * never what they were called.
 */
internal class FileSender(
    private val context: Context,
    /** Send a command and wait for its answer; null if none came in time. */
    private val askAndWait: (LinkConnection, String, JsonObject, Long) -> Outcome?,
    /** Tell the Mac something without waiting for its answer. */
    private val tell: (LinkConnection, String, JsonObject) -> Unit,
    private val progress: (Progress) -> Unit,
) {

    sealed interface Progress {
        data class Sending(val macName: String, val file: Int, val files: Int, val fraction: Float) : Progress
        data class Done(val macName: String, val sent: Int, val failure: String?) : Progress
    }

    private class Outgoing(val uri: Uri, val name: String, val size: Long, val type: String?)

    private val thread = Executors.newSingleThreadExecutor { Thread(it, "conduit-files") }
    private val nextId = AtomicInteger(1)
    /** The person stopped the files being sent. */
    @Volatile private var cancelled = false
    /** The Mac gave up on this transfer, and said so. */
    @Volatile private var stoppedByMac = 0

    fun send(connection: LinkConnection, macName: String, uris: List<Uri>) {
        thread.execute { sendBatch(connection, macName, uris) }
    }

    fun cancel() {
        cancelled = true
    }

    fun stoppedByMac(transferId: Int) {
        stoppedByMac = transferId
    }

    fun shutdown() {
        cancelled = true
        thread.shutdown()
    }

    private fun sendBatch(connection: LinkConnection, macName: String, uris: List<Uri>) {
        cancelled = false
        val files = uris.mapNotNull(::describe)
        val total = files.sumOf { it.size }.coerceAtLeast(1)
        var done = 0L
        var sent = 0
        var failure: String? = if (files.size < uris.size) "Conduit couldn't read some of them." else null
        var lastReport = 0L

        for ((index, file) in files.withIndex()) {
            val problem = sendOne(connection, file, index, files.size) { moved ->
                val now = System.currentTimeMillis()
                if (now - lastReport >= REPORT_MILLIS) {
                    lastReport = now
                    progress(Progress.Sending(macName, index + 1, files.size, (done + moved).toFloat() / total))
                }
            }
            if (problem != null) {
                failure = problem
                break
            }
            sent++
            done += file.size
        }
        Log.i(TAG, "sent $sent of ${uris.size} files to the Mac, $done bytes")
        progress(Progress.Done(macName, sent, failure))
    }

    /** Null when the Mac has the file; otherwise what went wrong, in words for the person. */
    private fun sendOne(connection: LinkConnection, file: Outgoing, index: Int, count: Int, moved: (Long) -> Unit): String? {
        val id = nextId.getAndIncrement()
        val offer = buildJsonObject {
            put("transferID", id)
            put("name", file.name)
            put("size", file.size)
            put("index", index)
            put("count", count)
            file.type?.let { put("type", it) }
        }
        when (val answer = askAndWait(connection, ActionName.FILE_OFFER, offer, ANSWER_MILLIS)) {
            null -> return "Your Mac didn't answer."
            is Outcome.Failure -> return answer.error.message
            Outcome.Success -> Unit
        }

        val digest = MessageDigest.getInstance("SHA-256")
        var offset = 0L
        val stopped = try {
            val input = context.contentResolver.openInputStream(file.uri)
                ?: return stop(connection, id, "Conduit couldn't open a file.")
            input.use {
                val buffer = ByteArray(CHUNK_SIZE)
                while (true) {
                    if (cancelled) return@use "Stopped."
                    if (stoppedByMac == id) return "Your Mac stopped taking the file."
                    val read = readUpTo(it, buffer)
                    if (read <= 0) break
                    digest.update(buffer, 0, read)
                    if (!connection.sendBlocking(FileChunk.frame(id, offset, buffer, read))) {
                        return "The connection to your Mac was lost."
                    }
                    offset += read
                    moved(offset)
                }
                null
            }
        } catch (_: IOException) {
            "Conduit couldn't read a file."
        } catch (_: SecurityException) {
            "Conduit isn't allowed to read that file any more."
        }
        if (stopped != null) return stop(connection, id, stopped)
        if (offset != file.size) return stop(connection, id, "A file changed while it was being sent.")

        val finish = buildJsonObject {
            put("transferID", id)
            put("sha256", digest.digest().joinToString("") { "%02x".format(it) })
        }
        return when (val answer = askAndWait(connection, ActionName.FILE_FINISH, finish, FINISH_MILLIS)) {
            null -> "Your Mac didn't say whether it got the file."
            is Outcome.Failure -> answer.error.message
            Outcome.Success -> null
        }
    }

    /** Tell the Mac to throw away what it has of the file, and say why it stopped. */
    private fun stop(connection: LinkConnection, id: Int, reason: String): String {
        if (connection.isOpen) tell(connection, ActionName.FILE_CANCEL, buildJsonObject { put("transferID", id) })
        return reason
    }

    /** What the Mac needs before the bytes: a name and an exact size. */
    private fun describe(uri: Uri): Outgoing? {
        val resolver = context.contentResolver
        var name: String? = null
        var size: Long? = null
        runCatching {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    name = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let(cursor::getString)
                    size = cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }
                        ?.let(cursor::getLong)
                }
            }
        }
        if (size == null || size!! < 0) {
            size = runCatching { resolver.openAssetFileDescriptor(uri, "r")?.use { it.length } }.getOrNull()
                ?.takeIf { it >= 0 }
        }
        val known = size ?: return null.also { Log.i(TAG, "skipped a file whose size Android didn't know") }
        return Outgoing(uri, name ?: uri.lastPathSegment ?: "File", known, resolver.getType(uri))
    }

    /** Fill as much of [buffer] as the stream allows; fewer only at the end. */
    private fun readUpTo(input: InputStream, buffer: ByteArray): Int {
        var filled = 0
        while (filled < buffer.size) {
            val read = input.read(buffer, filled, buffer.size - filled)
            if (read < 0) break
            filled += read
        }
        return filled
    }

    private companion object {
        const val TAG = "ConduitFiles"
        const val CHUNK_SIZE = 256 * 1024
        const val ANSWER_MILLIS = 15_000L
        /** The Mac hashes as it writes, so finishing is quick; this allows for a slow disk. */
        const val FINISH_MILLIS = 60_000L
        const val REPORT_MILLIS = 400L
    }
}
