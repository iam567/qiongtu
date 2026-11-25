package com.taoo.xiutu.ai

import android.graphics.Bitmap
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.ml.Mask8
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * AI 改完的图，只在真正变了的地方用 AI 的像素，其余用原图的：
 * 没动的地方保持原来的清晰度和质感，不会整张都是 AI 重画出来的涂抹感。
 */
object ChangeKeep {
    /**
     * original、ai 一样大。area：只允许在这一块里换（白 = 允许），不给就整张都可以。
     * core：这一块一定用 AI 的（换衣服）。fine：变化看得更细，一两根飘着的发丝也算变了（换发型）。
     */
    fun apply(g: GpuScope, original: Tex, ai: Tex, area: Tex?, core: Tex? = null, fine: Boolean = false): Tex {
        val w = original.width
        val h = original.height
        val long = max(w, h).toFloat()
        // AI 常把整张的明暗颜色带偏一点：先按大范围拉回原图的样子，再比较、再贴。
        val toned = if ((core != null || fine) && area != null) tonedByOutside(g, ai, original, area)
        else ToneTransfer.apply(g, ai, original, radius = long * 0.05f)
        val sigma = long * (if (fine) 0.0016f else 0.0028f)
        // 蒙版本来就要羽化：在最长 1600 的小图上算，预览和导出一致，也快。
        val k = min(1f, MASK_SIDE / long)
        val mw = max(1, (w * k).roundToInt())
        val mh = max(1, (h * k).roundToInt())
        val ml = long * k
        val bo = g.blur(original, sigma * 2.5f)
        val bt = g.blur(toned, sigma * 2.5f)
        val diff = g.pass(if (fine) DIFF_FINE else DIFF, mapOf("src" to bo, "fg" to bt), width = mw, height = mh)
        if (bo !== original) g.release(bo)
        if (bt !== toned) g.release(bt)
        // 去掉零星的小点，再往外扩一点、羽化，接缝落在没变的地方。
        var mask = if (fine) diff else morphology(g, diff, ml * 0.0012f, grow = false)
        mask = morphology(g, mask, ml * 0.009f, grow = true)
        mask = g.blur(mask, ml * 0.005f * 2.5f)
        if (core != null) mask = g.pass(MAX, mapOf("src" to mask, "fg" to core), width = mw, height = mh)
        val out = blend(g, original, toned, mask, area)
        g.release(toned)
        return out
    }

    /**
     * 只看 area 外面（背景）的色差来校正 AI 图：换衣服时人身上的颜色本来就要变，不能拿来比。
     * 半径很大，在最长 800 的浮点小图上算。
     */
    private fun tonedByOutside(g: GpuScope, ai: Tex, original: Tex, area: Tex): Tex {
        val k = min(1f, 800f / max(ai.width, ai.height))
        val w = max(1, (ai.width * k).roundToInt())
        val h = max(1, (ai.height * k).roundToInt())
        fun weighted(t: Tex) = g.blur(g.passFloat(OUTSIDE, mapOf("src" to t, "area" to area), width = w, height = h), max(w, h) * 0.12f * 2.5f)
        return g.pass(OUTSIDE_GAIN, mapOf("src" to ai, "o0" to weighted(original), "a0" to weighted(ai)), width = ai.width, height = ai.height)
    }

    /** 蒙版白的地方用 fg（线性光里混合，和 Core Image 一致）；area 不为空时再乘上它。 */
    fun blend(g: GpuScope, src: Tex, fg: Tex, mask: Tex, area: Tex? = null): Tex = g.pass(
        BLEND, mapOf("src" to src, "fg" to fg, "mask" to mask, "area" to (area ?: mask)),
        mapOf("useArea" to if (area != null) 1 else 0), src.width, src.height,
    )

    /** 取附近最大 / 最小的值（先横后竖）。 */
    fun morphology(g: GpuScope, src: Tex, radius: Float, grow: Boolean): Tex {
        val n = max(1, radius.roundToInt())
        fun go(t: Tex, dx: Float, dy: Float) = g.pass(
            MORPH, mapOf("src" to t), mapOf("dir" to floatArrayOf(dx, dy), "n" to n, "grow" to if (grow) 1 else 0), t.width, t.height,
        )
        return go(go(src, 1f, 0f), 0f, 1f)
    }

    private const val MASK_SIDE = 1600f

    private const val DIFF = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
uniform sampler2D fg;
void main() {
    vec3 d = abs(toLin(texture(src, uv).rgb) - toLin(texture(fg, uv).rgb));
    float v = max(d.r, max(d.g, d.b));
    float m = smoothstep(0.045, 0.12, v);
    o = vec4(m, m, m, 1.0);
}
"""

    private const val DIFF_FINE = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D fg;
void main() {
    vec3 d = abs(texture(src, uv).rgb - texture(fg, uv).rgb);
    float v = max(d.r, max(d.g, d.b));
    float m = smoothstep(0.03, 0.08, v);
    o = vec4(m, m, m, 1.0);
}
"""

    private const val MORPH = Shaders.HEADER + """
uniform sampler2D src;
uniform vec2 dir;
uniform int n;
uniform int grow;
void main() {
    vec2 px = dir / src_size;
    float v = texture(src, uv).r;
    for (int i = 1; i <= 48; i++) {
        if (i > n) break;
        float a = texture(src, uv + px * float(i)).r;
        float b = texture(src, uv - px * float(i)).r;
        v = grow == 1 ? max(v, max(a, b)) : min(v, min(a, b));
    }
    o = vec4(v, v, v, 1.0);
}
"""

    private const val BLEND = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
uniform sampler2D fg;
uniform sampler2D mask;
uniform sampler2D area;
uniform int useArea;
void main() {
    vec4 a = texture(src, uv);
    vec4 b = texture(fg, uv);
    float m = texture(mask, uv).r;
    if (useArea == 1) m *= texture(area, uv).r;
    o = vec4(toSrgb(mix(toLin(a.rgb), toLin(b.rgb), m)), mix(a.a, b.a, m));
}
"""

    private const val MAX = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D fg;
void main() { o = vec4(vec3(max(texture(src, uv).r, texture(fg, uv).r)), 1.0); }
"""

    private const val OUTSIDE = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
uniform sampler2D area;
void main() { o = vec4(toLin(texture(src, uv).rgb) * (1.0 - texture(area, uv).r), 1.0); }
"""

    private const val OUTSIDE_GAIN = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
uniform sampler2D o0;
uniform sampler2D a0;
void main() {
    vec4 s = texture(src, uv);
    vec3 e = vec3(0.004);
    vec3 gain = clamp((texture(o0, uv).rgb + e) / (texture(a0, uv).rgb + e), vec3(0.6), vec3(1.7));
    o = vec4(toSrgb(toLin(s.rgb) * gain), s.a);
}
"""

    // MARK: 对齐

    /**
     * AI 图相对原图整体偏了多少（占宽高的比例）：返回要把 AI 图挪多少才能和原图对齐，原点左上。
     * 偏得太多就不管（说明不是简单的平移）。iOS 用 Vision，这里先在 256 的小图上找一遍，再到 768 上细调。
     */
    fun shift(original: Bitmap, ai: Bitmap): Pair<Float, Float> {
        val coarse = gray(original, ai, 256f)
        val fine = gray(original, ai, 768f)
        return shift(coarse, fine)
    }

    internal class Pair8(val a: FloatArray, val b: FloatArray, val w: Int, val h: Int)

    private fun gray(original: Bitmap, ai: Bitmap, side: Float): Pair8 {
        val k = side / max(original.width, original.height)
        val w = max(1, (original.width * k).toInt())
        val h = max(1, (original.height * k).toInt())
        fun luma(b: Bitmap): FloatArray {
            val s = Img.scaled(Img.downscale(Img.soft(b), max(w, h)), w, h)
            val px = IntArray(w * h)
            s.getPixels(px, 0, w, 0, 0, w, h)
            return FloatArray(px.size) { val p = px[it]; ((p shr 16 and 255) * 0.299f + (p shr 8 and 255) * 0.587f + (p and 255) * 0.114f) }
        }
        return Pair8(luma(original), luma(ai), w, h)
    }

    internal fun shift(coarse: Pair8, fine: Pair8): Pair<Float, Float> {
        val limit = 0.02f
        val cx = (coarse.w * limit).toInt() + 1
        val cy = (coarse.h * limit).toInt() + 1
        val (x0, y0) = search(coarse, -cx..cx, -cy..cy)
        val fx = (x0.toFloat() * fine.w / coarse.w).roundToInt()
        val fy = (y0.toFloat() * fine.h / coarse.h).roundToInt()
        val (x1, y1) = search(fine, fx - 3..fx + 3, fy - 3..fy + 3)
        val best = sad(fine, x1, y1)
        // 挪了也没明显更好（画面很平、或者本来就对齐）：不挪。
        if (best > sad(fine, 0, 0) * 0.99f) return 0f to 0f
        fun sub(l: Float, r: Float): Float {
            val d = l - 2 * best + r
            return if (d > 1e-6f) (0.5f * (l - r) / d).coerceIn(-0.5f, 0.5f) else 0f
        }
        val dx = (x1 + sub(sad(fine, x1 - 1, y1), sad(fine, x1 + 1, y1))) / fine.w
        val dy = (y1 + sub(sad(fine, x1, y1 - 1), sad(fine, x1, y1 + 1))) / fine.h
        return if (abs(dx) < limit && abs(dy) < limit) dx to dy else 0f to 0f
    }

    private fun search(p: Pair8, xs: IntRange, ys: IntRange): Pair<Int, Int> {
        var best = Float.MAX_VALUE
        var out = 0 to 0
        for (y in ys) for (x in xs) {
            val v = sad(p, x, y)
            if (v < best) { best = v; out = x to y }
        }
        return out
    }

    /** b 挪 (dx, dy) 之后和 a 重叠部分的平均差（去掉整体明暗差）。 */
    private fun sad(p: Pair8, dx: Int, dy: Int): Float {
        val w = p.w
        val h = p.h
        val x0 = max(0, dx); val x1 = min(w, w + dx)
        val y0 = max(0, dy); val y1 = min(h, h + dy)
        if (x1 - x0 < 8 || y1 - y0 < 8) return Float.MAX_VALUE
        val step = if (w * h > 120_000) 2 else 1
        var sum = 0.0
        var n = 0
        for (y in y0 until y1 step step) {
            var i = y * w + x0
            var j = (y - dy) * w + x0 - dx
            var row = 0f
            for (x in x0 until x1) { row += p.a[i] - p.b[j]; i++; j++ }
            sum += row
            n += x1 - x0
        }
        val mean = (sum / n).toFloat()
        var total = 0.0
        for (y in y0 until y1 step step) {
            var i = y * w + x0
            var j = (y - dy) * w + x0 - dx
            var row = 0f
            for (x in x0 until x1) { row += abs(p.a[i] - p.b[j] - mean); i++; j++ }
            total += row
        }
        return (total / n).toFloat()
    }

    // MARK: 范围

    /** 两个范围的交集；b 缩放到 a 的大小。 */
    fun intersect(a: Mask8?, b: Mask8): Mask8 {
        if (a == null) return b
        val f = Mask8.resized(b, a.w, a.h)
        return Mask8(ByteArray(a.w * a.h) { (a[it] * f[it] / 255).toByte() }, a.w, a.h)
    }

    /** 人和人周围一圈（原图里的人和 AI 图里的人合起来，往外扩一点）。 */
    fun personArea(a: Mask8?, b: Mask8?, width: Int, height: Int, grow: Int = 22, blur: Float = 8f): Mask8? {
        val masks = listOfNotNull(a, b)
        if (masks.isEmpty()) return null
        val k = 640f / max(width, height)
        val w = max(1, (width * k).toInt())
        val h = max(1, (height * k).toInt())
        var out = ByteArray(w * h)
        for (m in masks) {
            val s = Mask8.resized(m, w, h)
            for (i in out.indices) if (s[i] > (out[i].toInt() and 255)) out[i] = s.pixels[i]
        }
        out = dilate(out, w, h, grow)
        val r = Mask8(out, w, h)
        Mask8.gaussian(r, blur)
        return r
    }

    private fun dilate(src: ByteArray, w: Int, h: Int, n: Int): ByteArray {
        fun line(input: ByteArray, count: Int, stride: Int, start: Int, out: ByteArray) {
            for (i in 0 until count) {
                var v = 0
                for (j in max(0, i - n)..min(count - 1, i + n)) v = max(v, input[start + j * stride].toInt() and 255)
                out[start + i * stride] = v.toByte()
            }
        }
        val t = ByteArray(src.size)
        for (y in 0 until h) line(src, w, 1, y * w, t)
        val out = ByteArray(src.size)
        for (x in 0 until w) line(t, h, w, x, out)
        return out
    }
}
