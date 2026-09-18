package ai.openclaw.mobile

data class SessionSummary(val key:String, val title:String = key, val updatedAt:Long = 0L)
data class AttachmentDraft(val name:String, val mimeType:String, val bytes:ByteArray)
data class ChatMessage(
    val id:String,
    val role:String,
    var text:String,
    val attachments:MutableList<String> = mutableListOf(),
    var streaming:Boolean = false,
    var failed:Boolean = false
)
enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, RECONNECTING, PAIRING_REQUIRED }
