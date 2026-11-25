package com.taoo.xiutu.tools.retouch

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class InpaintTest {
    private val w = 260
    private val h = 200

    /** 竖条纹加噪点，中间挖一块涂成绿的。 */
    private fun sample(): Pair<IntArray, ByteArray> {
        val px = IntArray(w * h)
        val mask = ByteArray(w * h)
        var seed = 777
        fun rnd(): Int { seed = seed * 1103515245 + 12345; return seed ushr 16 and 255 }
        for (y in 0 until h) for (x in 0 until w) {
            val stripe = (x / 13) % 2 == 0
            val n = rnd() % 14
            var r = (if (stripe) 170 else 90) + n
            var g = (if (stripe) 120 else 140) + n
            var b = if (y > 120) 60 + n else 180 + n
            if (x in 100..159 && y in 70..124) { mask[y * w + x] = -1; r = 10; g = 250; b = 10 }
            px[y * w + x] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
        }
        return px to mask
    }

    /** 和 iOS 的 Inpaint.swift 在同一份数据上的结果几乎一样（浮点舍入会让个别点选到另一块）。 */
    @Test fun matchesIOS() {
        val (px, mask) = sample()
        val out = Inpaint.fill(px, mask, w, h)!!
        val expect = intArrayOf(
            98, 148, 188, 174, 124, 184, 179, 129, 189, 92, 142, 182, 179, 129, 189, 176, 126, 186, 96, 146, 186, 96, 146, 186, 178, 128, 188,
            102, 152, 192, 175, 125, 185, 145, 132, 185, 95, 145, 185, 178, 128, 188, 176, 126, 186, 97, 147, 187, 97, 147, 187, 174, 124, 184,
            93, 143, 183, 174, 124, 184, 99, 149, 189, 96, 146, 186, 177, 127, 187, 175, 125, 185, 95, 145, 185, 97, 147, 187, 178, 128, 188,
            92, 142, 182, 178, 128, 188, 97, 147, 187, 95, 145, 185, 178, 128, 188, 174, 124, 184, 100, 150, 190, 99, 143, 184, 178, 128, 188,
            100, 150, 190, 176, 126, 186, 95, 145, 185, 97, 147, 187, 178, 128, 188, 176, 126, 186, 95, 145, 185, 103, 147, 188, 177, 127, 187,
            93, 143, 183, 177, 127, 187, 96, 146, 186, 101, 151, 191, 178, 129, 189, 179, 129, 189, 96, 146, 186, 104, 147, 189, 172, 122, 182,
            98, 148, 188, 177, 127, 187, 92, 142, 182, 95, 145, 185, 161, 129, 141, 175, 125, 185, 90, 140, 180, 100, 143, 185, 177, 127, 187,
            98, 148, 188, 174, 124, 184, 176, 127, 67, 94, 144, 64, 174, 124, 64, 181, 131, 71, 102, 152, 73, 98, 146, 186, 174, 124, 184,
            97, 147, 67, 175, 125, 65, 181, 131, 71, 98, 148, 68, 174, 124, 64, 177, 127, 67, 96, 146, 66, 97, 147, 67, 173, 123, 67,
        )
        var k = 0
        var off = 0
        for (y in 72 until 125 step 6) for (x in 102 until 160 step 7) {
            val p = out[y * w + x]
            for (c in intArrayOf(p shr 16 and 255, p shr 8 and 255, p and 255)) if (abs(c - expect[k++]) > 4) off++
        }
        assertEquals(expect.size, k)
        assertTrue("差得多的有 $off / $k", off * 20 <= k)
    }

    /** 补出来的地方：绿的没了，条纹接得上，涂抹外面一个像素都不动。 */
    @Test fun fills() {
        val (px, mask) = sample()
        val out = Inpaint.fill(px, mask, w, h)!!
        var wrong = 0
        var n = 0
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * w + x
            if (mask[i].toInt() == 0) { assertEquals(px[i], out[i]); continue }
            n++
            val red = out[i] shr 16 and 255
            val stripe = (x / 13) % 2 == 0
            assertTrue((out[i] shr 8 and 255) < 200)
            if ((red > 140) != stripe) wrong++
        }
        assertTrue("条纹对不上的 $wrong / $n", wrong * 8 < n)
    }

    @Test fun edges() {
        val (px, _) = sample()
        assertArrayEquals(px, Inpaint.fill(px, ByteArray(w * h), w, h))
        // 到处都涂了：补不了
        assertNull(Inpaint.fill(px, ByteArray(w * h) { -1 }, w, h))
        // 贴着边的洞也能补
        val side = ByteArray(w * h) { if (it % w < 25 && it / w < 40) -1 else 0 }
        assertEquals(w * h, Inpaint.fill(px, side, w, h)!!.size)
    }

    /** 一笔的外接框：四周留余量，不出画面。 */
    @Test fun strokeBox() {
        val b = RetouchEngine.box(floatArrayOf(0.5f, 0.6f), floatArrayOf(0.5f, 0.5f), 0.02f, 1000, 800, 1f)
        // 宽 120、高 20（笔刷 20）：左右各留 122，上下各留 22
        assertArrayEquals(intArrayOf(368, 368, 732, 432), b)
        val c = RetouchEngine.box(floatArrayOf(0f), floatArrayOf(1f), 0.1f, 1000, 800, 0.2f)
        assertEquals(0, c[0])
        assertEquals(800, c[3])
    }

    /** 大一点的洞也要补得完（760 的一块、涂掉一小半）。 */
    @Test(timeout = 60_000) fun speed() {
        val side = 760
        val px = IntArray(side * side) { (0xFF shl 24) or ((it % side * 37 and 255) shl 16) or ((it / side * 11 and 255) shl 8) or (it * 7 and 255) }
        val mask = ByteArray(side * side) { if (it % side in 260..500 && it / side in 260..500) -1 else 0 }
        val t = System.currentTimeMillis()
        assertTrue(Inpaint.fill(px, mask, side, side) != null)
        println("760 一块用了 ${System.currentTimeMillis() - t} 毫秒")
    }
}
