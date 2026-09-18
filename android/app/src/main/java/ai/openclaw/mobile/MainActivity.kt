package ai.openclaw.mobile

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

class MainActivity : Activity() {
    private var client: GatewayClient? = null
    private lateinit var cache: TranscriptCache
    private lateinit var status: TextView
    private lateinit var sessionTitle: TextView
    private lateinit var transcript: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var input: EditText
    private lateinit var send: Button
    private lateinit var pause: Button
    private lateinit var attachmentStrip: LinearLayout

    private val messages = mutableListOf<ChatMessage>()
    private val sessions = mutableListOf<SessionSummary>()
    private val staged = mutableListOf<AttachmentDraft>()
    private var selectedSession = "main"
    private var streaming: ChatMessage? = null
    private var connectionState = ConnectionState.DISCONNECTED
    private var paused = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        selectedSession = intent.getStringExtra("session") ?: "main"
        val gateway = intent.getStringExtra("gateway") ?: "ws://127.0.0.1:18789"
        val token = intent.getStringExtra("token") ?: ""
        cache = TranscriptCache(this, gateway)
        buildUi()
        sessions += cache.loadSessions()
        messages += cache.loadMessages(selectedSession)
        renderTranscript()
        updateStatus(ConnectionState.DISCONNECTED, "Offline cache")
        client = GatewayClient(this, gateway, token) { event -> runOnUiThread { handleGateway(event) } }
        client!!.connect()
    }

    override fun onDestroy() {
        client?.close()
        super.onDestroy()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(12), dp(10), dp(12), dp(8))
            setBackgroundColor(Color.rgb(248, 248, 248))
        }
        val top = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        val sessionsButton = Button(this).apply {
            text = "Sessions"
            contentDescription = "Open sessions"
            setOnClickListener { showSessions() }
        }
        sessionTitle = TextView(this).apply {
            text = selectedSession
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            gravity = Gravity.CENTER
            setPadding(dp(8), 0, dp(8), 0)
        }
        status = TextView(this).apply {
            textSize = 12f
            gravity = Gravity.END
        }
        top.addView(sessionsButton)
        top.addView(sessionTitle, LinearLayout.LayoutParams(0, WRAP, 1f))
        top.addView(status)

        transcript = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, dp(10), 0, dp(12))
        }
        scroll = ScrollView(this).apply {
            isFillViewport = true
            addView(transcript)
        }
        attachmentStrip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            visibility = View.GONE
            setPadding(0, dp(4), 0, dp(4))
        }
        val composer = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
        }
        val attach = Button(this).apply {
            text = "＋"
            contentDescription = "Attach files"
            setOnClickListener { openFilePicker() }
        }
        input = EditText(this).apply {
            hint = "Message OpenClaw"
            minLines = 1
            maxLines = 6
            setPadding(dp(12), dp(8), dp(12), dp(8))
        }
        pause = Button(this).apply {
            text = "Pause"
            visibility = View.GONE
            contentDescription = "Pause current execution"
            setOnClickListener {
                client?.pauseOrStop()
                paused = true
                updateComposer()
            }
        }
        send = Button(this).apply {
            text = "Send"
            setOnClickListener { sendMessage() }
        }
        composer.addView(attach)
        composer.addView(input, LinearLayout.LayoutParams(0, WRAP, 1f))
        composer.addView(pause)
        composer.addView(send)
        root.addView(top)
        root.addView(scroll, LinearLayout.LayoutParams(MATCH, 0, 1f))
        root.addView(attachmentStrip)
        root.addView(composer)
        setContentView(root)
    }

    private fun handleGateway(event: JSONObject) {
        when (event.optString("type")) {
            "connection-state" -> {
                connectionState = when (event.optString("state")) {
                    "connecting" -> ConnectionState.CONNECTING
                    "connected" -> ConnectionState.CONNECTED
                    "reconnecting" -> ConnectionState.RECONNECTING
                    else -> ConnectionState.DISCONNECTED
                }
                updateStatus(connectionState, if (connectionState == ConnectionState.RECONNECTING) "Retrying…" else null)
                updateComposer()
            }
            "pairing-required" -> {
                connectionState = ConnectionState.PAIRING_REQUIRED
                val requestId = event.optString("requestId")
                updateStatus(connectionState, "Pair $requestId")
                AlertDialog.Builder(this)
                    .setTitle("Pairing required")
                    .setMessage("Approve this request on the Gateway host:\n\nopenclaw devices approve $requestId")
                    .setPositiveButton("OK", null)
                    .show()
            }
            "sessions-result" -> parseSessions(event.opt("payload"))
            "history-result" -> parseHistory(event.opt("payload"))
            "assistant-delta" -> appendAssistantDelta(event.optString("text"))
            "run-state" -> {
                val state = event.optString("state")
                if (state in listOf("end", "final", "done", "completed", "aborted", "error", "paused")) {
                    streaming?.streaming = false
                    streaming = null
                    paused = state == "paused" || state == "aborted"
                    cache.saveMessages(selectedSession, messages)
                } else {
                    paused = false
                }
                updateComposer()
                renderTranscript()
            }
            "local-error" -> updateStatus(ConnectionState.DISCONNECTED, event.optString("error"))
            "sequence-gap" -> updateStatus(ConnectionState.RECONNECTING, "Refreshing chat…")
        }
    }

    private fun parseSessions(payload: Any?) {
        val array = when (payload) {
            is JSONArray -> payload
            is JSONObject -> payload.optJSONArray("sessions") ?: payload.optJSONArray("items")
            else -> null
        } ?: return
        sessions.clear()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val key = item.optString("key", item.optString("sessionKey"))
            if (key.isBlank()) continue
            sessions += SessionSummary(
                key,
                item.optString("title", item.optString("name", key)),
                item.optLong("updatedAt", item.optLong("lastActivityAt"))
            )
        }
        cache.saveSessions(sessions)
    }

    private fun parseHistory(payload: Any?) {
        val array = when (payload) {
            is JSONArray -> payload
            is JSONObject -> payload.optJSONArray("messages") ?: payload.optJSONArray("items") ?: payload.optJSONArray("history")
            else -> null
        } ?: return
        val fresh = mutableListOf<ChatMessage>()
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val role = item.optString("role", item.optJSONObject("message")?.optString("role") ?: "")
            if (role !in listOf("user", "assistant", "system", "tool")) continue
            val text = extractMessageText(item)
            if (text.isBlank() && role != "tool") continue
            fresh += ChatMessage(
                item.optString("id", item.optString("messageId", "hist-$i")),
                role,
                text,
                extractAttachmentNames(item)
            )
        }
        if (fresh.isNotEmpty() || messages.isEmpty()) {
            messages.clear()
            messages += fresh
            streaming = null
            cache.saveMessages(selectedSession, messages)
            renderTranscript()
        }
    }

    private fun extractMessageText(item: JSONObject): String {
        listOf("text", "content", "message").forEach { key ->
            val value = item.opt(key)
            if (value is String) return value
        }
        item.optJSONObject("message")?.let { return extractMessageText(it) }
        val content = item.optJSONArray("content") ?: return ""
        val out = StringBuilder()
        for (i in 0 until content.length()) {
            val block = content.optJSONObject(i) ?: continue
            if (block.optString("type") in listOf("text", "output_text", "input_text")) out.append(block.optString("text"))
        }
        return out.toString()
    }

    private fun extractAttachmentNames(item: JSONObject): MutableList<String> {
        val out = mutableListOf<String>()
        val array = item.optJSONArray("attachments") ?: item.optJSONObject("message")?.optJSONArray("attachments") ?: return out
        for (i in 0 until array.length()) {
            val a = array.optJSONObject(i)
            out += a?.optString("fileName", a.optString("name", "attachment")) ?: "attachment"
        }
        return out
    }

    private fun appendAssistantDelta(delta: String) {
        if (delta.isBlank()) return
        var active = streaming
        if (active == null) {
            active = ChatMessage("stream-${UUID.randomUUID()}", "assistant", "", streaming = true)
            messages += active
            streaming = active
        }
        active.text = if (delta.startsWith(active.text) && delta.length > active.text.length) delta else active.text + delta
        renderTranscript()
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        cache.saveMessages(selectedSession, messages)
    }

    private fun sendMessage() {
        val text = input.text.toString().trim()
        if (text.isBlank() && staged.isEmpty()) return
        if (staged.isNotEmpty() && connectionState != ConnectionState.CONNECTED) {
            toast("Attachments require a live Gateway connection")
            return
        }
        messages += ChatMessage("local-${UUID.randomUUID()}", "user", text, staged.map { it.name }.toMutableList())
        cache.saveMessages(selectedSession, messages)
        renderTranscript()
        val outgoing = staged.toList()
        val estimatedPayload = text.toByteArray().size.toLong() + outgoing.sumOf { ((it.bytes.size.toLong() + 2L) / 3L) * 4L + it.name.length + it.mimeType.length + 96L }
        val payloadLimit = client?.maxPayloadBytes
        if (payloadLimit != null && estimatedPayload > payloadLimit) {
            toast("Message plus attachments exceed the Gateway payload limit")
            return
        }
        staged.clear()
        renderAttachments()
        input.text.clear()
        paused = false
        client?.sendChat(selectedSession, text, outgoing)
        updateComposer()
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun renderTranscript() {
        transcript.removeAllViews()
        messages.forEachIndexed { index, message -> transcript.addView(messageView(message, index)) }
        if (messages.isEmpty()) {
            transcript.addView(TextView(this).apply {
                text = "Start a conversation"
                gravity = Gravity.CENTER
                textSize = 18f
                setTextColor(Color.DKGRAY)
                setPadding(0, dp(80), 0, 0)
            })
        }
    }

    private fun messageView(message: ChatMessage, index: Int): View {
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = if (message.role == "user") Gravity.END else Gravity.START
            setPadding(0, dp(4), 0, dp(6))
        }
        val bubble = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(14), dp(10), dp(14), dp(10))
            background = rounded(if (message.role == "user") Color.rgb(225, 237, 255) else Color.WHITE)
        }
        message.attachments.forEach { name ->
            bubble.addView(TextView(this).apply {
                text = "📎 $name"
                textSize = 13f
                setTextColor(Color.DKGRAY)
            })
        }
        bubble.addView(TextView(this).apply {
            text = message.text.ifBlank { if (message.streaming) "…" else "" }
            textSize = 16f
            setTextColor(Color.BLACK)
            setTextIsSelectable(true)
        })
        outer.addView(bubble, LinearLayout.LayoutParams(if (message.role == "user") dp(320) else MATCH, WRAP))
        if (message.role == "assistant") {
            val actions = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.START
            }
            actions.addView(smallButton("Copy") { copy(message.text) })
            actions.addView(smallButton("Continue") { client?.sendChat(selectedSession, "Continue.") })
            actions.addView(smallButton("Retry") {
                val prior = messages.subList(0, index).lastOrNull { it.role == "user" }
                if (prior != null) client?.sendChat(selectedSession, prior.text)
            })
            outer.addView(actions)
        }
        return outer
    }

    private fun smallButton(label: String, onClick: () -> Unit) = Button(this).apply {
        text = label
        textSize = 11f
        minHeight = 0
        minimumHeight = 0
        setPadding(dp(8), 0, dp(8), 0)
        setOnClickListener { onClick() }
    }

    private fun showSessions() {
        if (sessions.isEmpty()) {
            toast("No sessions loaded yet")
            return
        }
        AlertDialog.Builder(this)
            .setTitle("Chats")
            .setItems(sessions.map { it.title }.toTypedArray()) { _, index -> switchSession(sessions[index]) }
            .setNegativeButton("Close", null)
            .show()
    }

    private fun switchSession(session: SessionSummary) {
        selectedSession = session.key
        sessionTitle.text = session.title
        messages.clear()
        messages += cache.loadMessages(session.key)
        streaming = null
        renderTranscript()
        client?.selectSession(session.key)
    }


    private fun openFilePicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            addCategory(Intent.CATEGORY_OPENABLE)
        }
        @Suppress("DEPRECATION")
        startActivityForResult(intent, PICK_FILES)
    }

    @Deprecated("Platform callback retained to avoid AndroidX activity-result runtime dependency")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES || resultCode != RESULT_OK || data == null) return
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) stageAttachment(clip.getItemAt(i).uri)
            return
        }
        data.data?.let { stageAttachment(it) }
    }

    private fun stageAttachment(uri: Uri) {
        try {
            val name = queryName(uri)
            val mime = contentResolver.getType(uri) ?: "application/octet-stream"
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return
            val limit = if (mime.startsWith("image/")) client?.maxImageBytes ?: client?.maxAttachmentBytes else client?.maxAttachmentBytes
            if (limit != null && bytes.size > limit) {
                toast("$name is larger than the Gateway attachment limit")
                return
            }
            staged += AttachmentDraft(name, mime, bytes)
            renderAttachments()
        } catch (t: Throwable) {
            toast("Could not attach file: ${t.message}")
        }
    }

    private fun renderAttachments() {
        attachmentStrip.removeAllViews()
        attachmentStrip.visibility = if (staged.isEmpty()) View.GONE else View.VISIBLE
        staged.toList().forEach { attachment ->
            attachmentStrip.addView(Button(this).apply {
                text = "📎 ${attachment.name}  ×"
                textSize = 12f
                setOnClickListener {
                    staged.remove(attachment)
                    renderAttachments()
                }
            })
        }
        updateComposer()
    }

    private fun queryName(uri: Uri): String {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return uri.lastPathSegment ?: "attachment"
    }

    private fun updateComposer() {
        val running = client?.activeRunId != null && !paused
        pause.visibility = if (running) View.VISIBLE else View.GONE
        send.visibility = View.VISIBLE
        send.isEnabled = connectionState == ConnectionState.CONNECTED
    }

    private fun updateStatus(state: ConnectionState, detail: String?) {
        connectionState = state
        status.text = when (state) {
            ConnectionState.CONNECTED -> "● Connected"
            ConnectionState.CONNECTING -> "○ Connecting"
            ConnectionState.RECONNECTING -> "◌ Reconnecting"
            ConnectionState.PAIRING_REQUIRED -> "Pairing required"
            ConnectionState.DISCONNECTED -> "Offline"
        } + (detail?.let { " · $it" } ?: "")
        status.setTextColor(if (state == ConnectionState.CONNECTED) Color.rgb(20, 120, 60) else Color.DKGRAY)
    }

    private fun copy(text: String) {
        (getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager)
            .setPrimaryClip(ClipData.newPlainText("OpenClaw reply", text))
        toast("Copied")
    }

    private fun toast(text: String) = Toast.makeText(this, text, Toast.LENGTH_SHORT).show()

    private fun rounded(color: Int) = android.graphics.drawable.GradientDrawable().apply {
        setColor(color)
        cornerRadius = dp(18).toFloat()
        setStroke(dp(1), Color.rgb(225, 225, 225))
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    companion object {
        const val MATCH = -1
        const val WRAP = -2
        const val PICK_FILES = 1001
    }
}
