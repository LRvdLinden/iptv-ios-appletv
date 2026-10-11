package nl.lrvdlinden.bingr

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.text.Collator
import java.util.Locale

/** Een audio- of ondertitelspoor uit een stream (beide engines). */
data class MediaTrack(val id: String, val name: String, val lang: String? = null)

/**
 * Standaard audio- en ondertiteltaal (Mijn Bingr → Speler).
 * Wordt toegepast zodra een stream zijn sporen bekendmaakt, in beide engines.
 */
object TrackPreferences {
    const val audioKey = "player.audioLanguage"       // "" = zoals de stream
    const val subtitleKey = "player.subtitleLanguage" // "" = zoals de stream, "off" = uit

    /** Verhoogt bij elke wijziging zodat Compose opnieuw tekent. */
    private var version by mutableStateOf(0)

    var audio: String
        get() { version; return Prefs.string(audioKey) ?: "" }
        set(v) { Prefs.put(audioKey, v); version++ }

    var subtitle: String
        get() { version; return Prefs.string(subtitleKey) ?: "" }
        set(v) { Prefs.put(subtitleKey, v); version++ }

    /** Talen die je kunt kiezen (ISO 639-1) met hun ISO 639-2-varianten (zoals streams ze vaak noemen). */
    val languages: List<Pair<String, List<String>>> = listOf(
        "nl" to listOf("nld", "dut", "vlaams", "flemish"), "en" to listOf("eng"), "de" to listOf("deu", "ger"),
        "fr" to listOf("fra", "fre"), "es" to listOf("spa", "esp", "castellano", "latino"), "it" to listOf("ita"),
        "pt" to listOf("por", "brazil", "brasil"), "tr" to listOf("tur"), "ar" to listOf("ara"), "pl" to listOf("pol"),
        "zh" to listOf("zho", "chi", "chs", "cht", "mandarin", "cantonese"), "ja" to listOf("jpn"),
        "ko" to listOf("kor"), "ru" to listOf("rus"), "uk" to listOf("ukr"), "hi" to listOf("hin"), "sv" to listOf("swe"),
        "da" to listOf("dan"), "no" to listOf("nor", "nob", "nno"), "fi" to listOf("fin"), "el" to listOf("ell", "gre"),
        "he" to listOf("heb"), "hu" to listOf("hun"), "cs" to listOf("ces", "cze"), "ro" to listOf("ron", "rum"),
        "bg" to listOf("bul"), "hr" to listOf("hrv"), "sr" to listOf("srp"), "fa" to listOf("fas", "per"),
        "ur" to listOf("urd"), "th" to listOf("tha"), "vi" to listOf("vie"), "id" to listOf("ind"),
        "ms" to listOf("msa", "may"), "ta" to listOf("tam"), "pa" to listOf("pan"), "bn" to listOf("ben"),
        "sq" to listOf("sqi", "alb"), "ku" to listOf("kur"), "so" to listOf("som"),
    )

    private fun alts(code: String): List<String> = languages.firstOrNull { it.first == code }?.second ?: emptyList()

    /** Taalnaam in de taal van de app. */
    fun name(code: String): String {
        val loc = Localizer.locale
        val n = Locale(code).getDisplayLanguage(loc)
        if (n.isNullOrBlank()) return code
        return n.replaceFirstChar { if (it.isLowerCase()) it.titlecase(loc) else it.toString() }
    }

    private val region: Map<String, String> = mapOf(
        "en" to "GB", "nl" to "NL", "de" to "DE", "fr" to "FR", "es" to "ES", "it" to "IT", "pt" to "PT", "tr" to "TR", "ar" to "SA",
        "pl" to "PL", "zh" to "CN", "ja" to "JP", "ko" to "KR", "ru" to "RU", "uk" to "UA", "hi" to "IN", "sv" to "SE", "da" to "DK",
        "no" to "NO", "nb" to "NO", "fi" to "FI", "el" to "GR", "he" to "IL", "hu" to "HU", "cs" to "CZ", "ro" to "RO", "bg" to "BG",
        "hr" to "HR", "sr" to "RS", "fa" to "IR", "ur" to "PK", "th" to "TH", "vi" to "VN", "id" to "ID", "ms" to "MY", "ta" to "LK",
        "pa" to "IN", "bn" to "BD", "sq" to "AL", "ku" to "IQ", "so" to "SO", "sk" to "SK", "sl" to "SI", "et" to "EE", "lv" to "LV",
        "lt" to "LT", "is" to "IS", "ga" to "IE", "ca" to "AD", "eu" to "ES", "gl" to "ES", "tl" to "PH", "mk" to "MK", "bs" to "BA",
        "ka" to "GE", "hy" to "AM", "az" to "AZ", "kk" to "KZ", "mn" to "MN", "ne" to "NP", "si" to "LK", "af" to "ZA", "sw" to "KE",
    )

    /** Vlag-emoji voor een taal of OpenSubtitles-code ("nl", "pt-BR", "zh-CN", "eng" …). */
    fun flag(code: String): String {
        val c = code.lowercase().replace("_", "-")
        val parts = c.split("-").filter { it.isNotEmpty() }
        var base = parts.firstOrNull() ?: c
        if (base.length == 3) languages.firstOrNull { base in it.second }?.let { base = it.first }
        // regio uit de code zelf (pt-BR, zh-TW, en-US)
        if (parts.size > 1 && parts[1].length == 2 && parts[1].all { it in 'a'..'z' }) return emoji(parts[1])
        return region[base]?.let { emoji(it) } ?: "🌐"
    }

    private fun emoji(region: String): String {
        val sb = StringBuilder()
        for (ch in region.uppercase()) {
            if (ch !in 'A'..'Z') return "🌐"
            sb.appendCodePoint(0x1F1E6 + (ch - 'A'))
        }
        return sb.toString()
    }

    /** "🇳🇱 Nederlands" voor keuzelijsten. */
    fun label(code: String): String = "${flag(code)} ${name(code)}"

    /** Talen alfabetisch op naam. */
    val sortedCodes: List<String>
        get() {
            val col = Collator.getInstance(Localizer.locale).apply { strength = Collator.PRIMARY }
            return languages.map { it.first }.sortedWith { a, b -> col.compare(name(a), name(b)) }
        }

    /** Past een spoor bij deze taal? Kijkt naar de taalcode (ExoPlayer) en naar de naam (VLC: "Dutch - [Nederlands]"). */
    fun matches(t: MediaTrack, code: String): Boolean {
        val l = t.lang?.lowercase()
        if (!l.isNullOrEmpty()) {
            val base = l.split('-', '_').firstOrNull() ?: ""
            if (base == code || base in alts(code)) return true
        }
        val n = t.name.lowercase()
        val words = n.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }.toSet()
        val needles = mutableListOf(code)
        needles += alts(code)
        for (id in listOf("en", code, Localizer.language)) {
            val s = Locale(code).getDisplayLanguage(Locale(id)).lowercase()
            if (s.isNotBlank() && s != code) needles += s
        }
        return needles.any { s -> if (s.length <= 3) s in words else n.contains(s) }
    }
}
