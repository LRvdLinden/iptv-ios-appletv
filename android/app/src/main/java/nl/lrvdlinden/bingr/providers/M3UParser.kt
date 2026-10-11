package nl.lrvdlinden.bingr

/**
 * Leest M3U/M3U8-playlists (inclusief Xtream-achtige get.php-lijsten) en
 * verdeelt ze in Live TV, Films en Series.
 */
object M3UParser {
    data class Entry(val name: String, val attrs: Map<String, String>, val url: String, val duration: Int)

    private val attrRegex = Regex("([\\w-]+)=\"([^\"]*)\"")

    fun entries(text: String): List<Entry> {
        val out = ArrayList<Entry>(4096)
        var pendingName: String? = null
        var pendingAttrs: Map<String, String> = emptyMap()
        var pendingDuration = -1
        var groupOverride: String? = null

        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty()) continue
            when {
                line.startsWith("#EXTINF") -> {
                    val commaIdx = lastTopLevelComma(line)
                    val header = if (commaIdx != null) line.substring(0, commaIdx) else line
                    val name = if (commaIdx != null) line.substring(commaIdx + 1).trim() else ""
                    val attrs = HashMap<String, String>()
                    for (m in attrRegex.findAll(header)) attrs[m.groupValues[1].lowercase()] = m.groupValues[2]
                    val durStr = header.replace("#EXTINF:", "").split(" ").firstOrNull { it.isNotEmpty() } ?: "-1"
                    pendingName = name.ifEmpty { attrs["tvg-name"] ?: "?" }
                    pendingAttrs = attrs
                    pendingDuration = durStr.toIntOrNull() ?: -1
                }
                line.startsWith("#EXTGRP:") -> groupOverride = line.substring(8)
                line.startsWith("#") -> {}
                pendingName != null -> {
                    var attrs = pendingAttrs
                    val g = groupOverride
                    if (attrs["group-title"] == null && g != null) attrs = attrs + ("group-title" to g)
                    out.add(Entry(pendingName, attrs, line, pendingDuration))
                    pendingName = null; groupOverride = null
                }
            }
        }
        return out
    }

    /** Komma ná de laatste attribuut-quote (titels mogen zelf komma's bevatten). */
    private fun lastTopLevelComma(s: String): Int? {
        var inQuote = false
        for (i in s.indices) {
            val ch = s[i]
            if (ch == '"') inQuote = !inQuote
            else if (ch == ',' && !inQuote) return i
        }
        return null
    }

    fun library(text: String, playlistID: String): Library {
        val channels = ArrayList<Channel>()
        val movies = ArrayList<Movie>()
        val seriesMap = HashMap<String, Series>()
        val seriesEpisodes = HashMap<String, MutableList<Episode>>()
        val seriesOrder = ArrayList<String>()
        var number = 0
        val other = L("Other")
        val prefix = playlistID.take(8)

        for (e in entries(text)) {
            val group = e.attrs["group-title"]?.takeIf { it.isNotEmpty() } ?: other
            val logo = Net.urlValue(e.attrs["tvg-logo"])
            val lowerURL = e.url.lowercase()
            val parsed = TitleCleaner.parse(e.name)
            val id = "$prefix-${stableHash(e.url)}"

            val looksSeries = lowerURL.contains("/series/") || (parsed.season != null && parsed.episode != null)
            val looksMovie = !looksSeries && (lowerURL.contains("/movie/") ||
                lowerURL.endsWith(".mkv") || lowerURL.endsWith(".mp4") || lowerURL.endsWith(".avi"))

            when {
                looksSeries -> {
                    val sKey = parsed.title.lowercase()
                    if (seriesMap[sKey] == null) {
                        seriesMap[sKey] = Series(id = "s-${stableHash(group + sKey)}", title = parsed.title, year = parsed.year,
                            poster = logo, group = group)
                        seriesEpisodes[sKey] = ArrayList()
                        seriesOrder.add(sKey)
                    }
                    val eps = seriesEpisodes.getValue(sKey)
                    eps.add(Episode(id = id, seriesID = seriesMap.getValue(sKey).id, season = parsed.season ?: 1,
                        number = parsed.episode ?: (eps.size + 1), title = e.name,
                        streamURL = Net.urlValue(e.url), still = logo))
                }
                looksMovie -> movies.add(Movie(id = id, title = parsed.title, year = parsed.year, poster = logo, group = group,
                    streamURL = Net.urlValue(e.url)))
                else -> {
                    number += 1
                    val catchup = (e.attrs["catchup-days"] ?: e.attrs["timeshift"] ?: "").toIntOrNull() ?: 0
                    channels.add(Channel(id = id, name = e.name, logo = logo, group = group,
                        streamURL = Net.urlValue(e.url),
                        epgID = e.attrs["tvg-id"]?.takeIf { it.isNotEmpty() },
                        number = (e.attrs["tvg-chno"] ?: "").toIntOrNull() ?: number,
                        catchupDays = catchup))
                }
            }
        }
        val series = seriesOrder.mapNotNull { k ->
            seriesMap[k]?.copy(episodes = (seriesEpisodes[k] ?: emptyList<Episode>())
                .sortedWith(compareBy<Episode>({ it.season }, { it.number })))
        }
        return Library(channels = channels, movies = movies, series = series)
    }

    fun epgURL(fromHeader: String): String? {
        val first = fromHeader.lineSequence().firstOrNull()?.trimStart('\uFEFF')?.trim() ?: return null
        if (!first.startsWith("#EXTM3U")) return null
        for (key in listOf("url-tvg", "x-tvg-url", "tvg-url")) {
            val start = first.indexOf("$key=\"")
            if (start >= 0) {
                val rest = first.substring(start + key.length + 2)
                val end = rest.indexOf('"')
                if (end >= 0) return Net.urlValue(rest.substring(0, end).split(",").firstOrNull())
            }
        }
        return null
    }

    /** Stabiele (niet-gerandomiseerde) hash zodat ID's tussen apparaten gelijk blijven (FNV-1a 64). */
    fun stableHash(s: String): String {
        var h = 0xcbf29ce484222325uL
        for (b in s.encodeToByteArray()) {
            h = h xor b.toUByte().toULong()
            h *= 0x100000001b3uL
        }
        return h.toString(36)
    }
}
