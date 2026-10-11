package nl.lrvdlinden.bingr

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

class HttpException(val code: Int, message: String) : Exception(message)

/** Netwerk: één OkHttp-client, JSON via kotlinx.serialization. Alles op Dispatchers.IO. */
object Http {
    const val USER_AGENT = "Bingr v1.0.0"
    val json = Json { ignoreUnknownKeys = true; isLenient = true; coerceInputValues = true; explicitNulls = false }
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    data class Response(val code: Int, val body: String, val bytes: ByteArray? = null) {
        val ok: Boolean get() = code in 200..299
    }

    suspend fun request(
        url: String,
        method: String = "GET",
        headers: Map<String, String> = emptyMap(),
        jsonBody: String? = null,
        formBody: Map<String, String>? = null,
        raw: Boolean = false,
    ): Response = withContext(Dispatchers.IO) {
        val b = Request.Builder().url(url).header("User-Agent", USER_AGENT)
        headers.forEach { (k, v) -> b.header(k, v) }
        when {
            jsonBody != null -> b.method(method, jsonBody.toRequestBody("application/json".toMediaType()))
            formBody != null -> b.method(method, formBody.entries.joinToString("&") {
                java.net.URLEncoder.encode(it.key, "UTF-8") + "=" + java.net.URLEncoder.encode(it.value, "UTF-8")
            }.toRequestBody("application/x-www-form-urlencoded".toMediaType()))
            method != "GET" -> b.method(method, ByteArray(0).toRequestBody(null))
        }
        client.newCall(b.build()).execute().use { r ->
            if (raw) { val bytes = r.body?.bytes() ?: ByteArray(0); Response(r.code, "", bytes) }
            else Response(r.code, r.body?.string() ?: "")
        }
    }

    suspend fun get(url: String, headers: Map<String, String> = emptyMap()): String {
        val r = request(url, headers = headers)
        if (!r.ok) throw HttpException(r.code, "HTTP ${r.code}")
        return r.body
    }

    suspend fun bytes(url: String, headers: Map<String, String> = emptyMap()): ByteArray {
        val r = request(url, headers = headers, raw = true)
        if (!r.ok) throw HttpException(r.code, "HTTP ${r.code}")
        return r.bytes ?: ByteArray(0)
    }

    inline fun <reified T> decode(s: String): T = json.decodeFromString(s)

    fun enc(s: String): String = java.net.URLEncoder.encode(s, "UTF-8").replace("+", "%20")
}
