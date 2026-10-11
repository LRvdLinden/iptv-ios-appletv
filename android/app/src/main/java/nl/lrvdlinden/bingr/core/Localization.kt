package nl.lrvdlinden.bingr

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.util.Locale

/**
 * Zelfde vertaalsysteem als iOS: Engelse tekst is de sleutel, vertalingen komen uit
 * Shared/Resources/Translations.json (meegebouwd als asset). Gebruik: L("Play"), L("%d seasons", n).
 * %@ (iOS) wordt %s.
 */
object Localizer {
    val supported = listOf(
        "en" to "English", "nl" to "Nederlands", "de" to "Deutsch", "fr" to "Français",
        "es" to "Español", "it" to "Italiano", "pt" to "Português", "tr" to "Türkçe",
        "pl" to "Polski", "ar" to "العربية", "zh-Hans" to "简体中文"
    )
    private var table: Map<String, Map<String, String>> = emptyMap()

    /** "" = volg het systeem */
    // (geen `var override … private set`: die setter botst op de JVM met setOverride())
    private var overrideState by mutableStateOf("")
    val override: String get() = overrideState
    var language by mutableStateOf("en")
        private set

    fun init(ctx: Context) {
        runCatching {
            val text = ctx.assets.open("Translations.json").bufferedReader().readText()
            val root = Json.parseToJsonElement(text).jsonObject
            table = root.mapValues { (_, v) -> (v as JsonObject).mapValues { it.value.jsonPrimitive.content } }
        }
        overrideState = Prefs.string("app.language") ?: ""
        language = resolve(override)
    }

    fun setOverride(code: String) {
        overrideState = code
        Prefs.put("app.language", code)
        language = resolve(code)
    }

    fun resolve(o: String): String {
        if (o.isNotEmpty()) return o
        val codes = supported.map { it.first }
        val l = Locale.getDefault()
        if (l.language == "zh") return "zh-Hans"
        return if (l.language in codes) l.language else "en"
    }

    fun text(key: String): String = if (language == "en") key else table[language]?.get(key) ?: key
    val locale: Locale get() = if (language == "zh-Hans") Locale.SIMPLIFIED_CHINESE else Locale(language)
    val isRTL: Boolean get() = language == "ar"
}

private fun iosToJava(f: String): String = f.replace("%@", "%s").replace("%ld", "%d")

fun L(key: String): String = iosToJava(Localizer.text(key)).replace("%%", "%")
fun L(key: String, vararg args: Any?): String =
    runCatching { String.format(Localizer.locale, iosToJava(Localizer.text(key)), *args) }.getOrElse { key }
