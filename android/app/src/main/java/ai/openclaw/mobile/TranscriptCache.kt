package ai.openclaw.mobile

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class TranscriptCache(context: Context, gatewayUrl: String) {
    private val root = File(context.filesDir, "chat-cache/${hash(gatewayUrl)}").apply { mkdirs() }
    private val sessionsFile = File(root, "sessions.json")
    private fun sessionFile(key:String) = File(root, "session-${hash(key)}.json")

    fun saveSessions(sessions:List<SessionSummary>) {
        val a = JSONArray()
        sessions.forEach { a.put(JSONObject().put("key",it.key).put("title",it.title).put("updatedAt",it.updatedAt)) }
        atomicWrite(sessionsFile, a.toString())
    }
    fun loadSessions():List<SessionSummary> = try {
        val a=JSONArray(sessionsFile.readText()); buildList { for(i in 0 until a.length()) { val j=a.getJSONObject(i); add(SessionSummary(j.getString("key"),j.optString("title",j.getString("key")),j.optLong("updatedAt"))) } }
    } catch(_:Throwable) { emptyList() }

    fun saveMessages(key:String,messages:List<ChatMessage>) {
        val a=JSONArray(); messages.forEach { m ->
            val aa=JSONArray();m.attachments.forEach{aa.put(it)}
            a.put(JSONObject().put("id",m.id).put("role",m.role).put("text",m.text).put("attachments",aa).put("failed",m.failed))
        }
        atomicWrite(sessionFile(key),a.toString())
    }
    fun loadMessages(key:String):MutableList<ChatMessage> = try {
        val a=JSONArray(sessionFile(key).readText()); MutableList(a.length()) { i ->
            val j=a.getJSONObject(i); val names=mutableListOf<String>(); val aa=j.optJSONArray("attachments"); if(aa!=null)for(n in 0 until aa.length())names+=aa.getString(n)
            ChatMessage(j.optString("id","cached-$i"),j.optString("role","assistant"),j.optString("text"),names,false,j.optBoolean("failed"))
        }
    } catch(_:Throwable) { mutableListOf() }

    private fun atomicWrite(file:File,text:String){val tmp=File(file.parentFile,file.name+".tmp");tmp.writeText(text);if(!tmp.renameTo(file)){file.writeText(text);tmp.delete()}}
    companion object { private fun hash(s:String):String = MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).take(12).joinToString(""){"%02x".format(it)} }
}
