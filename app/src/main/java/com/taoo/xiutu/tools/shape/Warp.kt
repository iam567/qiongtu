package com.taoo.xiutu.tools.shape

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * 位移场的一份快照：一张低分辨率网格，每格记"这里的画面要从哪边取"（取样点 - 当前位置），
 * 单位是输入图的长边，y 朝下。outW / outH 是输出画面的大小（单位坐标）。
 */
class WarpField(
    val width: Int,
    val height: Int,
    val dx: FloatArray,
    val dy: FloatArray,
    val outW: Float,
    val outH: Float,
    val maxOffset: Float,
)

/**
 * 按位移场取样（美体塑形、推拉共用，iOS ShapeEngine.warp / LiquifyGrid.warp）。
 * 网格放大后要抹平一格左右（iOS 是放大后高斯 0.8 格），这里先在网格上做一次小高斯，
 * 着色器里再用三次 B 样条取样，效果相当，直线边缘不会被推成一段段折线。
 * "背景保护 / 固定背景"：人单独变形，背景保持原样，人让出来的地方用补好的无人背景填。
 */
object Warp {
    /** 补背景、算"人的轮廓动过的地方"在多大的缩小版上做。 */
    private const val CTX_SIDE = 640
    private const val TILE = 2048

    /** 背景保护的准备（缩小版）：weight = 背景变形的权重，人身上是 1，出了人的轮廓平滑减到 0。 */
    class Plate(val weight: Bitmap)

    /** 抹平后的网格。 */
    private class Smoothed(val w: Int, val h: Int, val dx: FloatArray, val dy: FloatArray, val range: Float) {
        /** 单位坐标位移，pu / pv 是输出画面上的归一化位置（双线性，CPU 用）。 */
        fun sample(pu: Float, pv: Float, out: FloatArray) {
            val gx = (pu * w - 0.5f).coerceIn(0f, (w - 1).toFloat())
            val gy = (pv * h - 0.5f).coerceIn(0f, (h - 1).toFloat())
            val x0 = gx.toInt(); val y0 = gy.toInt()
            val x1 = min(x0 + 1, w - 1); val y1 = min(y0 + 1, h - 1)
            val fx = gx - x0; val fy = gy - y0
            fun lerp2(a: FloatArray): Float {
                val t = a[y0 * w + x0] + (a[y0 * w + x1] - a[y0 * w + x0]) * fx
                val b = a[y1 * w + x0] + (a[y1 * w + x1] - a[y1 * w + x0]) * fx
                return t + (b - t) * fy
            }
            out[0] = lerp2(dx); out[1] = lerp2(dy)
        }
    }

    private const val WARP_BODY = """
uniform sampler2D src;
uniform sampler2D grid;
uniform vec2 src_size;
uniform vec2 gdim;
uniform float range;
uniform float scale;
uniform vec2 outFull;
uniform vec2 inFull;
uniform vec2 orig;
uniform vec2 inOrig;
#ifdef LOCK
uniform sampler2D person;
#ifdef AIFILL
uniform sampler2D changed;
uniform sampler2D aiplate;
#else
uniform sampler2D weight;
#endif
#endif
// 网格存成 16 位：上半张 x，下半张 y。
float dec(vec4 t) {
    return ((floor(t.r * 255.0 + 0.5) * 256.0 + floor(t.g * 255.0 + 0.5)) / 65535.0 * 2.0 - 1.0) * range;
}
vec2 cellAt(ivec2 c) {
    ivec2 m = ivec2(gdim) - 1;
    c = clamp(c, ivec2(0), m);
    return vec2(dec(texelFetch(grid, c, 0)), dec(texelFetch(grid, ivec2(c.x, c.y + m.y + 1), 0)));
}
vec4 bspline(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    float s = 1.0 - t;
    return vec4(s * s * s, 3.0 * t3 - 6.0 * t2 + 4.0, -3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0, t3) / 6.0;
}
vec2 offsetAt(vec2 pix) {
    vec2 g = pix / outFull * gdim - 0.5;
    vec2 f = floor(g);
    vec2 t = g - f;
    vec4 wx = bspline(t.x);
    vec4 wy = bspline(t.y);
    ivec2 b = ivec2(f) - 1;
    vec2 acc = vec2(0.0);
    for (int j = 0; j < 4; j++) {
        vec2 row = wx.x * cellAt(b + ivec2(0, j)) + wx.y * cellAt(b + ivec2(1, j))
                 + wx.z * cellAt(b + ivec2(2, j)) + wx.w * cellAt(b + ivec2(3, j));
        acc += wy[j] * row;
    }
    return acc;
}
// 按整张输入图的像素坐标取样（边缘外延）。
vec4 at(vec2 pix) {
    pix = clamp(pix, vec2(0.5), inFull - 0.5);
    return texture(src, (pix - inOrig) / src_size);
}
void main() {
    vec2 pix = orig + uv * size;
    vec2 off = offsetAt(pix) * scale;
    vec2 sp = pix + off;
    vec4 warped = at(sp);
#ifdef LOCK
    float moved = texture(person, clamp(sp, vec2(0.5), inFull - 0.5) / inFull).r;
    vec2 u = pix / inFull;
#ifdef AIFILL
    // AI 补背景：人的轮廓动过的地方换成 AI 补好的背景，其余地方一个像素都不动。
    float ch = texture(changed, u).r;
    vec4 behind = mix(at(pix), texture(aiplate, u), ch);
#else
    // 背景：人身上和人让出来的缝里照常变形（缝里是旁边拉过来的背景，纹理清楚），
    // 出了人的轮廓，变形平滑地减到零。背景是连续的一整张，不会出现两张图叠在一起的重影。
    float w = texture(weight, u).r;
    vec4 behind = at(pix + off * w);
#endif
    o = mix(behind, warped, moved);
#else
    o = warped;
#endif
}
"""

    private val WARP = Shaders.HEADER + WARP_BODY
    private val WARP_LOCK = Shaders.HEADER.replaceFirst("#version 300 es\n", "#version 300 es\n#define LOCK\n") + WARP_BODY
    private val WARP_AIFILL = Shaders.HEADER.replaceFirst("#version 300 es\n", "#version 300 es\n#define LOCK\n#define AIFILL\n") + WARP_BODY

    /**
     * 按位移场取样。mask 不为空、而且画布大小没变时做背景保护（mask 白 = 人，任意尺寸）。
     * plate 是提前算好的背景变形权重（实时预览用），不传就现算；aiPlate 是 AI 补好的无人背景（整张图），
     * 有它时人让出来的地方直接用它。后台线程调用。
     */
    fun render(src: Bitmap, field: WarpField, mask: Bitmap? = null, plate: Plate? = null, aiPlate: Bitmap? = null): Bitmap {
        val w = src.width
        val h = src.height
        val scale = max(w, h).toFloat()
        val ow = max(1, (field.outW * scale).roundToInt())
        val oh = max(1, (field.outH * scale).roundToInt())
        val sm = smooth(field)
        val gridBmp = encode(sm)
        val lock = mask != null && ow == w && oh == h
        var changedBmp: Bitmap? = null
        var plateUsed: Plate? = null
        if (lock && mask != null) {
            if (aiPlate != null) changedBmp = changedMask(sm, mask, w, h) else plateUsed = plate ?: plate(src, mask)
        }
        val frag = when {
            !lock -> WARP
            aiPlate != null -> WARP_AIFILL
            else -> WARP_LOCK
        }
        val cellPx = max(ow, oh).toFloat() / max(sm.w, sm.h)
        val reach = ceil(sm.range * scale + cellPx * 3 + 4).toInt()

        fun uniforms(ox: Int, oy: Int, ix: Int, iy: Int): Map<String, Any> = mapOf(
            "gdim" to floatArrayOf(sm.w.toFloat(), sm.h.toFloat()),
            "range" to sm.range,
            "scale" to scale,
            "outFull" to floatArrayOf(ow.toFloat(), oh.toFloat()),
            "inFull" to floatArrayOf(w.toFloat(), h.toFloat()),
            "orig" to floatArrayOf(ox.toFloat(), oy.toFloat()),
            "inOrig" to floatArrayOf(ix.toFloat(), iy.toFloat()),
        )

        return Gpu.run {
            val grid = upload(gridBmp)
            val extra = HashMap<String, Tex>()
            if (lock && mask != null) {
                extra["person"] = upload(mask)
                if (aiPlate != null && changedBmp != null) {
                    extra["changed"] = upload(changedBmp)
                    extra["aiplate"] = upload(aiPlate)
                } else if (plateUsed != null) {
                    extra["weight"] = upload(plateUsed.weight)
                }
            }
            val limit = min(Gpu.maxTextureSize, 4096)
            if (max(max(w, h), max(ow, oh)) <= limit) {
                val t = upload(src)
                return@run read(pass(frag, linkedMapOf("src" to t, "grid" to grid) + extra, uniforms(0, 0, 0, 0), ow, oh))
            }
            // 大图分块：每块输出要用到的输入范围 = 这一块外扩最大位移
            val core = min(TILE, Gpu.maxTextureSize - 2 * reach - 2).coerceAtLeast(256)
            val out = Bitmap.createBitmap(ow, oh, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(out)
            val nx = ceil(ow / core.toFloat()).toInt()
            val ny = ceil(oh / core.toFloat()).toInt()
            for (ty in 0 until ny) for (tx in 0 until nx) {
                val x0 = tx * core
                val y0 = ty * core
                val cw = min(core, ow - x0)
                val ch = min(core, oh - y0)
                val ix0 = (x0 - reach).coerceIn(0, w - 1)
                val iy0 = (y0 - reach).coerceIn(0, h - 1)
                val ix1 = (x0 + cw + reach).coerceIn(ix0 + 1, w)
                val iy1 = (y0 + ch + reach).coerceIn(iy0 + 1, h)
                val sub = Bitmap.createBitmap(src, ix0, iy0, ix1 - ix0, iy1 - iy0)
                val piece = Gpu.run {
                    val t = upload(sub)
                    read(pass(frag, linkedMapOf("src" to t, "grid" to grid) + extra, uniforms(x0, y0, ix0, iy0), cw, ch))
                }
                canvas.drawBitmap(piece, null, Rect(x0, y0, x0 + cw, y0 + ch), null)
                if (sub !== src) sub.recycle()
                piece.recycle()
            }
            out
        }
    }

    // MARK: 网格

    /** 网格先抹平一点（iOS 放大后高斯 0.8 格；三次 B 样条本身相当于 0.58 格，这里补上剩下的）。 */
    private fun smooth(f: WarpField): Smoothed {
        val dx = f.dx.copyOf()
        val dy = f.dy.copyOf()
        gaussSmall(dx, f.width, f.height, 0.69f)
        gaussSmall(dy, f.width, f.height, 0.69f)
        var peak = 0f
        for (i in dx.indices) peak = max(peak, max(abs(dx[i]), abs(dy[i])))
        return Smoothed(f.width, f.height, dx, dy, max(peak * 1.001f, 1e-5f))
    }

    /** 编码成 16 位：宽 w、高 2h，上半张 x 位移，下半张 y 位移；R 高 8 位、G 低 8 位，A 不透明（免得预乘丢数据）。 */
    private fun encode(s: Smoothed): Bitmap {
        val px = IntArray(s.w * s.h * 2)
        fun q(v: Float): Int = ((v / s.range * 0.5f + 0.5f).coerceIn(0f, 1f) * 65535f).roundToInt()
        for (i in 0 until s.w * s.h) {
            val a = q(s.dx[i])
            val b = q(s.dy[i])
            px[i] = (0xFF shl 24) or ((a shr 8) shl 16) or ((a and 0xFF) shl 8)
            px[i + s.w * s.h] = (0xFF shl 24) or ((b shr 8) shl 16) or ((b and 0xFF) shl 8)
        }
        return Bitmap.createBitmap(px, s.w, s.h * 2, Bitmap.Config.ARGB_8888)
    }

    // MARK: 背景保护

    private fun ctxSize(w: Int, h: Int): Pair<Int, Int> {
        val long = max(w, h)
        val side = min(CTX_SIDE, long)
        val k = side.toFloat() / long
        return max(1, (w * k).roundToInt()) to max(1, (h * k).roundToInt())
    }

    /** 蒙版缩到 (cw, ch)，取红色通道，0...1。 */
    private fun maskPlane(mask: Bitmap, cw: Int, ch: Int): FloatArray {
        val m = Img.scaled(Img.soft(Img.downscale(mask, max(cw, ch) * 2)), cw, ch)
        val px = IntArray(cw * ch)
        m.getPixels(px, 0, cw, 0, 0, cw, ch)
        return FloatArray(px.size) { ((px[it] shr 16) and 0xFF) / 255f }
    }

    private fun grayBitmap(a: FloatArray, w: Int, h: Int): Bitmap {
        val px = IntArray(w * h) {
            val v = (a[it].coerceIn(0f, 1f) * 255f + 0.5f).toInt()
            (0xFF shl 24) or (v shl 16) or (v shl 8) or v
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    /**
     * 背景变形的权重：人身上（包括人让出来的缝）一定是 1，缝里才不会残留人的边；
     * 外面一圈（人像外扩 1.2%、再羽化 1%）平滑减到 0，背景离人远的地方一个像素都不动。
     */
    fun plate(image: Bitmap, mask: Bitmap): Plate {
        val (cw, ch) = ctxSize(image.width, image.height)
        val long = max(cw, ch).toFloat()
        val person = maskPlane(mask, cw, ch)
        val falloff = person.copyOf()
        dilate(falloff, cw, ch, (long * 0.012f).roundToInt())
        gaussBox(falloff, cw, ch, long * 0.01f)
        for (i in person.indices) falloff[i] = max(falloff[i], person[i])
        return Plate(grayBitmap(falloff, cw, ch))
    }

    /** 人的轮廓动过的地方：|人 - 变形后的人|，外扩 1%、羽化 0.5%、放大 2.5 倍。 */
    private fun changedMask(sm: Smoothed, mask: Bitmap, w: Int, h: Int): Bitmap {
        val (cw, ch) = ctxSize(w, h)
        val long = max(cw, ch).toFloat()
        val person = maskPlane(mask, cw, ch)
        val out = FloatArray(cw * ch)
        val off = FloatArray(2)
        // 位移单位是长边；缩小版里一个长边 = long 像素
        for (j in 0 until ch) {
            val v = (j + 0.5f) / ch
            for (i in 0 until cw) {
                val u = (i + 0.5f) / cw
                sm.sample(u, v, off)
                val sx = (i + 0.5f + off[0] * long - 0.5f).coerceIn(0f, (cw - 1).toFloat())
                val sy = (j + 0.5f + off[1] * long - 0.5f).coerceIn(0f, (ch - 1).toFloat())
                val x0 = sx.toInt(); val y0 = sy.toInt()
                val x1 = min(x0 + 1, cw - 1); val y1 = min(y0 + 1, ch - 1)
                val fx = sx - x0; val fy = sy - y0
                val top = person[y0 * cw + x0] + (person[y0 * cw + x1] - person[y0 * cw + x0]) * fx
                val bot = person[y1 * cw + x0] + (person[y1 * cw + x1] - person[y1 * cw + x0]) * fx
                val moved = top + (bot - top) * fy
                out[j * cw + i] = abs(person[j * cw + i] - moved)
            }
        }
        dilate(out, cw, ch, (long * 0.01f).roundToInt())
        gaussBox(out, cw, ch, long * 0.005f)
        for (i in out.indices) out[i] = (out[i] * 2.5f).coerceIn(0f, 1f)
        return grayBitmap(out, cw, ch)
    }

    // MARK: CPU 小工具

    /** 小半径高斯（直接卷积，边缘外延）。 */
    private fun gaussSmall(a: FloatArray, w: Int, h: Int, sigma: Float) {
        val r = ceil(sigma * 3).toInt().coerceAtLeast(1)
        val k = FloatArray(2 * r + 1) { exp(-((it - r) * (it - r)) / (2 * sigma * sigma)) }
        val sum = k.sum()
        for (i in k.indices) k[i] /= sum
        val tmp = FloatArray(a.size)
        for (y in 0 until h) for (x in 0 until w) {
            var acc = 0f
            for (t in -r..r) acc += a[y * w + (x + t).coerceIn(0, w - 1)] * k[t + r]
            tmp[y * w + x] = acc
        }
        for (y in 0 until h) for (x in 0 until w) {
            var acc = 0f
            for (t in -r..r) acc += tmp[(y + t).coerceIn(0, h - 1) * w + x] * k[t + r]
            a[y * w + x] = acc
        }
    }

    /** 大半径高斯：三次方框模糊近似（边缘外延），和半径无关的速度。 */
    private fun gaussBox(a: FloatArray, w: Int, h: Int, sigma: Float) {
        if (sigma < 0.4f) return
        if (sigma < 2f) { gaussSmall(a, w, h, sigma); return }
        val n = 3
        val ideal = sqrt(12 * sigma * sigma / n + 1)
        var wl = floor(ideal).toInt()
        if (wl % 2 == 0) wl--
        val wu = wl + 2
        val mIdeal = (12 * sigma * sigma - n * wl * wl - 4 * n * wl - 3 * n) / (-4f * wl - 4)
        val m = mIdeal.roundToInt()
        val tmp = FloatArray(a.size)
        for (pass in 0 until n) {
            val r = ((if (pass < m) wl else wu) - 1) / 2
            boxLine(a, tmp, w, h, r, true)
            boxLine(tmp, a, w, h, r, false)
        }
    }

    private fun boxLine(src: FloatArray, dst: FloatArray, w: Int, h: Int, r: Int, horizontal: Boolean) {
        val len = if (horizontal) w else h
        val lines = if (horizontal) h else w
        val inv = 1f / (2 * r + 1)
        for (l in 0 until lines) {
            fun idx(i: Int): Int { val c = i.coerceIn(0, len - 1); return if (horizontal) l * w + c else c * w + l }
            var acc = 0f
            for (i in -r..r) acc += src[idx(i)]
            for (i in 0 until len) {
                dst[idx(i)] = acc * inv
                acc += src[idx(i + r + 1)] - src[idx(i - r)]
            }
        }
    }

    /** 取最大值（方形近似 iOS 的圆形最大值滤镜），边缘外延。 */
    private fun dilate(a: FloatArray, w: Int, h: Int, r: Int) {
        if (r <= 0) return
        val tmp = FloatArray(a.size)
        for (y in 0 until h) for (x in 0 until w) {
            var m = 0f
            for (t in max(0, x - r)..min(w - 1, x + r)) m = max(m, a[y * w + t])
            tmp[y * w + x] = m
        }
        for (y in 0 until h) for (x in 0 until w) {
            var m = 0f
            for (t in max(0, y - r)..min(h - 1, y + r)) m = max(m, tmp[t * w + x])
            a[y * w + x] = m
        }
    }
}
