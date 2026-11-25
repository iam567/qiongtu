package com.taoo.xiutu.ml

import android.graphics.Bitmap
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 一张 8 位的灰度图（蒙版、覆盖图），一行一行从上到下。 */
class Mask8(val pixels: ByteArray, val w: Int, val h: Int) {
    operator fun get(i: Int): Int = pixels[i].toInt() and 0xFF

    /** 转成 ALPHA_8 位图：画的时候用 Paint 的颜色填。 */
    fun toAlphaBitmap(): Bitmap {
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ALPHA_8)
        val row = b.rowBytes
        if (row == w) {
            b.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
        } else {
            val padded = ByteArray(row * h)
            for (y in 0 until h) System.arraycopy(pixels, y * w, padded, y * row, w)
            b.copyPixelsFromBuffer(ByteBuffer.wrap(padded))
        }
        return b
    }

    /** 转成不透明的灰度位图（白 = 255）。 */
    fun toGrayBitmap(): Bitmap {
        val px = IntArray(w * h) { val v = this[it]; (0xFF shl 24) or (v shl 16) or (v shl 8) or v }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    fun copy() = Mask8(pixels.copyOf(), w, h)

    companion object {
        /** 取位图的透明通道。 */
        fun alphaOf(b: Bitmap): Mask8 {
            val a = b.extractAlpha()
            val row = a.rowBytes
            val buf = ByteBuffer.allocate(row * a.height)
            a.copyPixelsToBuffer(buf)
            val raw = buf.array()
            val w = a.width
            val h = a.height
            a.recycle()
            if (row == w) return Mask8(raw, w, h)
            val out = ByteArray(w * h)
            for (y in 0 until h) System.arraycopy(raw, y * row, out, y * w, w)
            return Mask8(out, w, h)
        }

        /** 灰度图（取红色通道）。 */
        fun grayOf(b: Bitmap): Mask8 {
            val px = IntArray(b.width * b.height)
            b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
            return Mask8(ByteArray(px.size) { ((px[it] shr 16) and 0xFF).toByte() }, b.width, b.height)
        }

        /** 把每个像素的值按 f 换算一遍（查表）。 */
        fun remap(m: Mask8, f: (Int) -> Int) {
            val table = ByteArray(256) { f(it).coerceIn(0, 255).toByte() }
            val p = m.pixels
            for (i in p.indices) p[i] = table[p[i].toInt() and 0xFF]
        }

        /** 缩放到指定大小：缩小按面积平均，放大用双线性。 */
        fun resized(m: Mask8, w: Int, h: Int): Mask8 {
            if (m.w == w && m.h == h) return m
            val out = ByteArray(w * h)
            if (w <= m.w && h <= m.h) {
                val sx = m.w.toFloat() / w
                val sy = m.h.toFloat() / h
                for (y in 0 until h) {
                    val y0 = (y * sy).toInt()
                    val y1 = max(y0 + 1, min(m.h, ((y + 1) * sy).roundToInt()))
                    for (x in 0 until w) {
                        val x0 = (x * sx).toInt()
                        val x1 = max(x0 + 1, min(m.w, ((x + 1) * sx).roundToInt()))
                        var sum = 0
                        for (yy in y0 until y1) {
                            val row = yy * m.w
                            for (xx in x0 until x1) sum += m.pixels[row + xx].toInt() and 0xFF
                        }
                        out[y * w + x] = (sum / ((y1 - y0) * (x1 - x0))).toByte()
                    }
                }
            } else {
                val sx = m.w.toFloat() / w
                val sy = m.h.toFloat() / h
                for (y in 0 until h) {
                    val fy = ((y + 0.5f) * sy - 0.5f).coerceIn(0f, (m.h - 1).toFloat())
                    val y0 = fy.toInt()
                    val y1 = min(y0 + 1, m.h - 1)
                    val ty = fy - y0
                    for (x in 0 until w) {
                        val fx = ((x + 0.5f) * sx - 0.5f).coerceIn(0f, (m.w - 1).toFloat())
                        val x0 = fx.toInt()
                        val x1 = min(x0 + 1, m.w - 1)
                        val tx = fx - x0
                        val a = m[y0 * m.w + x0]
                        val b = m[y0 * m.w + x1]
                        val c = m[y1 * m.w + x0]
                        val d = m[y1 * m.w + x1]
                        val top = a + (b - a) * tx
                        val bot = c + (d - c) * tx
                        out[y * w + x] = (top + (bot - top) * ty + 0.5f).toInt().toByte()
                    }
                }
            }
            return Mask8(out, w, h)
        }

        /** 近似高斯的模糊（四次方框模糊），耗时和半径无关。原地修改。 */
        fun blur(m: Mask8, radius: Float) {
            val r = max(1, radius.roundToInt())
            if (r < 1 || m.w <= 0 || m.h <= 0) return
            val b = max(1, (r / 2f).roundToInt())
            val buf = IntArray(m.w * m.h) { m[it] }
            val tmp = IntArray(max(m.w, m.h))
            repeat(4) {
                boxPass(buf, m.w, m.h, b, horizontal = true, tmp)
                boxPass(buf, m.w, m.h, b, horizontal = false, tmp)
            }
            for (i in buf.indices) m.pixels[i] = buf[i].coerceIn(0, 255).toByte()
        }

        /** 同上，按标准差给（四次方框模糊合起来 σ ≈ 0.577 × 半径）。原地修改。 */
        fun gaussian(m: Mask8, sigma: Float) = blur(m, max(1f, sigma * 1.732f - 1f))

        private fun boxPass(buf: IntArray, w: Int, h: Int, r: Int, horizontal: Boolean, tmp: IntArray) {
            val n = if (horizontal) w else h
            val lines = if (horizontal) h else w
            val stride = if (horizontal) 1 else w
            val size = 2 * r + 1
            for (line in 0 until lines) {
                val base = if (horizontal) line * w else line
                // 边缘外的像素按最边上的值算
                var sum = 0
                for (k in -r..r) sum += buf[base + k.coerceIn(0, n - 1) * stride]
                for (i in 0 until n) {
                    tmp[i] = (sum + size / 2) / size
                    val add = (i + r + 1).coerceAtMost(n - 1)
                    val sub = (i - r).coerceAtLeast(0)
                    sum += buf[base + add * stride] - buf[base + sub * stride]
                }
                for (i in 0 until n) buf[base + i * stride] = tmp[i]
            }
        }

        /** 模糊一张覆盖图。半径大的时候先缩小再模糊，大图上也很快。返回的图可能比原图小。 */
        fun softened(m: Mask8, radius: Float): Mask8 {
            val factor = min(8, max(1, (radius / 6f).toInt()))
            if (factor <= 1) {
                val c = m.copy()
                blur(c, radius)
                return c
            }
            val sw = max(1, m.w / factor)
            val sh = max(1, m.h / factor)
            val small = resized(m, sw, sh).let { if (it === m) it.copy() else it }
            blur(small, radius * sw / m.w)
            return small
        }
    }
}
