package nl.lrvdlinden.bingr

import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction

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
                if (cur.isNotEmpty()) { blocks += cur; cur = mutableListOf() }
            } else cur += line
        }
        if (cur.isNotEmpty()) blocks += cur
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
