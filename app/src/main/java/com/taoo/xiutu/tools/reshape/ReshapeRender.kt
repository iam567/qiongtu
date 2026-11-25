package com.taoo.xiutu.tools.reshape

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.Rect
import android.opengl.GLES30
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.ml.FaceInfo
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// MARK: - 编辑步骤

/**
 * 面部重塑：按人脸关键点对五官和脸型做局部变形，作为编辑历史里的一步。
 * 所有位置都按"图片长边 = 1"存，预览图和原图走同一套参数。
 */
class ReshapeParams(
    val faces: List<ReshapeFace> = emptyList(),
    /** 背景保护用的人像蒙版（白 = 人）；null = 不保护。 */
    val lockMask: Bitmap? = null,
    /** 变形还原涂过的地方。 */
    val restore: List<ReshapeRestoreStroke> = emptyList(),
) : EditOp {
    override val skipsColor: Boolean get() = true

    val isIdentity: Boolean get() = faces.all { it.isIdentity }

    override fun apply(src: Bitmap): Bitmap = apply(src, null)

    /** plate 是提前补好的"没有人的背景"（实时预览用）；不传的话开了背景保护就现算。 */
    fun apply(src: Bitmap, plate: ReshapePlate?): Bitmap =
        if (isIdentity) src else ReshapeRender.render(this, src, plate)

    override fun equals(other: Any?): Boolean =
        other is ReshapeParams && other.faces == faces && other.lockMask === lockMask && other.restore == restore

    override fun hashCode(): Int = faces.hashCode() * 31 + restore.hashCode()

    companion object {
        /** 这张脸的关键点能不能用（整体比例对得上）。 */
        fun usable(face: FaceInfo, width: Int, height: Int): Boolean = geometry(face, width, height) != null

        /** 这张脸上这一类项目调不调得了：嘴唇、鼻子、眉毛要各自的关键点落在合理的位置才行。 */
        fun supports(category: ReshapeCategory, face: FaceInfo, width: Int, height: Int): Boolean {
            val geo = geometry(face, width, height) ?: return false
            return when (category) {
                ReshapeCategory.LIPS -> geo.mouth != null
                ReshapeCategory.NOSE -> geo.noseValid
                ReshapeCategory.BROWS -> geo.brows.any { it != null }
                else -> true
            }
        }

        private fun geometry(face: FaceInfo, width: Int, height: Int): FaceGeometry? {
            val long = max(width, height).toFloat()
            if (long <= 0) return null
            return FaceGeometry.make(face, V2(width / long, height / long))
        }
    }
}

/**
 * "没有人的背景"（缩小版）：fill 是把人所在的位置用周围背景颜色由外向里填上的结果，
 * grown 是往外扩过一点的人像蒙版。用时 = 原图 × (1 − grown) + fill × grown。
 */
class ReshapePlate(val fill: Bitmap, val grown: Bitmap) {
    companion object {
        private const val SIDE = 1024

        /** 在后台线程调用。image 是整张图（任意分辨率），mask 是人像蒙版。 */
        fun make(image: Bitmap, mask: Bitmap): ReshapePlate {
            val small = Img.downscale(Img.soft(image), SIDE)
            val w = small.width
            val h = small.height
            val long = max(w, h).toFloat()
            return Gpu.run {
                val img = upload(small)
                val m = pass(Shaders.COPY, mapOf("src" to upload(mask)), emptyMap(), w, h)
                // 人像蒙版往外扩一点，避免人边缘的颜色混进背景。
                val grown = maxFilter(m, long * 0.006f)
                val bg = pass(ReshapeShaders.PLATE_BG, mapOf("src" to img, "grown" to grown), emptyMap(), w, h)
                // 每一层：把周围的背景颜色向人的位置里晕开（只统计背景像素，不掺人的颜色）。
                // 半径小的层细节多但伸不远，半径大的层伸得远但更糊。离背景近的地方用细的，深处才用粗的。
                val levels = floatArrayOf(0.2f, 0.07f, 0.025f, 0.008f).map { blur(bg, long * it * 2.5f) }
                val fill = pass(
                    ReshapeShaders.PLATE_COMBINE,
                    mapOf("b0" to levels[0], "b1" to levels[1], "b2" to levels[2], "b3" to levels[3]),
                    emptyMap(), w, h,
                )
                ReshapePlate(read(fill), read(grown))
            }
        }
    }
}

// MARK: - 渲染

/** 调颜色用的一小块蒙版：rect 是它在图上的位置（长边为 1），feather 是蒙版像素里的羽化半径。 */
private class ColorPatch(
    val kind: Int,
    val amount: Float,
    val rect: FloatArray,
    val mask: Bitmap,
    val feather: Float,
    /** 去眼袋：抹匀用的模糊半径（长边为 1）。 */
    val soft: Float = 0f,
)

private class FacePlan(val colors: List<ColorPatch>, val field: ReshapeField?)

internal object ReshapeRender {
    private const val RED_EYE = 0
    private const val TEETH = 2
    private const val EYE_BAGS = 1

    fun render(params: ReshapeParams, input: Bitmap, plate: ReshapePlate?): Bitmap {
        val src = Img.soft(input)
        val w = src.width
        val h = src.height
        val long = max(w, h).toFloat()
        if (long <= 1) return input
        val aspect = V2(w / long, h / long)

        // 先在 CPU 上把每张脸要做的颜色蒙版和位移场都算好
        val plans = ArrayList<FacePlan>()
        for (face in params.faces) {
            if (face.isIdentity) continue
            val geo = FaceGeometry.make(face.info, aspect) ?: continue
            val colors = colorPatches(face, geo, long)
            val field = ReshapeField.make(ReshapePlan.warps(face, geo), aspect, params.restore)
            if (colors.isNotEmpty() || field != null) plans += FacePlan(colors, field)
        }
        if (plans.isEmpty()) return input

        // 只处理用得到的那一块（像素）：位移场范围外加最大位移，颜色蒙版外加模糊半径
        var x0 = Float.MAX_VALUE
        var y0 = Float.MAX_VALUE
        var x1 = -Float.MAX_VALUE
        var y1 = -Float.MAX_VALUE
        fun grow(l: Float, t: Float, r: Float, b: Float) {
            x0 = min(x0, l); y0 = min(y0, t); x1 = max(x1, r); y1 = max(y1, b)
        }
        for (p in plans) {
            p.field?.let { f ->
                val cx = f.width / f.gw * 3
                val cy = f.height / f.gh * 3
                val reach = f.maxOffset + 4 / long
                grow(f.minX - cx - reach, f.minY - cy - reach, f.minX + f.width + cx + reach, f.minY + f.height + cy + reach)
            }
            for (c in p.colors) {
                val m = c.soft * 3 + 4 / long
                grow(c.rect[0] - m, c.rect[1] - m, c.rect[0] + c.rect[2] + m, c.rect[1] + c.rect[3] + m)
            }
        }
        val left = floor(x0 * long).toInt().coerceIn(0, w - 1)
        val top = floor(y0 * long).toInt().coerceIn(0, h - 1)
        val right = ceil(x1 * long).toInt().coerceIn(left + 1, w)
        val bottom = ceil(y1 * long).toInt().coerceIn(top + 1, h)
        val cw = right - left
        val ch = bottom - top
        val whole = left == 0 && top == 0 && cw == w && ch == h
        val crop = if (whole) src else Bitmap.createBitmap(src, left, top, cw, ch)

        // 超过显卡上限的一块按比例缩小来做（极少见）
        val maxSide = Gpu.run { Gpu.maxTextureSize }
        val k = min(1f, maxSide.toFloat() / max(cw, ch))
        val tw = max(1, (cw * k).roundToInt())
        val th = max(1, (ch * k).roundToInt())
        val work = if (k < 1f) Img.scaled(crop, tw, th) else crop

        val lock = params.lockMask
        val bgPlate = if (lock != null) plate ?: ReshapePlate.make(src, lock) else null

        val view = floatArrayOf(left / long, top / long, cw / long, ch / long)
        val asp = floatArrayOf(aspect.x, aspect.y)
        val result = Gpu.run {
            val own = ArrayList<Int>()
            try {
                var tex = upload(work)
                val person = lock?.let { upload(it) }
                val fill = bgPlate?.let { upload(it.fill) }
                val grown = bgPlate?.let { upload(it.grown) }
                // 长边为 1 的一个单位在这块纹理上是多少像素
                val pxPerLong = tw / view[2]
                for (plan in plans) {
                    // 先调颜色（蒙版和五官位置还对得上），再变形。
                    for (c in plan.colors) tex = colorPass(tex, c, view, asp, pxPerLong)
                    val f = plan.field ?: continue
                    val fieldTex = fieldTexture(f, own)
                    val common = mapOf(
                        "view" to view, "aspect" to asp,
                        "region" to floatArrayOf(f.minX, f.minY, f.width, f.height),
                        "pad" to floatArrayOf(3f / f.gw, 3f / f.gh),
                        "amp" to f.maxOffset,
                    )
                    tex = if (person == null || fill == null || grown == null) {
                        pass(ReshapeShaders.WARP, mapOf("src" to tex, "field" to fieldTex), common, tw, th)
                    } else {
                        // 背景保护：人单独变形，背景保持原图；人让出来的地方用补好的背景填。
                        // 只有人的轮廓真的动过的地方才换成补好的背景：先在小图上算出"动过"的范围，扩一圈再羽化。
                        val ks = min(1f, 1024f / max(tw, th))
                        val sw = max(1, (tw * ks).roundToInt())
                        val sh = max(1, (th * ks).roundToInt())
                        val diff = pass(ReshapeShaders.CHANGED, mapOf("field" to fieldTex, "person" to person), common, sw, sh)
                        val smallLong = long * k * ks
                        val changed = blur(maxFilter(diff, smallLong * 0.01f), smallLong * 0.005f * 2.5f)
                        pass(
                            ReshapeShaders.WARP_LOCK,
                            mapOf("src" to tex, "field" to fieldTex, "person" to person, "changed" to changed, "fill" to fill, "grown" to grown),
                            common, tw, th,
                        )
                    }
                }
                read(tex)
            } finally {
                if (own.isNotEmpty()) GLES30.glDeleteTextures(own.size, own.toIntArray(), 0)
            }
        }
        if (whole && k >= 1f) return result
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        Canvas(out).drawBitmap(result, Rect(0, 0, tw, th), Rect(left, top, right, bottom), Paint(Paint.FILTER_BITMAP_FLAG))
        return out
    }

    /** 位移场传成半精度浮点纹理（RG = 位移 ÷ 最大位移），由 GPU 双线性插值。 */
    private fun fieldTexture(f: ReshapeField, own: MutableList<Int>): Tex {
        val ids = IntArray(1)
        GLES30.glGenTextures(1, ids, 0)
        own += ids[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, ids[0])
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        val buf = ByteBuffer.allocateDirect(f.gw * f.gh * 4 * 4).order(ByteOrder.nativeOrder()).asFloatBuffer()
        for (n in 0 until f.gw * f.gh) {
            buf.put(f.data[n * 2]); buf.put(f.data[n * 2 + 1]); buf.put(0f); buf.put(1f)
        }
        buf.position(0)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_RGBA16F, f.gw, f.gh, 0, GLES30.GL_RGBA, GLES30.GL_FLOAT, buf)
        return Tex(ids[0], f.gw, f.gh)
    }

    private fun GpuScope.colorPass(tex: Tex, c: ColorPatch, view: FloatArray, aspect: FloatArray, pxPerLong: Float): Tex {
        val m = blur(upload(c.mask), c.feather * 2.5f)
        val u = mapOf("view" to view, "aspect" to aspect, "rect" to c.rect, "amount" to c.amount, "kind" to c.kind)
        if (c.kind != EYE_BAGS) return pass(ReshapeShaders.COLOR, mapOf("src" to tex, "mask" to m), u, tex.width, tex.height)
        // 去眼袋：把这一块抠出来抹匀，再按蒙版贴回去
        val pw = (c.rect[2] * pxPerLong).roundToInt().coerceIn(2, 2048)
        val ph = (c.rect[3] * pxPerLong).roundToInt().coerceIn(2, 2048)
        val piece = pass(ReshapeShaders.CROP, mapOf("src" to tex), u, pw, ph)
        val soft = blur(piece, c.soft / c.rect[2] * pw * 2.5f)
        return pass(ReshapeShaders.BAGS, mapOf("src" to tex, "mask" to m, "soft" to soft), u, tex.width, tex.height)
    }

    // MARK: 调颜色的蒙版

    /**
     * 在脸附近的一小块灰度位图上画蒙版（最多 512 像素见方，四周留出 3 倍羽化的黑边）。
     * draw 拿到画布、把长边为 1 的坐标换成位图像素的函数，以及每单位长度的像素数。
     */
    private fun mask(
        center: V2, radius: Float, feather: Float, long: Float,
        draw: (Canvas, (V2) -> PointF, Float) -> Unit,
    ): Triple<FloatArray, Bitmap, Float>? {
        val side = radius * 2 * long
        if (side < 2) return null
        val pixels = ceil(side).toInt().coerceIn(8, 512)
        val k = pixels / (radius * 2)
        val r = radius + feather * 3
        val rect = floatArrayOf(center.x - r, center.y - r, r * 2, r * 2)
        val n = max(8, ceil(r * 2 * k).toInt())
        val bmp = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(Color.BLACK)
        draw(canvas, { p -> PointF((p.x - rect[0]) * k, (p.y - rect[1]) * k) }, k)
        return Triple(rect, bmp, feather * k)
    }

    private fun path(points: List<PointF>): Path = Path().apply {
        moveTo(points[0].x, points[0].y)
        for (i in 1 until points.size) lineTo(points[i].x, points[i].y)
        close()
    }

    private fun paint(white: Boolean, style: Paint.Style = Paint.Style.FILL) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = if (white) Color.WHITE else Color.BLACK
        this.style = style
    }

    private fun colorPatches(face: ReshapeFace, g: FaceGeometry, long: Float): List<ColorPatch> {
        val out = ArrayList<ColorPatch>()
        // 祛红血丝：眼白范围，避开瞳孔。
        face.values[ReshapeKey.RED_EYE]?.let { value ->
            for ((i, e) in g.eyes.withIndex()) {
                val amount = if (i == 0) value.left else value.right
                if (amount <= 0 || e.polygon.size < 3) continue
                val m = mask(e.c, e.w, e.w * 0.04f, long) { cv, point, k ->
                    cv.drawPath(path(e.polygon.map(point)), paint(true))
                    val p = point(e.pupil)
                    cv.drawCircle(p.x, p.y, e.w * 0.24f * k, paint(false))
                } ?: continue
                out += ColorPatch(RED_EYE, amount, m.first, m.second, m.third)
            }
        }
        // 去眼袋：眼睛下面那一条抹匀、提亮一点。
        face.values[ReshapeKey.EYE_BAGS]?.let { value ->
            for ((i, e) in g.eyes.withIndex()) {
                val amount = if (i == 0) value.left else value.right
                if (amount <= 0) continue
                val c = e.c + e.n * (e.w * 0.5f)
                val m = mask(c, e.w * 1.2f, e.w * 0.09f, long) { cv, point, k ->
                    val p = point(c)
                    cv.save()
                    cv.translate(p.x, p.y)
                    cv.rotate(Math.toDegrees(atan2(e.a.y, e.a.x).toDouble()).toFloat())
                    val rx = e.w * 0.62f * k
                    val ry = e.w * 0.2f * k
                    cv.drawOval(-rx, -ry, rx, ry, paint(true))
                    cv.restore()
                    // 眼睛本身不动。
                    if (e.polygon.size >= 3) {
                        val pts = e.polygon.map(point)
                        cv.drawPath(path(pts), paint(false))
                        cv.drawPath(path(pts), paint(false, Paint.Style.STROKE).apply {
                            strokeWidth = e.w * 0.1f * k
                            strokeJoin = Paint.Join.ROUND
                        })
                    }
                } ?: continue
                out += ColorPatch(EYE_BAGS, amount, m.first, m.second, m.third, soft = e.w * 0.06f)
            }
        }
        // 白牙：嘴唇内圈（张着嘴才有）。
        val teeth = face.values[ReshapeKey.TEETH]?.left ?: 0f
        val mouth = g.mouth
        if (teeth > 0 && mouth != null && mouth.inner.size >= 3) {
            mask(mouth.c, mouth.w * 0.8f, mouth.w * 0.02f, long) { cv, point, k ->
                val pts = mouth.inner.map(point)
                cv.drawPath(path(pts), paint(true))
                cv.drawPath(path(pts), paint(true, Paint.Style.STROKE).apply { strokeWidth = mouth.w * 0.02f * k })
            }?.let { out += ColorPatch(TEETH, teeth, it.first, it.second, it.third) }
        }
        return out
    }
}

private fun GpuScope.maxFilter(t: Tex, radius: Float): Tex {
    if (radius < 0.5f) return t
    val r = min(radius, 64f)
    val hPass = pass(ReshapeShaders.MAX_FILTER, mapOf("src" to t), mapOf("dir" to floatArrayOf(1f, 0f), "radius" to r), t.width, t.height)
    return pass(ReshapeShaders.MAX_FILTER, mapOf("src" to hPass), mapOf("dir" to floatArrayOf(0f, 1f), "radius" to r), t.width, t.height)
}

// MARK: - 着色器

internal object ReshapeShaders {

    /** 所有着色器都在"长边为 1"的坐标里算：view 是这块纹理在整张图上的位置，aspect 是整张图的宽高（长边为 1）。 */
    const val COMMON = """
uniform vec4 view;
uniform vec2 aspect;
vec2 toP(vec2 t) { return view.xy + t * view.zw; }
vec2 toT(vec2 p) { return (p - view.xy) / view.zw; }
"""

    const val FIELD = """
uniform sampler2D field;
uniform vec4 region;
uniform vec2 pad;
uniform float amp;
vec2 disp(vec2 p) { return texture(field, (p - region.xy) / region.zw).rg * amp; }
bool inside(vec2 p) {
    vec2 f = (p - region.xy) / region.zw;
    return f.x >= -pad.x && f.y >= -pad.y && f.x <= 1.0 + pad.x && f.y <= 1.0 + pad.y;
}
"""

    /** 人像蒙版边缘很淡的那一圈不算人，否则离人很远的背景也会被带着动一点点。 */
    const val PERSON = """
uniform sampler2D person;
float personAt(vec2 p) { return clamp(texture(person, p / aspect).r * 1.5 - 0.2, 0.0, 1.0); }
"""

    /** 按位移图取样；网格之外原样不动。 */
    const val WARP = Shaders.HEADER + COMMON + FIELD + """
uniform sampler2D src;
void main() {
    vec2 p = toP(uv);
    if (!inside(p)) { o = texture(src, uv); return; }
    o = texture(src, toT(p + disp(p)));
}
"""

    const val WARP_LOCK = Shaders.HEADER + COMMON + FIELD + PERSON + """
uniform sampler2D src;
uniform sampler2D changed;
uniform sampler2D fill;
uniform sampler2D grown;
void main() {
    vec4 base = texture(src, uv);
    vec2 p = toP(uv);
    if (!inside(p)) { o = base; return; }
    vec2 q = p + disp(p);
    vec4 warped = texture(src, toT(q));
    float moved = personAt(q);
    float ch = clamp(texture(changed, uv).r * 2.5, 0.0, 1.0);
    vec2 w = p / aspect;
    vec4 bg = mix(texture(fill, w), base, 1.0 - texture(grown, w).r);
    vec4 behind = mix(base, bg, ch);
    o = mix(behind, warped, moved);
}
"""

    /** 人的轮廓动了多少（变形前后人像蒙版之差）。 */
    const val CHANGED = Shaders.HEADER + COMMON + FIELD + PERSON + """
void main() {
    vec2 p = toP(uv);
    if (!inside(p)) { o = vec4(0.0, 0.0, 0.0, 1.0); return; }
    float d = abs(personAt(p) - personAt(p + disp(p)));
    o = vec4(vec3(d), 1.0);
}
"""

    /** 一个方向上的最大值（两遍就是方形的膨胀）。 */
    const val MAX_FILTER = Shaders.HEADER + """
uniform sampler2D src;
uniform vec2 src_size;
uniform vec2 dir;
uniform float radius;
void main() {
    float m = texture(src, uv).r;
    vec2 px = dir / src_size;
    for (int i = 1; i <= 64; i++) {
        if (float(i) > radius) break;
        m = max(m, max(texture(src, uv + px * float(i)).r, texture(src, uv - px * float(i)).r));
    }
    o = vec4(vec3(m), 1.0);
}
"""

    /** 祛红血丝 / 白牙（在线性色彩里算，和 iOS 的 Core Image 一致）。 */
    const val COLOR = Shaders.HEADER + Shaders.COLOR_FUNCS + COMMON + """
uniform sampler2D src;
uniform sampler2D mask;
uniform vec4 rect;
uniform float amount;
uniform int kind;
void main() {
    vec4 s = texture(src, uv);
    vec2 f = (toP(uv) - rect.xy) / rect.zw;
    float m = (f.x < 0.0 || f.y < 0.0 || f.x > 1.0 || f.y > 1.0) ? 0.0 : texture(mask, f).r;
    if (m <= 0.0 || s.a <= 0.0) { o = s; return; }
    vec3 c = srgbToLinear(s.rgb / s.a);
    float l = luma(c);
    if (kind == 0) {
        // 眼白：把红色压回去，再稍微提亮一点。
        float redness = max(c.r - max(c.g, c.b), 0.0);
        float w = m * amount * smoothstep(0.1, 0.3, l);
        c.r = c.r - redness * 0.9 * w;
        c = c + (vec3(1.0) - c) * 0.06 * w;
    } else {
        // 牙齿：只动偏黄、够亮、不发红的像素（嘴唇和舌头是红的，不碰）。
        float redness = c.r - max(c.g, c.b);
        float w = m * amount * smoothstep(0.08, 0.25, l) * (1.0 - smoothstep(0.03, 0.12, redness));
        c = mix(c, vec3(l), 0.65 * w);
        c = c + (vec3(1.0) - c) * 0.22 * w;
    }
    o = vec4(linearToSrgb(c) * s.a, s.a);
}
"""

    /** 把 rect 这一块抠出来。 */
    const val CROP = Shaders.HEADER + COMMON + """
uniform sampler2D src;
uniform vec4 rect;
void main() { o = texture(src, toT(rect.xy + uv * rect.zw)); }
"""

    /** 去眼袋：抹匀后的那一块提亮 0.22 × 强度 EV，按蒙版 × 强度 × 0.85 贴回。 */
    const val BAGS = Shaders.HEADER + Shaders.COLOR_FUNCS + COMMON + """
uniform sampler2D src;
uniform sampler2D mask;
uniform sampler2D soft;
uniform vec4 rect;
uniform float amount;
void main() {
    vec4 s = texture(src, uv);
    vec2 f = (toP(uv) - rect.xy) / rect.zw;
    float m = (f.x < 0.0 || f.y < 0.0 || f.x > 1.0 || f.y > 1.0) ? 0.0 : texture(mask, f).r;
    if (m <= 0.0) { o = s; return; }
    vec4 b = texture(soft, f);
    vec3 c = srgbToLinear(b.rgb / max(b.a, 1e-4)) * exp2(0.22 * amount);
    vec4 lifted = vec4(linearToSrgb(c) * b.a, b.a);
    o = mix(s, lifted, clamp(m * amount * 0.85, 0.0, 1.0));
}
"""

    const val PLATE_BG = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D grown;
void main() { o = texture(src, uv) * (1.0 - texture(grown, uv).r); }
"""

    /** 由粗到细：每层在周围背景像素占比高的地方盖住上一层。 */
    const val PLATE_COMBINE = Shaders.HEADER + """
uniform sampler2D b0;
uniform sampler2D b1;
uniform sampler2D b2;
uniform sampler2D b3;
vec3 norm(vec4 b, vec3 fallback) { return b.a > 1e-4 ? b.rgb / b.a : fallback; }
void main() {
    vec3 plate = norm(texture(b0, uv), vec3(0.0));
    vec4 l1 = texture(b1, uv);
    plate = mix(plate, norm(l1, plate), clamp(l1.a * 5.0, 0.0, 1.0));
    vec4 l2 = texture(b2, uv);
    plate = mix(plate, norm(l2, plate), clamp(l2.a * 5.0, 0.0, 1.0));
    vec4 l3 = texture(b3, uv);
    plate = mix(plate, norm(l3, plate), clamp(l3.a * 5.0, 0.0, 1.0));
    o = vec4(plate, 1.0);
}
"""
}
