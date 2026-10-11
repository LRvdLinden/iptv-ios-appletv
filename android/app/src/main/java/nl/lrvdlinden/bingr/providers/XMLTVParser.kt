package nl.lrvdlinden.bingr

import android.util.Xml
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import java.io.BufferedInputStream
import java.io.InputStream
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.zip.GZIPInputStream

/** XMLTV (EPG) parser. Ondersteunt ook .xml.gz (herkend aan de gzip-header). Streamt, dus ook grote gidsen. */
object XMLTVParser {

    /** Download + parse in één keer (zonder het hele bestand in het geheugen te houden). */
    suspend fun load(url: String, daysBack: Int = 1, daysAhead: Int = 3): Map<String, List<EPGProgram>> =
        withContext(Dispatchers.IO) {
            runCatching {
                val req = Request.Builder().url(url.trim()).header("User-Agent", Http.USER_AGENT).build()
                Http.client.newCall(req).execute().use { r ->
                    if (!r.isSuccessful) return@use emptyMap<String, List<EPGProgram>>()
                    val body = r.body ?: return@use emptyMap<String, List<EPGProgram>>()
                    parse(body.byteStream(), daysBack, daysAhead)
                }
            }.getOrDefault(emptyMap<String, List<EPGProgram>>())
        }

    fun parse(data: ByteArray, daysBack: Int = 1, daysAhead: Int = 3): Map<String, List<EPGProgram>> =
        parse(data.inputStream(), daysBack, daysAhead)

    fun parse(input: InputStream, daysBack: Int = 1, daysAhead: Int = 3): Map<String, List<EPGProgram>> {
        val now = System.currentTimeMillis()
        val lower = now - daysBack * 86_400_000L
        val upper = now + daysAhead * 86_400_000L
        val programs = HashMap<String, MutableList<EPGProgram>>()

        val fmt = SimpleDateFormat("yyyyMMddHHmmss Z", Locale.US)
        val fmtNoTZ = SimpleDateFormat("yyyyMMddHHmmss", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
        fun date(s: String?): Long? {
            val t = s?.trim() ?: return null
            return runCatching { fmt.parse(t)?.time }.getOrNull()
                ?: runCatching { fmtNoTZ.parse(t.take(14))?.time }.getOrNull()
        }

        val stream = gunzipIfNeeded(input)
        try {
            val p = Xml.newPullParser()
            runCatching { p.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, false) }
            runCatching { p.setFeature("http://xmlpull.org/v1/doc/features.html#relaxed", true) }
            p.setInput(stream, null)

            var channel: String? = null
            var start = 0L
            var end = 0L
            var title = ""
            var desc = ""
            val text = StringBuilder()

            var ev = p.eventType
            while (ev != XmlPullParser.END_DOCUMENT) {
                when (ev) {
                    XmlPullParser.START_TAG -> {
                        text.setLength(0)
                        if (p.name == "programme") {
                            val ch = p.getAttributeValue(null, "channel")
                            val s = date(p.getAttributeValue(null, "start"))
                            val e = date(p.getAttributeValue(null, "stop"))
                            if (ch != null && s != null && e != null) {
                                channel = ch; start = s; end = e; title = ""; desc = ""
                            } else channel = null
                        }
                    }
                    XmlPullParser.TEXT -> text.append(p.text ?: "")
                    XmlPullParser.END_TAG -> when (p.name) {
                        "title" -> if (channel != null && title.isEmpty()) title = text.toString().trim()
                        "desc" -> if (channel != null && desc.isEmpty()) desc = text.toString().trim()
                        "programme" -> {
                            val c = channel
                            if (c != null && end >= lower && start <= upper) {
                                programs.getOrPut(c) { ArrayList() }.add(
                                    EPGProgram(channelID = c, title = title, description = desc.ifEmpty { null }, start = start, end = end)
                                )
                            }
                            channel = null
                        }
                    }
                }
                ev = p.next()
            }
        } catch (_: Exception) {
            // kapotte of afgebroken gids: houd wat er al gelezen is
        } finally {
            runCatching { stream.close() }
        }
        return programs.mapValues { (_, v) -> v.sortedBy { it.start } }
    }

    /** Pakt gzip uit als de data met de gzip-header (1f 8b) begint. */
    fun gunzipIfNeeded(input: InputStream): InputStream {
        val b = BufferedInputStream(input, 64 * 1024)
        b.mark(4)
        val b0 = b.read()
        val b1 = b.read()
        b.reset()
        return if (b0 == 0x1f && b1 == 0x8b) BufferedInputStream(GZIPInputStream(b, 64 * 1024), 64 * 1024) else b
    }
}
