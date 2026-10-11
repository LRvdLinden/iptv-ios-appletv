package nl.lrvdlinden.bingr

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.text.Normalizer
import java.text.SimpleDateFormat
import java.util.Locale

/** Fout met een (vertaalde) tekst die direct aan de gebruiker getoond kan worden. */
class ServiceException(message: String) : Exception(message)

/**
 * Netwerk-hulpjes voor de diensten (tegenhanger van HTTP.swift): foutteksten zoals op iOS,
 * JSON als boom (servers sturen rommelige JSON), URL's met query-parameters.
 */
object Net {
    fun statusError(code: Int, body: String): ServiceException = ServiceException(
        if (code == 401 || code == 403 || code == 511)
            L("Sign-in failed (%d). Check the username and password of this playlist.", code)
        else L("Server error %d: %@", code, body.take(200))
    )
    fun badURL() = ServiceException(L("Invalid URL"))
    fun decoding(m: String) = ServiceException(L("Couldn't read the response: %@", m))

    /** Tekst voor de gebruiker bij een willekeurige fout. */
    fun message(e: Throwable): String = when (e) {
        is ServiceException -> e.message ?: ""
        is HttpException -> statusError(e.code, "").message ?: ""
        else -> e.localizedMessage ?: e.toString()
    }

    private suspend fun req(
        url: String, method: String = "GET", headers: Map<String, String> = emptyMap(),
        jsonBody: String? = null, raw: Boolean = false,
    ): Http.Response {
        if (url.toHttpUrlOrNull() == null) throw badURL()
        return Http.request(url, method = method, headers = headers, jsonBody = jsonBody, raw = raw)
    }

    /** GET → tekst; gooit [ServiceException] bij een foutstatus. */
    suspend fun text(url: String, headers: Map<String, String> = emptyMap()): String {
        val r = req(url, headers = headers)
        if (!r.ok) throw statusError(r.code, r.body)
        return r.body
    }

    /** GET → JSON-boom. */
    suspend fun json(url: String, headers: Map<String, String> = emptyMap()): JsonElement = parse(text(url, headers))

    fun parse(text: String): JsonElement =
        try { Http.json.parseToJsonElement(text) } catch (e: Exception) { throw decoding(e.message ?: "") }

    /** JSON-verzoek (zoals jsonRequest in MediaServerClients.swift): Accept JSON, optioneel body. */
    suspend fun send(
        url: String, method: String = "GET", headers: Map<String, String> = emptyMap(), body: JsonElement? = null,
    ): String {
        val r = req(url, method, mapOf("Accept" to "application/json") + headers, body?.toString())
        if (!r.ok) throw statusError(r.code, r.body)
        return r.body
    }

    /** URL met query-parameters (null bij een ongeldige basis-URL). */
    fun url(base: String, query: List<Pair<String, String>> = emptyList()): String? {
        val b = base.trim().toHttpUrlOrNull()?.newBuilder() ?: return null
        query.forEach { (k, v) -> b.addQueryParameter(k, v) }
        return b.build().toString()
    }

    fun normalizedServer(s: String): String {
        var v = trimmedSlash(s)
        if (!v.lowercase().startsWith("http")) v = "http://$v"
        return v
    }

    fun trimmedSlash(s: String): String = s.trim().trimEnd('/')

    /** Lege tekst → null (tegenhanger van String.urlValue). */
    fun urlValue(s: String?): String? = s?.trim()?.takeIf { it.isNotEmpty() }

    /** ISO-datum met 0–7 decimalen (Jellyfin/Emby gebruiken er 7) → epoch-ms. */
    fun parseISODate(input: String?): Long? {
        var s = input?.trim()?.takeIf { it.isNotEmpty() } ?: return null
        val dot = s.indexOf('.')
        if (dot >= 0) {
            var end = dot + 1
            while (end < s.length && s[end].isDigit()) end++
            s = s.removeRange(dot, end)
        }
        if (s.length == 10) s += "T00:00:00"
        s = when {
            s.endsWith("Z") -> s.dropLast(1) + "+0000"
            s.length == 19 -> "$s+0000"
            s.length == 25 && (s[19] == '+' || s[19] == '-') && s[22] == ':' -> s.substring(0, 22) + s.substring(23)
            else -> s
        }
        return runCatching { SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssZ", Locale.US).parse(s)?.time }.getOrNull()
    }

    /** "yyyy-MM-dd" (lokale tijd) → epoch-ms */
    fun parseDay(s: String?): Long? {
        val d = s?.take(10)?.takeIf { it.length == 10 } ?: return null
        return runCatching { SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(d)?.time }.getOrNull()
    }

    private val marks = Regex("\\p{Mn}+")
    /** Hoofdletter- en accent-ongevoelig (zoals String.folding op iOS). */
    fun fold(s: String): String = marks.replace(Normalizer.normalize(s, Normalizer.Form.NFD), "").lowercase()
    /** Alleen letters en cijfers, gevouwen — voor het vergelijken van titels. */
    fun normTitle(s: String): String = fold(s).filter { it.isLetterOrDigit() }
}

// MARK: lenient JSON (tegenhanger van Flex / StringOrArray) -----------------------------

val JsonElement?.jObj: JsonObject? get() = this as? JsonObject
val JsonElement?.jArr: JsonArray? get() = this as? JsonArray

/** Waarde als tekst, of het nu een string, getal of bool is (bool → "1"/"0"). */
val JsonElement?.jFlex: String?
    get() {
        val p = this as? JsonPrimitive ?: return null
        if (p is JsonNull) return null
        if (!p.isString && (p.content == "true" || p.content == "false")) return if (p.content == "true") "1" else "0"
        return p.content
    }

fun JsonElement?.jS(key: String): String? = jObj?.get(key).jFlex
fun JsonElement?.jI(key: String): Int? = jS(key)?.let { it.trim().toIntOrNull() ?: it.trim().toDoubleOrNull()?.toInt() }
fun JsonElement?.jL(key: String): Long? = jS(key)?.let { it.trim().toLongOrNull() ?: it.trim().toDoubleOrNull()?.toLong() }
fun JsonElement?.jD(key: String): Double? = jS(key)?.trim()?.toDoubleOrNull()
fun JsonElement?.jB(key: String): Boolean? = jS(key)?.let { it == "1" || it.equals("true", ignoreCase = true) }
fun JsonElement?.jO(key: String): JsonObject? = jObj?.get(key) as? JsonObject
fun JsonElement?.jList(key: String): List<JsonElement> = (jObj?.get(key) as? JsonArray) ?: emptyList()
/** Veld dat een string óf een lijst met strings kan zijn (bijv. Xtream backdrop_path). */
fun JsonElement?.jStrings(key: String): List<String> = when (val v = jObj?.get(key)) {
    is JsonArray -> v.mapNotNull { it.jFlex }.filter { it.isNotEmpty() }
    else -> listOfNotNull(v.jFlex?.takeIf { it.isNotEmpty() })
}
/** Element als lijst (null/object → leeg). */
val JsonElement?.jItems: List<JsonElement> get() = (this as? JsonArray) ?: emptyList()
