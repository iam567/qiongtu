package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.AIRecipe
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.tools.mosaic.MosaicMaskSet
import com.taoo.xiutu.tools.mosaic.MosaicStroke
import com.taoo.xiutu.tools.mosaic.MosaicStyle
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * 一次 AI 改图的结果，作为编辑历史里的一步。
 * 涂抹过区域时，只把该区域换成 AI 的结果，其余部分保持原图和原分辨率。
 */
class AIEdit(
    val result: Bitmap,
    strokes: List<MosaicStroke>,
    /** 结果对应原图的哪一块（归一化坐标，原点左上角）。null = 整张图。 */
    val frame: RectF? = null,
    /** 只采用这个椭圆范围内的结果（归一化坐标），边缘羽化。 */
    val ellipse: RectF? = null,
    /** 0...1，AI 结果和原图的混合比例。 */
    val strength: Float = 1f,
    /** 只采用 AI 的光影和颜色，细节用原图。 */
    val toneOnly: Boolean = false,
    /** 换了画幅的构图：结果整张替换原图，画面比例跟着 AI 的结果走。 */
    val reframed: Boolean = false,
    /** 预览时拖滑块会反复新建这一步：笔画没变就沿用上一次画好的蒙版。 */
    shared: AIEdit? = null,
    /** 0...1，把 AI 结果过头的锐化压下去，在本机调。 */
    val soften: Float = 0f,
    /** 这一步是怎么发起的（套用到新照片时再跑一遍）；涂抹、融合出来的没有。 */
    val recipe: AIRecipe? = null,
    /** 贴回原图的脸（整张重画的结果用）。 */
    val faces: List<FaceKeep> = emptyList(),
    /** 只在真正变了的地方用 AI 的像素（美体、去路人这类只动一部分的）。 */
    val changedOnly: Boolean = false,
    /** changedOnly 允许换的范围（人和周围一圈，灰度图，白 = 允许）；null = 整张。 */
    val area: Bitmap? = null,
    /** AI 图整体偏了多少（占宽高的比例，左上原点），对齐后再比较。 */
    val shift: Pair<Float, Float> = 0f to 0f,
    /** AI 的结果是黑白的：只取光影时把颜色也去掉。 */
    val mono: Boolean = false,
) : EditOp {
    val strokes: List<MosaicStroke> = strokes.map { it.copy() }

    val hasRegion get() = strokes.any { !it.erase }

    override val bakesInput: Boolean
        get() = frame == null && ellipse == null && !hasRegion && !toneOnly

    override val changesCanvas: Boolean get() = reframed

    // 蒙版只和尺寸有关：拖强度滑块时不用每次重画
    private var maskCache: Pair<Long, Bitmap>? = null

    init {
        if (shared != null && shared.strokes.size == this.strokes.size &&
            shared.strokes.indices.all { shared.strokes[it].sameAs(this.strokes[it]) }
        ) {
            maskCache = synchronized(shared) { shared.maskCache }
        }
    }

    private fun regionMask(w: Int, h: Int): Bitmap? = synchronized(this) {
        val key = w.toLong() shl 32 or h.toLong()
        maskCache?.let { if (it.first == key) return it.second }
        val m = AIRegion.maskImage(strokes, w, h) ?: return null
        maskCache = key to m
        m
    }

    private fun keepFaces(g: GpuScope, out: Tex, original: Tex): Tex {
        if (faces.isEmpty()) return out
        val pasted = faces.fold(out) { t, face -> face.apply(g, t, original) }
        return if (mono) MonoCheck.gray(g, pasted) else pasted
    }

    override fun apply(src: Bitmap): Bitmap {
        val w = src.width
        val h = src.height
        if (reframed) {
            // 长边和原图一样长，比例按 AI 给的。
            val k = max(w, h).toFloat() / max(result.width, result.height)
            val ow = (result.width * k).roundToInt().coerceAtLeast(1)
            val oh = (result.height * k).roundToInt().coerceAtLeast(1)
            val out = if (k < 1f) Img.scaled(Img.downscale(result, max(ow, oh)), ow, oh) else Img.scaled(result, ow, oh)
            if (soften <= 0.005f && faces.isEmpty()) return out
            return Gpu.run {
                val soft = softened(this, upload(out), soften, max(ow, oh).toFloat())
                read(if (faces.isEmpty()) soft else keepFaces(this, soft, upload(src)))
            }
        }
        // 结果贴到哪一块（像素，原点左上）
        val t = frame?.let { floatArrayOf(it.left * w, it.top * h, it.width() * w, it.height() * h) }
            ?: floatArrayOf(0f, 0f, w.toFloat(), h.toFloat())
        // 涂抹蒙版：最长 2048，和分辨率无关
        val maskScale = min(1f, 2048f / max(w, h))
        val mask = if (ellipse == null && hasRegion) {
            regionMask((w * maskScale).roundToInt().coerceAtLeast(1), (h * maskScale).roundToInt().coerceAtLeast(1))
        } else null
        return Gpu.run {
            val s = upload(src)
            val r = upload(result)
            var fg = r
            val full = floatArrayOf(0f, 0f, w.toFloat(), h.toFloat())
            var place = t
            val (sx, sy) = shift
            if (toneOnly || changedOnly || faces.isNotEmpty() || sx != 0f || sy != 0f) {
                // 整体偏了就挪回来，边上露出来的地方延伸边缘像素
                val rect = floatArrayOf(t[0] + sx * w, t[1] + sy * h, t[2], t[3])
                fg = pass(AIShaders.PLACE, mapOf("res" to r), mapOf("rect" to rect), w, h)
                place = full
            }
            val areaTex = if (toneOnly || changedOnly) area?.let { upload(it) } else null
            if (toneOnly) {
                fg = ToneTransfer.apply(this, s, fg)
                if (mono) fg = MonoCheck.gray(this, fg)
                if (areaTex != null) fg = ChangeKeep.blend(this, s, fg, areaTex)
            } else if (changedOnly) {
                fg = ChangeKeep.apply(this, s, fg, areaTex)
            }
            if (soften > 0.005f) {
                // 柔化按贴上去之后的大小算半径：先摆到整张画布上再模糊
                if (fg === r) {
                    fg = pass(AIShaders.PLACE, mapOf("res" to r), mapOf("rect" to t), w, h)
                    place = full
                }
                fg = softened(this, fg, soften, max(t[2], t[3]))
            }
            if (!toneOnly) fg = keepFaces(this, fg, s)
            var mode = 0
            var maskTex = s
            val ell = FloatArray(4)
            var sigma = 0f
            val e = ellipse
            if (e != null) {
                mode = 1
                ell[0] = e.centerX() * w; ell[1] = e.centerY() * h
                ell[2] = e.width() * w / 2; ell[3] = e.height() * h / 2
                sigma = min(e.width() * w, e.height() * h) * 0.08f
            } else if (mask != null) {
                mode = 2
                // 边缘羽化一点，接缝才不明显（σ = 长边 × 0.006，换算到蒙版像素）
                val m = upload(mask)
                val sig = max(w, h) * 0.006f * (mask.width.toFloat() / w)
                maskTex = blur(m, sig * 2.5f)
            }
            val out = pass(
                AIShaders.COMPOSE, mapOf("src" to s, "fg" to fg, "mask" to maskTex),
                mapOf("rect" to place, "mode" to mode, "ell" to ell, "sigma" to sigma, "strength" to strength.coerceIn(0f, 1f)),
                w, h,
            )
            read(out)
        }
    }

    companion object {
        /**
         * AI 出图常常锐化过头：和模糊过的自己混一下，边缘的白边和沙沙的纹理就下去了。
         * dim = 结果贴上去之后的长边，和 r 用同一种像素单位。
         */
        fun softened(g: GpuScope, r: Tex, amount: Float, dim: Float = max(r.width, r.height).toFloat()): Tex {
            if (amount <= 0.005f) return r
            // Core Image 的模糊半径约等于 σ；Gpu.blur 的半径是 2.5σ
            val blurred = g.blur(r, dim * (0.0006f + 0.0012f * amount) * 2.5f)
            return g.pass(
                AIShaders.SOFT_MIX, mapOf("src" to r, "fg" to blurred), mapOf("t" to min(1f, amount * 0.9f)),
                r.width, r.height,
            )
        }
    }
}

/**
 * 只采用 AI 结果的光影和颜色，细节全部用原图。
 * 比较"AI 图"和"原图"各自模糊之后的样子，得到每个位置的增益，再乘回原图。
 */
object ToneTransfer {
    /** radius（σ，像素）不给就用长边的 1.2%（修逆光这类要跟着局部光影走）；给大半径就只跟整体的明暗冷暖。 */
    fun apply(g: GpuScope, original: Tex, graded: Tex, radius: Float? = null): Tex {
        // Core Image 的模糊半径约等于 σ；Gpu.blur 的半径是 2.5σ
        val radius = (radius ?: (max(original.width, original.height) * 0.012f)) * 2.5f
        val bo = g.blur(original, radius)
        val br = g.blur(graded, radius)
        val out = g.pass(AIShaders.TONE_GAIN, mapOf("src" to original, "bo" to bo, "br" to br), width = original.width, height = original.height)
        if (bo !== original) g.release(bo)
        if (br !== graded) g.release(br)
        return out
    }
}

/** 涂抹区域相关的图像处理。 */
object AIRegion {
    /** AI 区域的笔画统一用这个样式，这样蒙版只有一张。 */
    fun stroke(points: List<PointF>, width: Float, erase: Boolean) =
        MosaicStroke(points.toMutableList(), width, erase, MosaicStyle.PIXEL, 1f)

    /** 白 = 涂抹过的区域。 */
    fun maskImage(strokes: List<MosaicStroke>, width: Int, height: Int): Bitmap? {
        val set = MosaicMaskSet(width, height)
        set.rebuild(strokes)
        return set.snapshot().firstOrNull()?.image
    }

    /** 把涂抹区域用半透明红色标出来：既是屏幕上的预览，也是发给不支持蒙版的服务商的参考图。 */
    fun overlay(base: Bitmap, mask: Bitmap, lock: Any? = null): Bitmap = Gpu.run {
        val b = upload(base)
        val m = if (lock != null) synchronized(lock) { upload(mask) } else upload(mask)
        read(pass(AIShaders.RED_OVERLAY, mapOf("src" to b, "mask" to m), width = b.width, height = b.height))
    }
}

internal object AIShaders {
    const val LINEAR = """
vec3 toLin(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toSrgb(vec3 c) { c = max(c, 0.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
"""

    /** 把 res 拉伸到 rect（像素：x, y, w, h），rect 外面延伸边缘像素。 */
    const val PLACE = Shaders.HEADER + """
uniform sampler2D res;
uniform vec4 rect;
void main() {
    vec2 p = uv * size;
    o = texture(res, clamp((p - rect.xy) / rect.zw, 0.0, 1.0));
}
"""

    /** 增益 = 模糊后的 AI 图 / 模糊后的原图，在线性光里算（和 Core Image 一致）。 */
    const val TONE_GAIN = Shaders.HEADER + LINEAR + """
uniform sampler2D src;
uniform sampler2D bo;
uniform sampler2D br;
void main() {
    vec4 c = texture(src, uv);
    vec3 a = max(toLin(texture(br, uv).rgb), vec3(0.0)) + vec3(0.004);
    vec3 b = max(toLin(texture(bo, uv).rgb), vec3(0.0)) + vec3(0.004);
    vec3 gain = clamp(a / b, vec3(0.0), vec3(6.0));
    o = vec4(toSrgb(toLin(c.rgb) * gain), c.a);
}
"""

    /**
     * 贴回：mode 0 = 整张按强度混合，1 = 羽化椭圆，2 = 涂抹蒙版。
     * 椭圆的羽化 = 硬边椭圆做高斯模糊（σ = sigma）的解析近似。混合在线性光里做。
     */
    const val COMPOSE = Shaders.HEADER + LINEAR + """
uniform sampler2D src;
uniform sampler2D fg;
uniform sampler2D mask;
uniform vec4 rect;
uniform int mode;
uniform vec4 ell;
uniform float sigma;
uniform float strength;
float erfApprox(float x) {
    float s = sign(x);
    x = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * x);
    float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-x * x);
    return s * y;
}
void main() {
    vec2 p = uv * size;
    vec4 a = texture(src, uv);
    vec4 b = texture(fg, clamp((p - rect.xy) / rect.zw, 0.0, 1.0));
    float m = 1.0;
    if (mode == 1) {
        vec2 q = (p - ell.xy) / ell.zw;
        float d = length(q);
        vec2 grad = q / max(ell.zw, vec2(1.0)) / max(d, 1e-4);
        float sd = (d - 1.0) / max(length(grad), 1e-6);
        m = 0.5 * (1.0 - erfApprox(sd / (max(sigma, 0.5) * 1.41421356)));
    } else if (mode == 2) {
        m = texture(mask, uv).r;
    }
    m *= strength;
    vec3 c = toSrgb(mix(toLin(a.rgb), toLin(b.rgb), m));
    o = vec4(c, mix(a.a, b.a, m));
}
"""

    /** 和模糊过的自己混合（线性光）。 */
    const val SOFT_MIX = Shaders.HEADER + LINEAR + """
uniform sampler2D src;
uniform sampler2D fg;
uniform float t;
void main() {
    vec4 a = texture(src, uv);
    vec4 b = texture(fg, uv);
    o = vec4(toSrgb(mix(toLin(a.rgb), toLin(b.rgb), t)), mix(a.a, b.a, t));
}
"""

    const val RED_OVERLAY = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D mask;
void main() {
    vec4 c = texture(src, uv);
    float m = texture(mask, uv).r;
    vec3 tinted = mix(c.rgb, vec3(1.0, 0.1, 0.2), 0.55);
    o = vec4(mix(c.rgb, tinted, m), c.a);
}
"""
}
