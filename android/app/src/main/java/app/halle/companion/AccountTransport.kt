package app.halle.companion

import android.content.Context
import org.json.JSONObject
import java.io.IOException
import java.net.URI
import java.net.URL
import java.security.MessageDigest
import javax.net.ssl.HttpsURLConnection

internal fun ByteArray.hex() = joinToString("") { "%02x".format(it) }

internal data class AccountSession(val origin: String, val userId: String, val token: String, val expiresAt: Long) {
    // The same opaque subject on two different servers must never share files or an outbox.
    val scope: String get() = MessageDigest.getInstance("SHA-256").digest(("$origin\n$userId").toByteArray()).hex()
    fun json() = JSONObject().put("origin", origin).put("userId", userId).put("token", token).put("expiresAt", expiresAt)
    companion object {
        fun from(origin: String, data: JSONObject) = AccountSession(accountOrigin(origin), data.getString("userId"),
            data.getString("token"), data.getLong("expiresAt"))
    }
}

internal fun accountOrigin(raw: String): String {
    val uri = URI(raw.trim())
    require(uri.scheme.equals("https", true) && uri.host != null && uri.userInfo == null &&
        uri.rawQuery == null && uri.rawFragment == null && uri.path.trimEnd('/') in listOf("", "/account/v1")) {
        "Enter an HTTPS server address without a user, query or fragment."
    }
    return URI("https", null, uri.host.lowercase(java.util.Locale.ROOT), if (uri.port == 443) -1 else uri.port,
        null, null, null).toASCIIString()
}

internal class AccountHttpError(val status: Int, val reason: String?) : IOException("Account service returned HTTP $status")

internal object AccountTransport {
    fun request(origin: String, path: String, method: String = "GET", token: String? = null,
                body: JSONObject? = null, bytes: ByteArray? = null): JSONObject {
        val conn = URL(accountOrigin(origin) + "/account/v1" + path).openConnection() as HttpsURLConnection
        try {
            conn.instanceFollowRedirects = false
            conn.useCaches = false
            conn.connectTimeout = 12000
            conn.readTimeout = 45000
            conn.requestMethod = method
            token?.let { conn.setRequestProperty("Authorization", "Bearer $it") }
            val payload = bytes ?: body?.toString()?.toByteArray()
            if (payload != null) {
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", if (bytes == null) "application/json" else "application/octet-stream")
                conn.setFixedLengthStreamingMode(payload.size)
                conn.outputStream.use { it.write(payload) }
            }
            if (conn.responseCode !in 200..299) {
                val reason = runCatching { conn.errorStream?.bufferedReader()?.use { JSONObject(it.readText()).optString("error") } }.getOrNull()
                throw AccountHttpError(conn.responseCode, reason)
            }
            val raw = conn.inputStream.bufferedReader().use { it.readText() }
            return if (raw.isBlank()) JSONObject() else JSONObject(raw)
        } finally { conn.disconnect() }
    }
}

internal class AccountSessions(context: Context) {
    private val prefs = context.getSharedPreferences("account-sessions-v1", Context.MODE_PRIVATE)
    var lastOrigin: String
        get() = prefs.getString("origin", null) ?: BuildConfig.ACCOUNT_ORIGIN
        set(value) { check(prefs.edit().putString("origin", accountOrigin(value)).commit()) }

    private fun read(key: String) = prefs.getString(key, null)?.let {
        JSONObject(String(AndroidVault.open(ALIAS, it), Charsets.UTF_8))
    }
    private fun encrypted(data: JSONObject) = AndroidVault.seal(ALIAS, data.toString().toByteArray())
    fun current(): AccountSession? = synchronized(lock) {
        read("active")?.let { AccountSession.from(it.getString("origin"), it) }?.takeIf { it.expiresAt > System.currentTimeMillis() }
    }
    fun save(value: AccountSession) = synchronized(lock) {
        check(prefs.edit().putString("active", encrypted(value.json())).putString("origin", value.origin).commit())
    }
    fun logout(value: AccountSession, revoke: Boolean) = synchronized(lock) {
        if (current()?.token != value.token) return@synchronized
        val edit = prefs.edit().remove("active").remove("browser")
        if (revoke) edit.putString("revoke-" + java.util.UUID.randomUUID(), encrypted(value.json()))
        check(edit.commit())
    }
    fun revokePending() {
        prefs.all.keys.filter { it.startsWith("revoke-") }.forEach { key ->
            val data = read(key) ?: return@forEach
            val value = AccountSession.from(data.getString("origin"), data)
            if (value.expiresAt > System.currentTimeMillis()) {
                try { AccountTransport.request(value.origin, "/auth/logout", "POST", value.token, JSONObject()) }
                catch (e: AccountHttpError) { if (e.status != 401) throw e }
            }
            check(prefs.edit().remove(key).commit())
        }
    }
    fun browserPending() = read("browser")
    fun browserPending(value: JSONObject?) {
        check(prefs.edit().putString("browser", value?.let(::encrypted)).commit())
    }
    companion object {
        private val lock = Any()
        private const val ALIAS = "halle.private.account.credentials.v1"
    }
}
