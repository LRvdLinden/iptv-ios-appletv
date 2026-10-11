package nl.lrvdlinden.bingr

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Kleine QR-encoder (bytemodus, foutcorrectie M, versie 1–40), naar het algoritme van Nayuki's qrcodegen.
 * Geen externe bibliotheek nodig. [encode] geeft een vierkant raster terug (true = zwart).
 */
object QrEncoder {
    private val ECC_M = intArrayOf(-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26,
        28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28)
    private val BLOCKS_M = intArrayOf(-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20,
        21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49)
    private const val ECL_FORMAT_BITS_M = 0

    fun encode(text: String): Array<BooleanArray>? {
        val data = text.toByteArray(Charsets.UTF_8)
        // kleinste versie zoeken
        var version = 1
        while (true) {
            if (version > 40) return null
            val ccBits = if (version <= 9) 8 else 16
            val needed = 4 + ccBits + data.size * 8
            if (needed <= numDataCodewords(version) * 8) break
            version++
        }
        val ccBits = if (version <= 9) 8 else 16
        val capacityBits = numDataCodewords(version) * 8
        val bits = ArrayList<Boolean>(capacityBits)
        fun append(value: Int, len: Int) { for (i in len - 1 downTo 0) bits.add(((value ushr i) and 1) != 0) }
        append(0x4, 4)
        append(data.size, ccBits)
        data.forEach { append(it.toInt() and 0xFF, 8) }
        append(0, minOf(4, capacityBits - bits.size))
        append(0, (8 - bits.size % 8) % 8)
        var pad = 0xEC
        while (bits.size < capacityBits) { append(pad, 8); pad = pad xor 0xEC xor 0x11 }
        val codewords = IntArray(bits.size / 8)
        for (i in bits.indices) if (bits[i]) codewords[i ushr 3] = codewords[i ushr 3] or (1 shl (7 - (i and 7)))

        val qr = Grid(version)
        qr.drawFunctionPatterns()
        val all = addEccAndInterleave(codewords, version)
        qr.drawCodewords(all)
        // beste masker kiezen
        var best = 0
        var minPenalty = Int.MAX_VALUE
        for (m in 0 until 8) {
            qr.applyMask(m); qr.drawFormatBits(m)
            val p = qr.penalty()
            if (p < minPenalty) { minPenalty = p; best = m }
            qr.applyMask(m)   // terugdraaien (xor)
        }
        qr.applyMask(best); qr.drawFormatBits(best)
        return qr.modules
    }

    private fun numRawDataModules(ver: Int): Int {
        var result = (16 * ver + 128) * ver + 64
        if (ver >= 2) {
            val numAlign = ver / 7 + 2
            result -= (25 * numAlign - 10) * numAlign - 55
            if (ver >= 7) result -= 36
        }
        return result
    }

    private fun numDataCodewords(ver: Int) = numRawDataModules(ver) / 8 - ECC_M[ver] * BLOCKS_M[ver]

    private fun addEccAndInterleave(data: IntArray, ver: Int): IntArray {
        val numBlocks = BLOCKS_M[ver]
        val blockEccLen = ECC_M[ver]
        val rawCodewords = numRawDataModules(ver) / 8
        val numShortBlocks = numBlocks - rawCodewords % numBlocks
        val shortBlockLen = rawCodewords / numBlocks
        val divisor = rsDivisor(blockEccLen)
        val blocks = ArrayList<IntArray>()
        var k = 0
        for (i in 0 until numBlocks) {
            val datLen = shortBlockLen - blockEccLen + (if (i < numShortBlocks) 0 else 1)
            val dat = data.copyOfRange(k, k + datLen)
            k += datLen
            val ecc = rsRemainder(dat, divisor)
            val block = IntArray(shortBlockLen + 1)
            dat.copyInto(block, 0)
            ecc.copyInto(block, block.size - blockEccLen)
            blocks.add(block)
        }
        val result = IntArray(rawCodewords)
        var r = 0
        for (i in 0 until blocks[0].size) {
            for (j in blocks.indices) {
                if (i != shortBlockLen - blockEccLen || j >= numShortBlocks) { result[r] = blocks[j][i]; r++ }
            }
        }
        return result
    }

    private fun rsMultiply(x: Int, y: Int): Int {
        var z = 0
        for (i in 7 downTo 0) {
            z = (z shl 1) xor ((z ushr 7) * 0x11D)
            z = z xor (((y ushr i) and 1) * x)
        }
        return z and 0xFF
    }

    private fun rsDivisor(degree: Int): IntArray {
        val result = IntArray(degree)
        result[degree - 1] = 1
        var root = 1
        for (i in 0 until degree) {
            for (j in 0 until degree) {
                result[j] = rsMultiply(result[j], root)
                if (j + 1 < degree) result[j] = result[j] xor result[j + 1]
            }
            root = rsMultiply(root, 0x02)
        }
        return result
    }

    private fun rsRemainder(data: IntArray, divisor: IntArray): IntArray {
        val result = IntArray(divisor.size)
        for (b in data) {
            val factor = (b xor result[0]) and 0xFF
            for (i in 0 until result.size - 1) result[i] = result[i + 1]
            result[result.size - 1] = 0
            for (i in result.indices) result[i] = result[i] xor rsMultiply(divisor[i], factor)
        }
        return result
    }

    private class Grid(val version: Int) {
        val size = version * 4 + 17
        val modules = Array(size) { BooleanArray(size) }
        val isFunction = Array(size) { BooleanArray(size) }

        fun set(x: Int, y: Int, dark: Boolean) { modules[y][x] = dark; isFunction[y][x] = true }

        fun drawFunctionPatterns() {
            for (i in 0 until size) { set(6, i, i % 2 == 0); set(i, 6, i % 2 == 0) }
            finder(3, 3); finder(size - 4, 3); finder(3, size - 4)
            val pos = alignmentPositions()
            val n = pos.size
            for (i in 0 until n) for (j in 0 until n) {
                if ((i == 0 && j == 0) || (i == 0 && j == n - 1) || (i == n - 1 && j == 0)) continue
                alignment(pos[i], pos[j])
            }
            drawFormatBits(0)
            drawVersion()
        }

        private fun finder(x: Int, y: Int) {
            for (dy in -4..4) for (dx in -4..4) {
                val dist = maxOf(kotlin.math.abs(dx), kotlin.math.abs(dy))
                val xx = x + dx; val yy = y + dy
                if (xx in 0 until size && yy in 0 until size) set(xx, yy, dist != 2 && dist != 4)
            }
        }

        private fun alignment(x: Int, y: Int) {
            for (dy in -2..2) for (dx in -2..2) set(x + dx, y + dy, maxOf(kotlin.math.abs(dx), kotlin.math.abs(dy)) != 1)
        }

        private fun alignmentPositions(): IntArray {
            if (version == 1) return IntArray(0)
            val numAlign = version / 7 + 2
            val step = (version * 8 + numAlign * 3 + 5) / (numAlign * 4 - 4) * 2
            val result = IntArray(numAlign)
            result[0] = 6
            var p = size - 7
            for (i in numAlign - 1 downTo 1) { result[i] = p; p -= step }
            return result
        }

        fun drawFormatBits(mask: Int) {
            val data = (ECL_FORMAT_BITS_M shl 3) or mask
            var rem = data
            repeat(10) { rem = (rem shl 1) xor ((rem ushr 9) * 0x537) }
            val bits = ((data shl 10) or rem) xor 0x5412
            fun bit(i: Int) = ((bits ushr i) and 1) != 0
            for (i in 0..5) set(8, i, bit(i))
            set(8, 7, bit(6)); set(8, 8, bit(7)); set(7, 8, bit(8))
            for (i in 9 until 15) set(14 - i, 8, bit(i))
            for (i in 0 until 8) set(size - 1 - i, 8, bit(i))
            for (i in 8 until 15) set(8, size - 15 + i, bit(i))
            set(8, size - 8, true)
        }

        private fun drawVersion() {
            if (version < 7) return
            var rem = version
            repeat(12) { rem = (rem shl 1) xor ((rem ushr 11) * 0x1F25) }
            val bits = (version shl 12) or rem
            for (i in 0 until 18) {
                val b = ((bits ushr i) and 1) != 0
                val a = size - 11 + i % 3
                val c = i / 3
                set(a, c, b); set(c, a, b)
            }
        }

        fun drawCodewords(data: IntArray) {
            var i = 0
            var right = size - 1
            while (right >= 1) {
                if (right == 6) right = 5
                for (vert in 0 until size) {
                    for (j in 0..1) {
                        val x = right - j
                        val upward = ((right + 1) and 2) == 0
                        val y = if (upward) size - 1 - vert else vert
                        if (!isFunction[y][x] && i < data.size * 8) {
                            modules[y][x] = ((data[i ushr 3] ushr (7 - (i and 7))) and 1) != 0
                            i++
                        }
                    }
                }
                right -= 2
            }
        }

        fun applyMask(mask: Int) {
            for (y in 0 until size) for (x in 0 until size) {
                if (isFunction[y][x]) continue
                val invert = when (mask) {
                    0 -> (x + y) % 2 == 0
                    1 -> y % 2 == 0
                    2 -> x % 3 == 0
                    3 -> (x + y) % 3 == 0
                    4 -> (x / 3 + y / 2) % 2 == 0
                    5 -> x * y % 2 + x * y % 3 == 0
                    6 -> (x * y % 2 + x * y % 3) % 2 == 0
                    else -> ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if (invert) modules[y][x] = !modules[y][x]
            }
        }

        /** Vereenvoudigde strafpunten (regels 1, 2, 3 en 4 van de QR-norm). */
        fun penalty(): Int {
            var result = 0
            // regel 1: rijen/kolommen van 5+ gelijke modules
            for (y in 0 until size) {
                var run = 1
                for (x in 1 until size) {
                    if (modules[y][x] == modules[y][x - 1]) { run++; if (run == 5) result += 3 else if (run > 5) result++ } else run = 1
                }
            }
            for (x in 0 until size) {
                var run = 1
                for (y in 1 until size) {
                    if (modules[y][x] == modules[y - 1][x]) { run++; if (run == 5) result += 3 else if (run > 5) result++ } else run = 1
                }
            }
            // regel 2: 2×2-blokken
            for (y in 0 until size - 1) for (x in 0 until size - 1) {
                val c = modules[y][x]
                if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += 3
            }
            // regel 3: finder-achtige patronen 1:1:3:1:1 met 4 licht ervoor/erna
            val pat = booleanArrayOf(true, false, true, true, true, false, true)
            fun matches(get: (Int) -> Boolean, start: Int): Boolean {
                for (k in 0 until 7) if (get(start + k) != pat[k]) return false
                val before = (1..4).all { start - it < 0 || !get(start - it) }
                val after = (1..4).all { start + 6 + it >= size || !get(start + 6 + it) }
                return before || after
            }
            for (y in 0 until size) for (x in 0..size - 7) if (matches({ modules[y][it] }, x)) result += 40
            for (x in 0 until size) for (y in 0..size - 7) if (matches({ modules[it][x] }, y)) result += 40
            // regel 4: verhouding donker/licht
            var dark = 0
            for (row in modules) for (m in row) if (m) dark++
            val total = size * size
            val k = (kotlin.math.abs(dark * 20 - total * 10) + total - 1) / total - 1
            result += maxOf(0, k) * 10
            return result
        }
    }
}

/** QR-code als Compose-tekening (wit vlak met stille zone). */
@Composable
fun QrCodeImage(text: String, size: Dp, modifier: Modifier = Modifier) {
    val grid = remember(text) { runCatching { QrEncoder.encode(text) }.getOrNull() }
    if (grid == null) return
    Canvas(
        modifier.clip(RoundedCornerShape(8.dp)).background(Color.White).padding(8.dp).size(size)
    ) {
        val n = grid.size
        val cell = this.size.width / n
        for (y in 0 until n) for (x in 0 until n) {
            if (grid[y][x]) drawRect(Color.Black, topLeft = Offset(x * cell, y * cell), size = Size(cell + 0.5f, cell + 0.5f))
        }
    }
}
