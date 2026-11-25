package com.taoo.xiutu.tools.beauty

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Shader
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.tools.color.ColorGL
import com.taoo.xiutu.tools.color.ColorGL.gauss
import com.taoo.xiutu.tools.color.ColorParams
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** 本机美颜的各个项目。全部用 GPU 着色器完成，不联网、实时预览。 */
enum class BeautyKey(val title: String, val symbol: String) {
    SMOOTH("磨皮", "wand.and.stars"),
    WHITEN("美白", "sun.max"),
    SLIM("瘦脸", "arrow.right.and.line.vertical.and.arrow.left"),
    EYES("大眼", "eye"),
    LIPS("口红", "mouth"),
    BLUSH("腮红", "heart.circle"),
}

class BeautyPreset(val title: String, val values: Map<BeautyKey, Float>, val lipColor: Int = 0) {
    val id: String get() = title

    companion object {
        val all = listOf(
            BeautyPreset("自然", mapOf(BeautyKey.SMOOTH to 0.35f, BeautyKey.WHITEN to 0.2f, BeautyKey.SLIM to 0.15f, BeautyKey.EYES to 0.1f)),
            BeautyPreset("清透", mapOf(BeautyKey.SMOOTH to 0.5f, BeautyKey.WHITEN to 0.45f, BeautyKey.SLIM to 0.15f, BeautyKey.EYES to 0.15f, BeautyKey.BLUSH to 0.2f)),
            BeautyPreset(
                "精致",
                mapOf(BeautyKey.SMOOTH to 0.55f, BeautyKey.WHITEN to 0.3f, BeautyKey.SLIM to 0.35f, BeautyKey.EYES to 0.3f, BeautyKey.LIPS to 0.35f, BeautyKey.BLUSH to 0.25f),
                lipColor = 0,
            ),
            BeautyPreset(
                "网感",
                mapOf(BeautyKey.SMOOTH to 0.7f, BeautyKey.WHITEN to 0.5f, BeautyKey.SLIM to 0.5f, BeautyKey.EYES to 0.45f, BeautyKey.LIPS to 0.5f, BeautyKey.BLUSH to 0.4f),
                lipColor = 2,
            ),
        )
    }
}

/** 口红颜色：名字 + RGB（0...1）。 */
class LipColor(val name: String, val r: Float, val g: Float, val b: Float) {
    val argb: Int get() = Color.rgb((r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt())
}

/**
 * 一张脸的手动美颜参数，同时也是编辑历史里的一步。
 * faces 一般只有一张脸（每张脸各自一组参数）。
 */
data class BeautyParams(
    val faces: List<FaceInfo> = emptyList(),
    val values: Map<BeautyKey, Float> = emptyMap(),
    val lipColor: Int = 0,
) : EditOp {
    override val skipsColor: Boolean get() = true

    operator fun get(key: BeautyKey): Float = values[key] ?: 0f

    /** 改一项：<= 0 等于去掉，最大 1。 */
    fun with(key: BeautyKey, value: Float): BeautyParams {
        val m = values.toMutableMap()
        if (value <= 0f) m.remove(key) else m[key] = min(value, 1f)
        return copy(values = m)
    }

    /** 套用预设；null = 全部清零（口红颜色不动）。 */
    fun with(preset: BeautyPreset?): BeautyParams =
        copy(values = preset?.values?.filterValues { it > 0f } ?: emptyMap(), lipColor = preset?.lipColor ?: lipColor)

    val isIdentity: Boolean get() = values.isEmpty() || faces.isEmpty()

    override fun apply(src: Bitmap): Bitmap = if (isIdentity) src else BeautyRender.apply(src, this)

    companion object {
        val lipColors = listOf(
            LipColor("豆沙", 0.72f, 0.36f, 0.38f),
            LipColor("正红", 0.80f, 0.12f, 0.18f),
            LipColor("珊瑚", 0.95f, 0.42f, 0.36f),
            LipColor("莓果", 0.62f, 0.13f, 0.30f),
            LipColor("裸粉", 0.85f, 0.55f, 0.55f),
        )
    }
}

/**
 * 手动美颜的渲染。只处理脸附近的一块（大图也不用分块），处理完贴回原图。
 * 顺序照 iOS：磨皮 → 美白 → 口红 → 腮红 → 瘦脸 / 大眼（变形放最后，前面的蒙版才和五官对得上）。
 */
object BeautyRender {
    fun apply(src: Bitmap, p: BeautyParams): Bitmap {
        val w = src.width
        val h = src.height
        if (w <= 0 || h <= 0) return src
        val region = region(p.faces, w, h) ?: return src
        val rw = region.width()
        val rh = region.height()
        // 这一块超过显存上限时缩小处理（极少见）
        val k = min(1f, Gpu.maxTextureSize.toFloat() / max(rw, rh))
        var sub = Bitmap.createBitmap(src, region.left, region.top, rw, rh)
        if (k < 1f) sub = Img.scaled(sub, max(1, (rw * k).toInt()), max(1, (rh * k).toInt()))
        val geo = Geometry(w.toFloat(), h.toFloat(), region.left.toFloat(), region.top.toFloat(), k, sub.width, sub.height)
        val masks = Masks.get(p.faces, geo)
        val out = render(sub, p, geo, masks)
        val piece = if (out.width != rw || out.height != rh) Img.scaled(out, rw, rh) else out
        val result = src.copy(Bitmap.Config.ARGB_8888, true)
        val paint = Paint().apply { xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC) }
        Canvas(result).drawBitmap(piece, null, region, paint)
        return result
    }

    /** 所有脸外扩之后的范围（像素），磨皮的模糊、额头、变形的半径都落在里面。 */
    private fun region(faces: List<FaceInfo>, w: Int, h: Int): Rect? {
        var box: RectF? = null
        for (f in faces) {
            val bw = f.box.width() * w
            val bh = f.box.height() * h
            val s = max(bw, bh)
            val r = RectF(f.box.left * w - s * 0.9f, f.box.top * h - s * 1.0f, f.box.right * w + s * 0.9f, f.box.bottom * h + s * 0.8f)
            val pts = f.contour + f.leftEye + f.rightEye + f.leftBrow + f.rightBrow + f.outerLips + f.nose
            for (q in pts) r.union(q.x * w, q.y * h)
            val cur = box
            if (cur == null) box = r else cur.union(r)
        }
        val b = box ?: return null
        val out = Rect(floor(b.left).toInt(), floor(b.top).toInt(), ceil(b.right).toInt(), ceil(b.bottom).toInt())
        if (!out.intersect(0, 0, w, h) || out.width() < 2 || out.height() < 2) return null
        return out
    }

    /** 归一化坐标 → 处理块里的像素坐标。 */
    class Geometry(val fw: Float, val fh: Float, val ox: Float, val oy: Float, val k: Float, val width: Int, val height: Int) {
        fun px(p: PointF) = PointF((p.x * fw - ox) * k, (p.y * fh - oy) * k)

        /** 一张脸有多宽（处理块像素）。 */
        fun faceWidth(face: FaceInfo): Float {
            val a = face.contour.firstOrNull()
            val b = face.contour.lastOrNull()
            if (a != null && b != null) return hypot((a.x - b.x) * fw, (a.y - b.y) * fh) * k
            return face.box.width() * fw * k
        }
    }

    private fun centroid(points: List<PointF>): PointF {
        if (points.isEmpty()) return PointF(0f, 0f)
        return PointF(points.sumOf { it.x.toDouble() }.toFloat() / points.size, points.sumOf { it.y.toDouble() }.toFloat() / points.size)
    }

    private fun render(sub: Bitmap, p: BeautyParams, geo: Geometry, masks: Masks): Bitmap {
        val extentW = geo.width.toFloat()
        val faceWidth = p.faces.maxOfOrNull { geo.faceWidth(it) } ?: (extentW * 0.3f)
        return Gpu.run {
            var cur = pass(ColorGL.UNPREMUL, mapOf("src" to upload(sub)), width = geo.width, height = geo.height)

            val smooth = p[BeautyKey.SMOOTH]
            val whiten = p[BeautyKey.WHITEN]
            val skinBmp = masks.skin
            if ((smooth > 0 || whiten > 0) && skinBmp != null) {
                val skin = gauss(upload(skinBmp), faceWidth * 0.03f * masks.scale)
                if (smooth > 0) {
                    // 先把皮肤上的色块抹匀，再把细纹理补回来一些，避免磨成塑料脸。
                    val a = 0.75f * smooth
                    val radius = max(2f, faceWidth * 0.03f)
                    val blurred = gauss(cur, radius)
                    val soft = pass(Shaders.MIX, mapOf("src" to cur, "fg" to blurred), mapOf("t" to a), geo.width, geo.height)
                    // 只在亮度上补锐，避免在明暗交界处锐化出彩色的小点。
                    val sharpness = min(1.2f, a / (1 - a)) * 0.45f
                    val detail = gauss(soft, max(1f, radius / 5))
                    val sharp = pass(SHARPEN_LUM, mapOf("src" to soft, "low" to detail), mapOf("amount" to sharpness), geo.width, geo.height)
                    cur = pass(Shaders.BLEND_MASK, mapOf("src" to cur, "fg" to sharp, "mask" to skin), width = geo.width, height = geo.height)
                }
                if (whiten > 0) {
                    val c = ColorParams(brightness = 0.3f * whiten, shadows = 0.2f * whiten, saturation = -0.08f * whiten)
                    cur = pass(WHITEN, mapOf("src" to cur, "mask" to skin), c.uniforms("cp"), geo.width, geo.height)
                }
            }

            val lips = p[BeautyKey.LIPS]
            val lipBmp = masks.lips
            if (lips > 0 && lipBmp != null) {
                val color = BeautyParams.lipColors[p.lipColor.coerceIn(0, BeautyParams.lipColors.size - 1)]
                val m = gauss(upload(lipBmp), masks.lipFeather)
                // 用口红的色相和饱和度，保留嘴唇原本的明暗和纹理。
                cur = pass(LIP, mapOf("src" to cur, "mask" to m), mapOf("lip" to floatArrayOf(color.r, color.g, color.b), "k" to lips * 0.85f), geo.width, geo.height)
            }

            val blush = p[BeautyKey.BLUSH]
            val blushBmp = masks.blush
            if (blush > 0 && blushBmp != null) {
                cur = pass(BLUSH, mapOf("src" to cur, "mask" to upload(blushBmp)), mapOf("k" to blush * 0.32f), geo.width, geo.height)
            }

            // 变形放在最后做，这样前面的蒙版还和五官位置对得上。
            val slim = p[BeautyKey.SLIM]
            val eyes = p[BeautyKey.EYES]
            if (slim > 0 || eyes > 0) {
                for (face in p.faces) {
                    if (!face.hasReliableLandmarks) continue
                    val fwid = geo.faceWidth(face)
                    if (slim > 0 && face.contour.size >= 8) {
                        val all = face.contour.map(geo::px)
                        val center = centroid(if (face.nose.isEmpty()) all else face.nose.map(geo::px))
                        for (index in listOf(all.size / 4, all.size * 3 / 4)) {
                            val cheek = all[index]
                            // 收缩中心放在脸颊内侧，脸的边缘就会被往里带。
                            val c = PointF(cheek.x + (center.x - cheek.x) * 0.3f, cheek.y + (center.y - cheek.y) * 0.3f)
                            cur = bump(cur, c, fwid * 0.4f, -0.28f * slim)
                        }
                    }
                    if (eyes > 0) {
                        for ((points, pupil) in listOf(face.leftEye to face.leftPupil, face.rightEye to face.rightPupil)) {
                            if (points.size < 3) continue
                            val all = points.map(geo::px)
                            val c = pupil?.let(geo::px) ?: centroid(all)
                            val eyeWidth = all.maxOf { it.x } - all.minOf { it.x }
                            cur = bump(cur, c, max(4f, eyeWidth * 1.1f), 0.28f * eyes)
                        }
                    }
                }
            }
            read(pass(ColorGL.PREMUL, mapOf("src" to cur), width = geo.width, height = geo.height))
        }
    }

    private fun GpuScope.bump(t: Tex, center: PointF, radius: Float, scale: Float): Tex =
        pass(BUMP, mapOf("src" to t), mapOf("center" to floatArrayOf(center.x, center.y), "radius" to radius, "scale" to scale), t.width, t.height)

    // MARK: 着色器（中间纹理是未预乘的颜色）

    /** 亮度上的反锐化：只把亮度的高频加回去。 */
    private const val SHARPEN_LUM = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D low;
uniform float amount;
void main() {
    vec4 c = texture(src, uv);
    vec3 l = texture(low, uv).rgb;
    const vec3 W = vec3(0.2126, 0.7152, 0.0722);
    float d = dot(c.rgb, W) - dot(l, W);
    o = vec4(clamp(c.rgb + d * amount, 0.0, 1.0), c.a);
}
"""

    /** 美白：调色参数套在皮肤蒙版里。 */
    private val WHITEN = Shaders.HEADER + ColorParams.glsl("cp") + """
uniform sampler2D src;
uniform sampler2D mask;
void main() {
    vec4 c = texture(src, uv);
    float m = texture(mask, uv).r;
    o = vec4(mix(c.rgb, cp_map(c.rgb), m), c.a);
}
"""

    /** 口红：颜色混合模式（口红的色相饱和度 + 嘴唇原本的亮度）。 */
    private const val LIP = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D mask;
uniform vec3 lip;
uniform float k;
float lum(vec3 c) { return dot(c, vec3(0.3, 0.59, 0.11)); }
vec3 clipColor(vec3 c) {
    float l = lum(c);
    float n = min(c.r, min(c.g, c.b));
    float x = max(c.r, max(c.g, c.b));
    if (n < 0.0) c = l + (c - l) * l / max(l - n, 1e-5);
    if (x > 1.0) c = l + (c - l) * (1.0 - l) / max(x - l, 1e-5);
    return c;
}
vec3 setLum(vec3 c, float l) { return clipColor(c + (l - lum(c))); }
void main() {
    vec4 c = texture(src, uv);
    float m = texture(mask, uv).r * k;
    o = vec4(mix(c.rgb, setLum(lip, lum(c.rgb)), m), c.a);
}
"""

    /** 腮红：纯色按蒙版叠上去。 */
    private const val BLUSH = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D mask;
uniform float k;
void main() {
    vec4 c = texture(src, uv);
    float m = texture(mask, uv).r * k;
    o = vec4(mix(c.rgb, vec3(1.0, 0.42, 0.48), m), c.a);
}
"""

    /** 鼓起 / 收缩（对应 CIBumpDistortion）：scale > 0 放大，< 0 往里收。 */
    private const val BUMP = Shaders.HEADER + """
uniform sampler2D src;
uniform vec2 center;
uniform float radius;
uniform float scale;
void main() {
    vec2 p = uv * size;
    vec2 d = p - center;
    float dist = length(d);
    if (dist < radius) {
        float t = 1.0 - dist / radius;
        p = center + d * (1.0 - scale * t * t);
    }
    o = texture(src, p / size);
}
"""

    // MARK: 蒙版

    /** 皮肤 / 嘴唇 / 腮红蒙版。蒙版位图最长边限制在 1536，GPU 上拉伸并羽化。同一组脸和尺寸重复使用。 */
    class Masks(val scale: Float, val skin: Bitmap?, val lips: Bitmap?, val lipFeather: Float, val blush: Bitmap?) {
        companion object {
            private var lastKey: Any? = null
            private var last: Masks? = null

            fun get(faces: List<FaceInfo>, geo: Geometry): Masks = synchronized(this) {
                val key = listOf(faces, geo.fw, geo.fh, geo.ox, geo.oy, geo.k, geo.width, geo.height)
                last?.let { if (lastKey == key) return it }
                val m = build(faces, geo)
                lastKey = key
                last = m
                m
            }

            private fun build(faces: List<FaceInfo>, geo: Geometry): Masks {
                val scale = min(1f, 1536f / max(geo.width, geo.height))
                val mw = max(1, (geo.width * scale).roundToInt())
                val mh = max(1, (geo.height * scale).roundToInt())
                // 蒙版像素坐标（和处理块同比例）
                val sx = mw.toFloat() / geo.width
                val sy = mh.toFloat() / geo.height
                fun pt(p: PointF): PointF { val q = geo.px(p); return PointF(q.x * sx, q.y * sy) }
                val skin = skinMask(faces, mw, mh, ::pt)
                var widest = 0f
                val lips = lipMask(faces, mw, mh, ::pt) { widest = it }
                val blush = blushMask(faces, mw, mh, ::pt)
                return Masks(scale, skin, lips, widest * 0.035f, blush)
            }
        }
    }

    private class MaskCanvas(val w: Int, val h: Int) {
        val bitmap: Bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.BLACK) }
        val canvas = Canvas(bitmap)
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
        }

        /** 填充多边形，grow > 0 时再向外描一圈把形状撑大。 */
        fun fill(points: List<PointF>, white: Boolean, grow: Float = 0f) {
            if (points.size < 3) return
            val path = Path()
            path.moveTo(points[0].x, points[0].y)
            for (i in 1 until points.size) path.lineTo(points[i].x, points[i].y)
            path.close()
            paint.color = if (white) Color.WHITE else Color.BLACK
            paint.shader = null
            paint.xfermode = null
            if (grow > 0) {
                paint.style = Paint.Style.FILL_AND_STROKE
                paint.strokeWidth = grow * 2
            } else {
                paint.style = Paint.Style.FILL
            }
            canvas.drawPath(path, paint)
        }

        fun ellipse(r: RectF) {
            paint.color = Color.WHITE
            paint.style = Paint.Style.FILL
            paint.shader = null
            paint.xfermode = null
            canvas.drawOval(r, paint)
        }

        /** 中心白、边缘黑的径向渐变，用"滤色"叠加，两团重叠时不会互相盖掉。 */
        fun glow(c: PointF, radius: Float) {
            if (radius <= 0f) return
            paint.style = Paint.Style.FILL
            paint.color = Color.WHITE
            paint.shader = RadialGradient(c.x, c.y, radius, Color.WHITE, Color.BLACK, Shader.TileMode.CLAMP)
            paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SCREEN)
            canvas.drawCircle(c.x, c.y, radius, paint)
            paint.shader = null
            paint.xfermode = null
        }
    }

    private fun span(points: List<PointF>): Float =
        if (points.isEmpty()) 0f else points.maxOf { it.x } - points.minOf { it.x }

    /** 皮肤区域：下颌轮廓加上估算的额头，挖掉眼睛、眉毛和嘴唇。 */
    private fun skinMask(faces: List<FaceInfo>, w: Int, h: Int, pt: (PointF) -> PointF): Bitmap? {
        val canvas = MaskCanvas(w, h)
        var drew = false
        for (face in faces) {
            if (face.hasReliableLandmarks) continue
            // 五官不可信时，用人脸框估一个椭圆当皮肤范围。
            val b = face.box
            val tl = pt(PointF(b.left - b.width() * 0.05f, b.bottom - b.height() * 1.35f))
            val br = pt(PointF(b.left - b.width() * 0.05f + b.width() * 1.1f, b.bottom))
            canvas.ellipse(RectF(tl.x, tl.y, br.x, br.y))
            drew = true
        }
        for (face in faces) {
            if (!face.hasReliableLandmarks) continue
            val contour = face.contour.map(pt)
            val a = contour[0]
            val b = contour[contour.size - 1]
            val chin = contour[contour.size / 2]
            val mid = PointF((a.x + b.x) / 2, (a.y + b.y) / 2)
            val half = hypot(a.x - mid.x, a.y - mid.y)
            val upLength = max(hypot(mid.x - chin.x, mid.y - chin.y), 1f)
            val up = PointF((mid.x - chin.x) / upLength, (mid.y - chin.y) / upLength)
            // 检测器不给额头的点，用一段半椭圆补上。
            val polygon = contour.toMutableList()
            for (step in 11 downTo 1) {
                val t = step / 12f * PI.toFloat()
                polygon += PointF(
                    mid.x + cos(t) * (a.x - mid.x) + sin(t) * up.x * half * 1.1f,
                    mid.y + cos(t) * (a.y - mid.y) + sin(t) * up.y * half * 1.1f,
                )
            }
            canvas.fill(polygon, white = true)
            for (eye in listOf(face.leftEye, face.rightEye)) {
                val p = eye.map(pt)
                canvas.fill(p, white = false, grow = span(p) * 0.3f)
            }
            for (brow in listOf(face.leftBrow, face.rightBrow)) {
                val p = brow.map(pt)
                canvas.fill(p, white = false, grow = span(p) * 0.08f)
            }
            val lips = face.outerLips.map(pt)
            canvas.fill(lips, white = false, grow = span(lips) * 0.06f)
            drew = true
        }
        return if (drew) canvas.bitmap else null
    }

    private fun lipMask(faces: List<FaceInfo>, w: Int, h: Int, pt: (PointF) -> PointF, widestOut: (Float) -> Unit): Bitmap? {
        val canvas = MaskCanvas(w, h)
        var widest = 0f
        for (face in faces) {
            if (!face.hasReliableLandmarks || face.outerLips.size < 3) continue
            val outer = face.outerLips.map(pt)
            canvas.fill(outer, white = true)
            canvas.fill(face.innerLips.map(pt), white = false)
            widest = max(widest, span(outer))
        }
        widestOut(widest)
        return if (widest > 0) canvas.bitmap else null
    }

    private fun blushMask(faces: List<FaceInfo>, w: Int, h: Int, pt: (PointF) -> PointF): Bitmap? {
        val canvas = MaskCanvas(w, h)
        var drew = false
        for (face in faces) {
            if (!face.hasReliableLandmarks || face.outerLips.size < 3) continue
            val l = centroid(face.leftEye.map(pt))
            val r = centroid(face.rightEye.map(pt))
            val mouth = centroid(face.outerLips.map(pt))
            val eyeMid = PointF((l.x + r.x) / 2, (l.y + r.y) / 2)
            val eyeDistance = max(hypot(l.x - r.x, l.y - r.y), 1f)
            val down = PointF(mouth.x - eyeMid.x, mouth.y - eyeMid.y)
            val ends = listOf(pt(face.contour[0]), pt(face.contour[face.contour.size - 1]))
            // 每只眼睛到同侧脸边缘的距离 = 这半边脸露出来多宽。侧脸时远离镜头的那边很窄，就不画。
            fun sideWidth(eye: PointF) = ends.minOf { hypot(it.x - eye.x, it.y - eye.y) }
            val wl = sideWidth(l)
            val wr = sideWidth(r)
            val widest = max(max(wl, wr), 1f)
            for ((eye, other, side) in listOf(Triple(l, r, wl), Triple(r, l, wr))) {
                if (side / widest <= 0.55f) continue
                val out = PointF((eye.x - other.x) / eyeDistance, (eye.y - other.y) / eyeDistance)
                val c = PointF(eye.x + down.x * 0.55f + out.x * side * 0.15f, eye.y + down.y * 0.55f + out.y * side * 0.15f)
                canvas.glow(c, side * 0.8f)
            }
            drew = true
        }
        return if (drew) canvas.bitmap else null
    }
}

// MARK: - AI 美颜的风格

class BeautyStyle(val title: String, val prompt: String) {
    val id: String get() = title

    companion object {
        /** 所有风格共用的前提：只做修饰，必须还是同一个人。 */
        const val preamble = "This is a close-up crop from a portrait photo. Retouch the face like a top professional beauty retoucher. " +
            "The person must remain clearly the same individual: keep their identity, face shape, facial proportions, eye color, " +
            "expression, gaze, head pose, hairstyle, hair color, accessories, clothing, lighting direction and background. " +
            "Keep the exact same framing and position of every feature so the result can be overlaid on the original. " +
            "Keep realistic skin texture with visible pores; no plastic or airbrushed look. Photorealistic result. Style:"

        /** 满意脸型：第二张图是用户自己修满意的脸，照着它修。 */
        val favorite = BeautyStyle(
            "满意脸型",
            "match the user's own favorite retouch. The SECOND image is a reference: a face this user retouched before and is happy with. " +
                "Retouch the face in the FIRST image so it has the same look as the reference — the same face shape and jaw contour, face slimness, " +
                "eye size and shape, nose and lip refinement, skin smoothness and glow, and the same makeup style and colors. " +
                "Keep the identity of the person in the FIRST image: if the reference looks like a different person, transfer only the retouching " +
                "(slimness, eye enlargement, skin finish, makeup), never their facial identity. Return only the edited first image.",
        )

        val all = listOf(
            BeautyStyle("自然", "natural retouch. Even out skin tone, remove blemishes and reduce dark circles, slightly brighter eyes. Very subtle; it should look like a great photo of them on a good day."),
            BeautyStyle("韩系", "Korean beauty look. Luminous dewy glass skin, clear and bright complexion, soft straight brows, gentle gradient lips, soft rosy cheeks, delicate and fresh."),
            BeautyStyle("减龄", "fresh youthful look. Smooth fine lines and under-eye hollows, slightly fuller cheeks, brighter clearer eyes, soft healthy glow. Still clearly the same adult."),
            BeautyStyle("精致", "refined polished look. Flawless but textured skin, crisp well-defined features, subtle contour and highlight, neat brows, elegant understated makeup."),
            BeautyStyle("骨相", "enhanced bone structure. Use light and shadow to bring out cheekbones, a cleaner jawline, brow bone and nose bridge. Sculpted and elegant, without changing who they are."),
            BeautyStyle("消肿", "de-puffed look. Reduce facial puffiness and swelling, less puffy under-eyes and cheeks, slightly tighter contour, more awake and fresh."),
            BeautyStyle("立体", "more three-dimensional face. Stronger contour and highlight so the features have more depth, defined nose bridge and cheekbones."),
            BeautyStyle("紧致", "firm lifted look. Tighter jawline, softened nasolabial folds, firmer smoother skin, lifted cheeks."),
            BeautyStyle("补光", "beauty lighting. Add soft flattering frontal fill light on the face, brighten it evenly, gentle catchlights in the eyes, reduce harsh shadows."),
            BeautyStyle("欧美", "Western glam makeup. Sculpted contour, warm bronzed skin, defined arched brows, smoky neutral eyeshadow, fuller matte lips."),
            BeautyStyle("浓颜", "bold striking look. Deeper eye makeup, stronger brows, more saturated lips, high-contrast defined features."),
            BeautyStyle("网感", "social-media influencer look. Bright flawless skin, big bright sparkling eyes, small refined face, rosy cheeks and glossy lips."),
            BeautyStyle("裸感", "no-makeup makeup look. Bare healthy skin with natural glow, barely-there lip tint, soft natural brows."),
            BeautyStyle("甜妹", "sweet cute look. Soft pink blush, glossy pink lips, bright round eyes, gentle and adorable."),
        )
    }
}
