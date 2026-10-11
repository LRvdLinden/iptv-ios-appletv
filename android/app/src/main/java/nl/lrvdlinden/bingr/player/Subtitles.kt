package nl.lrvdlinden.bingr

import androidx.compose.runtime.mutableIntStateOf
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

/**
 * Grootte van ondertitels (Mijn Bingr → Speler, en tijdens het afspelen bij Opties) — zoals SubtitleSize in Engines.swift.
 * Prefs-sleutel "subtitle.size": 0 = klein (standaard), 1 = middel, 2 = groot.
 *
 * Voor een keuzelijst in Instellingen:
 * ```
 * for (s in SubtitleSize.entries) Row(s.title, selected = SubtitleSize.current == s) { SubtitleSize.current = s }
 * ```
 * `SubtitleSize.current` is Compose-state (tekent opnieuw bij wijziging). Tijdens het afspelen past
 * `PlayerController.applySubtitleSize()` de nieuwe grootte meteen toe (VLC laadt dan op dezelfde plek opnieuw).
 */
enum class SubtitleSize(val raw: Int) {
    SMALL(0), MEDIUM(1), LARGE(2);

    val title: String
        get() = when (this) { SMALL -> L("Small"); MEDIUM -> L("Medium"); LARGE -> L("Large") }

    /** VLC `:sub-text-scale` — percentage van de standaardgrootte (die op een tv erg groot is). */
    val vlcScale: Int
        get() = when (this) { SMALL -> 55; MEDIUM -> 75; LARGE -> 100 }

    /** VLC `:freetype-rel-fontsize` — hoger getal = kleiner. */
    val vlcRelFontSize: Int
        get() = when (this) { SMALL -> 20; MEDIUM -> 18; LARGE -> 16 }

    /** ExoPlayer (Media3 SubtitleView): factor op de standaard tekstgrootte (5,33 % van de beeldhoogte). */
    val exoFactor: Float
        get() = when (this) { SMALL -> 0.8f; MEDIUM -> 1.0f; LARGE -> 1.25f }

    /** Eigen overlay (OpenSubtitles-bestanden bij ExoPlayer). */
    val overlayFactor: Float
        get() = when (this) { SMALL -> 0.75f; MEDIUM -> 0.95f; LARGE -> 1.2f }

    companion object {
        const val key = "subtitle.size"
        private val version = mutableIntStateOf(0)

        fun from(raw: Int): SubtitleSize = entries.firstOrNull { it.raw == raw } ?: SMALL

        /** De gekozen grootte (Compose-state). */
        var current: SubtitleSize
            get() { version.intValue; return from(Prefs.int(key, 0)) }
            set(v) { Prefs.put(key, v.raw); version.intValue++ }
    }
}

/** Eén regel ondertitel (seconden). */
data class SubtitleCue(val start: Double, val end: Double, val text: String)

/** Externe ondertitels (SRT) — eigen overlay voor ExoPlayer en UTF-8-normalisatie voor VLC. */
object SRT {
    private val tagRegex = Regex("<[^>]+>")
    private val braceRegex = Regex("\\{[^}]*\\}")

    private fun isUTF8(bytes: ByteArray): Boolean = runCatching {
        Charsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes))
        true
    }.getOrDefault(false)

    private fun startsWith(b: ByteArray, vararg prefix: Int): Boolean =
        b.size >= prefix.size && prefix.indices.all { (b[it].toInt() and 0xFF) == prefix[it] }

    /** Tekst uit een ondertitelbestand: UTF-8 (met/zonder BOM), UTF-16, anders Windows-1252/Latin-1. */
    fun decode(bytes: ByteArray): String {
        if (startsWith(bytes, 0xFF, 0xFE)) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
        if (startsWith(bytes, 0xFE, 0xFF)) return String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
        if (isUTF8(bytes)) return String(bytes, Charsets.UTF_8).replace("﻿", "")
        val cp1252 = runCatching { Charset.forName("windows-1252") }.getOrNull()
        return if (cp1252 != null) String(bytes, cp1252) else String(bytes, Charsets.ISO_8859_1)
    }

    /** Schrijft een UTF-8-kopie naast het origineel (VLC en de eigen overlay lezen dan altijd goed). */
    fun normalizedFile(file: File): File? {
        val d = runCatching { file.readBytes() }.getOrNull() ?: return null
        if (isUTF8(d) && !startsWith(d, 0xEF, 0xBB, 0xBF)) return file
        val out = File(file.parentFile, file.nameWithoutExtension + ".utf8.srt")
        return runCatching { out.writeText(decode(d), Charsets.UTF_8); out }.getOrNull()
    }

    fun parse(bytes: ByteArray): List<SubtitleCue> = parse(decode(bytes))

    fun parse(text: String): List<SubtitleCue> {
        val clean = text.replace("\r\n", "\n").replace("\r", "\n")
        // blokken scheiden op lege regels (ook regels met alleen spaties)
        val blocks = mutableListOf<List<String>>()
        var cur = mutableListOf<String>()
        for (line in clean.split("\n")) {
            if (line.isBlank()) {
                if (cur.isNotEmpty()) { blocks.add(cur); cur = mutableListOf() }
            } else cur.add(line)
        }
        if (cur.isNotEmpty()) blocks.add(cur)
        val cues = mutableListOf<SubtitleCue>()
        for (lines in blocks) {
            val ti = lines.indexOfFirst { it.contains("-->") }
            if (ti < 0) continue
            val parts = lines[ti].split("-->")
            if (parts.size != 2) continue
            val s = time(parts[0]) ?: continue
            val e = time(parts[1]) ?: continue
            val body = lines.drop(ti + 1).joinToString("\n")
                .replace(tagRegex, "")
                .replace(braceRegex, "")
                .trim()
            if (body.isNotEmpty()) cues += SubtitleCue(s, e, body)
        }
        return cues.sortedBy { it.start }
    }

    private fun time(s: String): Double? {
        // "00:00:05,000 X1:100 …" → alleen de tijd
        val first = s.trim().split(Regex("\\s+")).firstOrNull() ?: return null
        val t = first.replace(",", ".")
        val p = t.split(":")
        if (p.size != 3) return null
        val h = p[0].toDoubleOrNull() ?: return null
        val m = p[1].toDoubleOrNull() ?: return null
        val sec = p[2].take(6).toDoubleOrNull() ?: return null
        return h * 3600 + m * 60 + sec
    }
}
