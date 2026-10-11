package nl.lrvdlinden.bingr

/**
 * Maakt IPTV-titels schoon ("NL - The Batman (2022) [4K]" → "The Batman", 2022)
 * en herkent afleveringen ("Breaking Bad S01 E02").
 */
object TitleCleaner {
    data class Parsed(val title: String, val year: Int? = null, val season: Int? = null, val episode: Int? = null)

    private val prefix = Regex("^\\s*(\\|[^|]{1,12}\\||\\[[^\\]]{1,12}\\]|[A-Z]{2,4}\\s*[-:|]\\s+)")
    private val episode = Regex("[Ss](\\d{1,2})\\s*[Ee](\\d{1,3})")
    private val year = Regex("[\\(\\[\\s-](19\\d{2}|20\\d{2})[\\)\\]]?")
    private val junk = Regex(
        "(?i)\\b(4k|uhd|fhd|hd|sd|hevc|h\\.?265|x265|x264|1080p|720p|2160p|multi|subs?|nl ?sub|vost\\w*|dolby|atmos|hdr10?\\+?|dv)\\b|\\[[^\\]]*\\]|\\([^\\)]*\\)"
    )
    private val spaces = Regex("[ \\t\\u00A0]+")

    fun parse(raw: String): Parsed {
        var s = raw
        // landcodes/labels vooraan weg (eventueel meerdere)
        repeat(2) { s = prefix.replace(s, "") }

        var season: Int? = null
        var ep: Int? = null
        episode.find(s)?.let { m ->
            season = m.groupValues[1].toIntOrNull(); ep = m.groupValues[2].toIntOrNull()
            s = s.substring(0, m.range.first)
        }

        var y: Int? = null
        year.findAll(s).lastOrNull()?.let { m ->
            y = m.groupValues[1].toIntOrNull()
            s = s.removeRange(m.range)
        }

        s = junk.replace(s, " ")
        s = s.replace("_", " ").replace(".", " ")
            .split(spaces).filter { it.isNotEmpty() }.joinToString(" ")
            .trim { it == ' ' || it == '-' || it == '|' || it == ':' }
        return Parsed(title = s.ifEmpty { raw }, year = y, season = season, episode = ep)
    }
}
