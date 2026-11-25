package com.taoo.xiutu.batch

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class StyleLUTTest {
    /** 和 iOS 那边验证用的小程序同一套数据。 */
    private fun sample(w: Int, h: Int): Pair<FloatArray, FloatArray> {
        val a = FloatArray(w * h * 3)
        val b = FloatArray(w * h * 3)
        var seed = 12345
        fun rnd(): Float { seed = seed * 1103515245 + 12345; return (seed ushr 16 and 255) / 255f }
        var i = 0
        for (y in 0 until h) for (x in 0 until w) {
            val n = rnd() * 0.06f
            val r = ((x.toFloat() / w * 0.8f + n) * 255).toInt() / 255f
            val g = ((y.toFloat() / h * 0.7f + 0.1f + n) * 255).toInt() / 255f
            val bl = ((x + y).toFloat() / (w + h) * 0.9f * 255).toInt() / 255f
            a[i] = r; a[i + 1] = g; a[i + 2] = bl
            b[i] = min(1f, r * 0.9f + 0.08f); b[i + 1] = g * g * 0.5f + g * 0.5f; b[i + 2] = max(0f, bl * 0.8f + 0.02f)
            i += 3
        }
        return a to b
    }

    /** 期望值是 iOS 的 StyleLUT.swift 在同一份数据上算出来的。 */
    @Test fun matchesIOS() {
        val (a, b) = sample(120, 90)
        val cube = StyleLUT.fit(a, b, 120, 90)!!
        val expect = mapOf(
            0 to floatArrayOf(0.07000999f, 0f, 0.0055068773f), 1000 to floatArrayOf(0.07048586f, 0.5137513f, 0.006505899f),
            5000 to floatArrayOf(0.0648261f, 0f, 0.3264837f), 7812 to floatArrayOf(0.53013265f, 0.37579495f, 0.4194124f),
            9999 to floatArrayOf(1f, 0.9182652f, 0.482313f), 12345 to floatArrayOf(0.8340346f, 0.65435266f, 0.6504562f),
            15624 to floatArrayOf(1f, 0.92085713f, 0.8506956f),
        )
        for ((i, v) in expect) for (c in 0..2) assertEquals("格子 $i", v[c], cube[i * 3 + c], 2e-4f)
    }

    /** 套回去之后和 AI 图接近。 */
    @Test fun reproducesGrade() {
        val (a, b) = sample(120, 90)
        val cube = StyleLUT.fit(a, b, 120, 90)!!
        var sum = 0.0
        for (i in 0 until a.size / 3) {
            val o = StyleLUT.map(cube, a[i * 3], a[i * 3 + 1], a[i * 3 + 2])
            for (c in 0..2) sum += abs(o[c] - b[i * 3 + c])
        }
        assertTrue("平均差 ${sum / a.size}", sum / a.size < 0.01)
    }

    /** 没变的图得到的是不变的对照表。 */
    @Test fun identity() {
        val (a, _) = sample(120, 90)
        val cube = StyleLUT.fit(a, a, 120, 90)
        assertNotNull(cube)
        val o = StyleLUT.map(cube!!, 0.3f, 0.6f, 0.9f)
        assertEquals(0.3f, o[0], 1e-3f)
        assertEquals(0.6f, o[1], 1e-3f)
        assertEquals(0.9f, o[2], 1e-3f)
    }
}
