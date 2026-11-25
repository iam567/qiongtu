package com.taoo.xiutu.tools.bodytone

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import com.taoo.xiutu.ai.AIRegion
import com.taoo.xiutu.ai.ChangeKeep
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.tools.color.V3
import com.taoo.xiutu.tools.mosaic.MosaicStroke
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 身体提亮的各项。signed = 能往两边调的。 */
enum class BodyToneKey(val title: String, val symbol: String, val signed: Boolean) {
    BRIGHT("提亮", "sun.max", true),
    MATCH("匹配脸色", "face.smiling", false),
    EVEN("匀肤色", "circle.lefthalf.filled", false),
    WARM("冷暖", "thermometer.medium", true),
    ROSY("红润", "heart", true),
}

/** 身体提亮：只动身体的皮肤，脸不动。范围 = 人身上和"身体颜色"相近的地方（去掉脸）+ 涂上的 − 擦掉的。 */
data class BodyToneParams(
    val values: Map<BodyToneKey, Float> = emptyMap(),
    /** 身体的肤色（点选的，或者自动找的），sRGB 0...1。 */
    val tone: V3 = V3(0.75f, 0.58f, 0.5f),
    /** 颜色差多少以内算身体（0...1，越大范围越宽）。 */
    val range: Float = 0.45f,
    /** 没有身体可选时只用涂的。 */
    val useColor: Boolean = true,
    /** 人像蒙版；null = 没认出人，整张按颜色选。 */
    val person: Bitmap? = null,
    /** 脸的蒙版（白 = 脸，不动）。 */
    val face: Bitmap? = null,
    val strokes: List<MosaicStroke> = emptyList(),
    /** 脸和身体的平均颜色（算"匹配脸色""匀肤色"用）。 */
    val faceMean: V3? = null,
    val bodyMean: V3 = V3(0.6f, 0.5f, 0.45f),
) {
    operator fun get(key: BodyToneKey): Float = values[key] ?: 0f

    val isIdentity: Boolean get() = values.values.all { it == 0f }

    /** 笔画还会接着改的时候，给后台线程一份拷贝。 */
    fun frozen() = copy(strokes = strokes.map { it.copy() })

    /** 着色器里的提亮是 c·g / (1 + c·(g−1))，按它反推出正好到脸色的倍数。 */
    internal fun gain(): FloatArray {
        val f = faceMean ?: return floatArrayOf(1f, 1f, 1f)
        val body = bodyMean.array()
        val face = f.array()
        return FloatArray(3) { i ->
            val c = body[i].coerceIn(0.05f, 0.95f)
            val t = face[i].coerceIn(0.05f, 0.95f)
            (if (t > c) t * (1 - c) / (c * (1 - t)) else t / c).coerceIn(0.6f, 5f)
        }
    }

    /** 选中的范围（白 = 要调的地方）。在最长 1600 的小图上算，边缘本来就要羽化，预览和导出一样。 */
    fun mask(g: GpuScope, src: Tex): Tex {
        val long = max(src.width, src.height).toFloat()
        val k = min(1f, MASK_SIDE / long)
        val w = max(1, (src.width * k).roundToInt())
        val h = max(1, (src.height * k).roundToInt())
        val ml = long * k
        var m: Tex? = null
        if (useColor) {
            // 先轻轻模糊再比颜色，毛孔和噪点不会把范围打碎。
            val smooth = g.blur(src, long * 0.0015f * 2.5f)
            val p = person?.let { g.upload(it) }
            val picked = g.pass(
                PICK, mapOf("src" to smooth, "person" to (p ?: smooth)),
                mapOf("tone" to tone.array(), "range" to range, "usePerson" to if (p != null) 1 else 0), w, h,
            )
            m = ChangeKeep.morphology(g, picked, ml * 0.0008f, grow = false)
            m = ChangeKeep.morphology(g, m, ml * 0.0016f, grow = true)
            m = g.blur(m, ml * 0.0022f * 2.5f)
        }
        val adds = strokes.any { !it.erase }
        val feather = ml * AIRegion.FEATHER * 2.5f
        fun strokeMask(list: List<MosaicStroke>): Tex? = AIRegion.maskImage(AIRegion.grown(list, AIRegion.GROW), w, h)?.let { g.blur(g.upload(it), feather) }
        // 一笔一笔按先后来：后擦的擦掉先涂的，也擦掉自动选的。
        val painted = if (adds) strokeMask(strokes) else null
        // 擦除的范围要减掉"擦完以后又涂回来"的：把笔画反过来画一遍就是。
        val hole = if (strokes.any { it.erase }) strokeMask(strokes.map { MosaicStroke(it.points, it.width, !it.erase, it.style, it.strength) }) else null
        val faceTex = face?.let { g.upload(it) }
        val any = m ?: painted ?: hole ?: faceTex ?: src
        return g.pass(
            COMBINE,
            mapOf("src" to (m ?: any), "painted" to (painted ?: any), "hole" to (hole ?: any), "face" to (faceTex ?: any)),
            mapOf("use" to floatArrayOf(flag(m), flag(painted), flag(hole), flag(faceTex))), w, h,
        )
    }

    private fun flag(t: Tex?) = if (t != null) 1f else 0f

    fun render(g: GpuScope, src: Tex, mask: Tex): Tex {
        val long = max(src.width, src.height).toFloat()
        val mid = g.blur(src, long * 0.018f * 2.5f)
        return g.pass(
            TONE, mapOf("src" to src, "mid" to mid, "mask" to mask),
            mapOf(
                "p" to floatArrayOf(this[BodyToneKey.BRIGHT], this[BodyToneKey.MATCH], this[BodyToneKey.EVEN], this[BodyToneKey.WARM]),
                "rosy" to this[BodyToneKey.ROSY], "gain" to gain(),
                "mean" to bodyMean.x * 0.299f + bodyMean.y * 0.587f + bodyMean.z * 0.114f,
            ),
            src.width, src.height,
        )
    }

    /** showMask：把选中的范围标红（只用在预览里）。 */
    fun apply(src: Bitmap, showMask: Boolean = false): Bitmap {
        if (isIdentity && !showMask) return src
        return Gpu.run {
            val s = upload(src)
            val m = mask(this, s)
            val out = if (isIdentity) s else render(this, s, m)
            read(if (showMask) pass(RED, mapOf("src" to out, "mask" to m), width = s.width, height = s.height) else out)
        }
    }

    companion object {
        private const val MASK_SIDE = 1600f

        private const val YCC = """
vec3 btYCC(vec3 c) {
    float y = dot(c, vec3(0.299, 0.587, 0.114));
    return vec3(y, (c.b - y) * 0.564, (c.r - y) * 0.713);
}
"""

        /** 和身体颜色像不像：看色度，明暗放得很宽（阴影里的皮肤也算）。 */
        private const val PICK = Shaders.HEADER + YCC + """
uniform sampler2D src;
uniform sampler2D person;
uniform vec3 tone;
uniform float range;
uniform int usePerson;
void main() {
    vec3 a = btYCC(clamp(texture(src, uv).rgb, 0.0, 1.0));
    vec3 b = btYCC(tone);
    // 暗处色度会缩小：按亮度比折算后再比。
    float k = clamp(b.x / max(a.x, 0.06), 0.6, 2.2);
    vec2 d = a.yz * k - b.yz;
    float dist = length(d * vec2(1.0, 1.15));
    float limit = mix(0.02, 0.11, range);
    float chroma = 1.0 - smoothstep(limit * 0.6, limit * 1.35, dist);
    float light = smoothstep(0.05, 0.14, a.x) * (1.0 - smoothstep(0.94, 1.0, a.x) * 0.3);
    float closeness = 1.0 - smoothstep(0.35, 0.75, abs(a.x - b.x) * mix(1.5, 0.7, range));
    float m = chroma * light * closeness;
    if (usePerson == 1) m *= texture(person, uv).r;
    o = vec4(m, m, m, 1.0);
}
"""

        /** use = 有没有（自动选的、涂上的、擦掉的、脸）。脸不动；涂上去的地方除外：用户自己涂到脸上就听用户的。 */
        private const val COMBINE = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D painted;
uniform sampler2D hole;
uniform sampler2D face;
uniform vec4 use;
void main() {
    float m = use.x * texture(src, uv).r;
    float add = use.y * texture(painted, uv).r;
    m = max(m, add);
    m *= 1.0 - use.z * texture(hole, uv).r;
    float keep = max(1.0 - use.w * texture(face, uv).r, add);
    m *= keep;
    o = vec4(m, m, m, 1.0);
}
"""

        private const val TONE = Shaders.HEADER + Shaders.COLOR_FUNCS + """
uniform sampler2D src;
uniform sampler2D mid;
uniform sampler2D mask;
uniform vec4 p;
uniform float rosy;
uniform vec3 gain;
uniform float mean;
void main() {
    vec4 s = texture(src, uv);
    vec3 c = clamp(s.rgb, 0.0, 1.0);
    // 匀肤色：把大块的明暗不均往平均亮度拉。
    float y = dot(texture(mid, uv).rgb, vec3(0.299, 0.587, 0.114));
    float level = clamp(mean / max(y, 0.05), 0.65, 1.6);
    float e = mix(1.0, level, p.z * 0.6);
    // 匹配脸色 + 匀肤色：提亮不溢出。
    vec3 g = mix(vec3(1.0), gain, p.y) * e;
    c = c * g / (vec3(1.0) + c * max(g - vec3(1.0), vec3(0.0)));
    // 提亮 / 压暗：中间调动得多，黑和白不动。
    float b = p.x;
    c = b >= 0.0 ? c + b * 0.9 * c * (vec3(1.0) - c) : c + b * 0.7 * c * (vec3(1.0) - c * 0.6);
    float l = dot(c, vec3(0.299, 0.587, 0.114));
    c += vec3(0.045, 0.006, -0.05) * p.w * l * 2.0 * (1.0 - l * 0.5);
    c += vec3(0.045, -0.018, -0.004) * rosy * l * 2.0 * (1.0 - l * 0.5);
    // 贴回去在线性光里混合，和 iOS 一致。
    o = vec4(linearToSrgb(mix(srgbToLinear(s.rgb), srgbToLinear(clamp(c, 0.0, 1.0)), texture(mask, uv).r)), s.a);
}
"""

        private const val RED = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D mask;
void main() {
    vec4 c = texture(src, uv);
    vec3 red = mix(c.rgb, vec3(1.0, 0.15, 0.2), 0.5);
    o = vec4(mix(c.rgb, red, texture(mask, uv).r), c.a);
}
"""
    }
}

/** 身体提亮确认后的一步。 */
class BodyToneOp(params: BodyToneParams) : EditOp {
    val params = params.frozen()

    override val skipsColor: Boolean get() = true

    override fun apply(src: Bitmap): Bitmap = params.apply(src)
}

/** 进工具时在本机做的识别：人像、脸，以及身体的肤色。在后台线程调用。 */
object BodyToneDetector {
    class Found(val person: Bitmap?, val face: Bitmap?, val faceMean: V3?)

    fun detect(image: Bitmap): Found {
        val person = runCatching { PersonSegmenter.mask(Img.downscale(image, 1024)) }.getOrNull()
        val faces = runCatching { FaceDetector.detect(image) }.getOrDefault(emptyList())
        val face = if (faces.isEmpty()) null else faceMask(faces, image.width, image.height)
        // 脸颊中间那一块的平均色。
        val faceMean = faces.maxByOrNull { it.box.width() }?.let { main ->
            val b = main.box
            mean(image, RectF(b.left + b.width() * 0.25f, b.top + b.height() * 0.45f, b.left + b.width() * 0.75f, b.top + b.height() * 0.75f))
        }
        return Found(person, face, faceMean)
    }

    /** 一块地方（归一化）的平均色。 */
    fun mean(image: Bitmap, rect: RectF): V3? {
        val x0 = (rect.left * image.width).toInt().coerceIn(0, image.width)
        val y0 = (rect.top * image.height).toInt().coerceIn(0, image.height)
        val x1 = kotlin.math.ceil(rect.right * image.width).toInt().coerceIn(0, image.width)
        val y1 = kotlin.math.ceil(rect.bottom * image.height).toInt().coerceIn(0, image.height)
        val w = x1 - x0
        val h = y1 - y0
        if (w < 1 || h < 1) return null
        val px = IntArray(w * h)
        image.getPixels(px, 0, w, x0, y0, w, h)
        var r = 0L
        var g = 0L
        var b = 0L
        for (p in px) { r += p shr 16 and 255; g += p shr 8 and 255; b += p and 255 }
        val n = px.size * 255f
        return V3(r / n, g / n, b / n)
    }

    /** 范围里的平均颜色（按蒙版加权）；几乎没选中东西时是 null。 */
    fun mean(image: Bitmap, params: BodyToneParams): V3? = Gpu.run {
        val s = upload(image)
        val mask = params.mask(this, s)
        // 先按蒙版加权再缩小：旁边的衣服和背景不会混进来。
        var sum = passFloat(WEIGHTED, mapOf("src" to s, "mask" to mask), width = mask.width, height = mask.height)
        while (max(sum.width, sum.height) > 160) {
            // 每次正好对半（双线性取四点平均），不漏采样
            sum = passFloat(Shaders.COPY, mapOf("src" to sum), width = max(1, (sum.width + 1) / 2), height = max(1, (sum.height + 1) / 2))
        }
        val color = read(pass(UNWEIGHT, mapOf("src" to sum), width = sum.width, height = sum.height))
        val weights = read(pass(WEIGHT, mapOf("src" to sum), width = sum.width, height = sum.height))
        val n = sum.width * sum.height
        val a = IntArray(n).also { color.getPixels(it, 0, sum.width, 0, 0, sum.width, sum.height) }
        val m = IntArray(n).also { weights.getPixels(it, 0, sum.width, 0, 0, sum.width, sum.height) }
        var r = 0.0
        var g = 0.0
        var b = 0.0
        var weight = 0.0
        for (i in a.indices) {
            val t = (m[i] shr 16 and 255) / 255.0
            r += (a[i] shr 16 and 255) * t
            g += (a[i] shr 8 and 255) * t
            b += (a[i] and 255) * t
            weight += t
        }
        if (weight <= 12) null else V3((r / (weight * 255)).toFloat(), (g / (weight * 255)).toFloat(), (b / (weight * 255)).toFloat())
    }

    private const val WEIGHTED = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D mask;
void main() {
    float m = texture(mask, uv).r;
    o = vec4(texture(src, uv).rgb * m, m);
}
"""

    private const val UNWEIGHT = Shaders.HEADER + """
uniform sampler2D src;
void main() {
    vec4 c = texture(src, uv);
    o = vec4(clamp(c.rgb / max(c.a, 0.0001), 0.0, 1.0), 1.0);
}
"""

    private const val WEIGHT = Shaders.HEADER + """
uniform sampler2D src;
void main() { o = vec4(vec3(texture(src, uv).a), 1.0); }
"""

    private fun faceMask(faces: List<FaceInfo>, width: Int, height: Int): Bitmap {
        val k = 900f / max(width, height)
        val w = max(1, (width * k).toInt())
        val h = max(1, (height * k).toInt())
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.BLACK)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
        var feather = 3f
        for (f in faces) {
            val b = f.box
            feather = max(feather, b.width() * w * 0.035f)
            if (f.hasReliableLandmarks) {
                // 下颌线 + 往上到发际线。
                val eyes = f.leftEye + f.rightEye
                val ey = eyes.sumOf { it.y.toDouble() }.toFloat() / eyes.size
                val chin = f.contour.maxOfOrNull { it.y } ?: b.bottom
                val top = ey - (chin - ey) * 0.75f
                val first = f.contour.first()
                val last = f.contour.last()
                val line = f.contour + listOf(
                    PointF(last.x + (first.x - last.x) * 0.06f, top + (ey - top) * 0.35f),
                    PointF(last.x + (first.x - last.x) * 0.25f, top),
                    PointF(last.x + (first.x - last.x) * 0.75f, top),
                    PointF(first.x + (last.x - first.x) * 0.06f, top + (ey - top) * 0.35f),
                )
                val path = Path()
                line.forEachIndexed { i, p -> if (i == 0) path.moveTo(p.x * w, p.y * h) else path.lineTo(p.x * w, p.y * h) }
                path.close()
                c.drawPath(path, paint)
            } else {
                c.drawOval(RectF(b.left * w, b.top * h - b.height() * h * 0.15f, b.right * w, b.bottom * h), paint)
            }
        }
        val m = Mask8.grayOf(bmp)
        Mask8.gaussian(m, feather)
        return m.toGrayBitmap()
    }
}
