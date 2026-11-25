package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.tools.shape.V2
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * AI 整张重画以后，把原图里的脸按五官位置对齐、贴回到 AI 的结果上：
 * 皮肤纹理和五官用原图的，明暗和颜色跟着 AI 图走。脸上就没有涂抹感，也不会换了个人。
 * 坐标都以各自图的长边为 1，原点左上角。
 */
data class FaceKeep(
    /** 原图 → 结果图的相似变换：x' = a·x − b·y + tx，y' = b·x + a·y + ty。 */
    val a: Double,
    val b: Double,
    val tx: Double,
    val ty: Double,
    /** 结果图上脸的范围（闭合多边形）。 */
    val outline: List<V2>,
    /** 结果图上脸的宽度。 */
    val width: Float,
) {
    /** 结果图整体平移了 shift（占宽高的比例）以后的位置。 */
    fun moved(dx: Float, dy: Float, w: Int, h: Int): FaceKeep {
        if (dx == 0f && dy == 0f) return this
        val long = max(w, h).toFloat()
        val x = dx * w / long
        val y = dy * h / long
        return copy(tx = tx + x, ty = ty + y, outline = outline.map { V2(it.x + x, it.y + y) })
    }

    // MARK: 贴回

    /** out：AI 的结果（已经放大到成品大小）；original：这一步之前的画面。 */
    fun apply(g: GpuScope, out: Tex, original: Tex): Tex {
        val l0 = max(original.width, original.height).toFloat()
        val l1 = max(out.width, out.height).toFloat()
        val face = width * l1
        if (outline.size < 3) return out
        val xs = outline.map { it.x * l1 }
        val ys = outline.map { it.y * l1 }
        // 原图摆到结果图上之后的范围。
        val ow = original.width / l0
        val oh = original.height / l0
        val corners = listOf(0f to 0f, ow to 0f, 0f to oh, ow to oh).map { (x, y) ->
            ((a * x - b * y + tx) * l1).toFloat() to ((b * x + a * y + ty) * l1).toFloat()
        }
        val pad = face * 0.45f
        val x0 = floor(max(max(xs.min() - pad, 0f), corners.minOf { it.first })).toInt()
        val y0 = floor(max(max(ys.min() - pad, 0f), corners.minOf { it.second })).toInt()
        val x1 = ceil(min(min(xs.max() + pad, out.width.toFloat()), corners.maxOf { it.first })).toInt()
        val y1 = ceil(min(min(ys.max() + pad, out.height.toFloat()), corners.maxOf { it.second })).toInt()
        val w = x1 - x0
        val h = y1 - y0
        if (w <= 8 || h <= 8) return out
        // 结果图像素 → 原图的 uv：反过来的相似变换。
        val n = a * a + b * b
        if (n < 1e-9) return out
        val region = floatArrayOf(x0.toFloat(), y0.toFloat(), w.toFloat(), h.toFloat())
        val warped = g.pass(
            WARP, mapOf("src" to original),
            mapOf(
                "region" to region, "l1" to l1, "unit" to floatArrayOf(ow, oh),
                "inv" to floatArrayOf((a / n).toFloat(), (b / n).toFloat()), "move" to floatArrayOf(tx.toFloat(), ty.toFloat()),
            ),
            w, h,
        )
        val cut = g.pass(CUT, mapOf("src" to out), mapOf("region" to region), w, h)
        // 明暗和颜色跟着 AI 图，细节用原图。
        val toned = ToneTransfer.apply(g, warped, cut, radius = face * 0.075f)
        val k = min(1f, 512f / max(w, h))
        val mw = max(1, (w * k).roundToInt())
        val mh = max(1, (h * k).roundToInt())
        val bmp = Bitmap.createBitmap(mw, mh, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.BLACK)
        val path = Path()
        for (i in xs.indices) {
            val x = (xs[i] - x0) * k
            val y = (ys[i] - y0) * k
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
        }
        path.close()
        c.drawPath(path, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE })
        val mask = g.blur(g.upload(bmp), face * 0.07f * k * 2.5f)
        return g.pass(PASTE, mapOf("src" to out, "fg" to toned, "mask" to mask), mapOf("region" to region), out.width, out.height)
    }

    companion object {
        /** original：发给 AI 之前的照片；result：AI 的结果。对不上的脸（转了头、换了表情、太小）不贴。在后台线程调用。 */
        fun match(original: Bitmap, result: Bitmap): List<FaceKeep> {
            val from = FaceDetector.detect(original).filter { it.hasReliableLandmarks }
            if (from.isEmpty()) return emptyList()
            val to = FaceDetector.detect(result).filter { it.hasReliableLandmarks }
            if (to.isEmpty()) return emptyList()
            val su = unit(original)
            val du = unit(result)
            val used = HashSet<Int>()
            val out = ArrayList<FaceKeep>()
            // 大的脸先配。
            for (face in to.sortedByDescending { it.box.width() }.take(4)) {
                var best: Triple<Int, FaceKeep, Double>? = null
                for ((i, source) in from.withIndex()) {
                    if (i in used || original.width * source.box.width() < 50) continue
                    val (keep, error) = fit(source, su, face, du) ?: continue
                    if (best == null || error < best.third) best = Triple(i, keep, error)
                }
                best?.let {
                    used += it.first
                    out += it.second
                }
            }
            return out
        }

        /** 归一化坐标 → 长边为 1 的坐标。 */
        private fun unit(b: Bitmap): V2 {
            val long = max(b.width, b.height).toFloat()
            return V2(b.width / long, b.height / long)
        }

        private fun scaled(p: List<PointF>, u: V2) = p.map { V2(it.x * u.x, it.y * u.y) }

        private fun fit(s: FaceInfo, su: V2, d: FaceInfo, du: V2): Pair<FaceKeep, Double>? {
            val from = ArrayList<V2>()
            val to = ArrayList<V2>()
            // 两边都有、点数一样的五官才用（ML Kit 有时只给一个鼻尖点）。
            for ((x, y) in listOf(s.leftEye to d.leftEye, s.rightEye to d.rightEye, s.nose to d.nose, s.outerLips to d.outerLips)) {
                if (x.isEmpty() || x.size != y.size) continue
                from += scaled(x, su)
                to += scaled(y, du)
            }
            val width = d.box.width() * du.x
            val f = similarity(from, to, width) ?: return null
            val line = outline(
                scaled(d.contour, du), scaled(d.leftEye + d.rightEye, du), scaled(d.leftBrow + d.rightBrow, du), scaled(d.outerLips, du),
            ) ?: return null
            return FaceKeep(f.a, f.b, f.tx, f.ty, line, width) to f.error
        }

        internal class Fit(val a: Double, val b: Double, val tx: Double, val ty: Double, val error: Double)

        /** 最小二乘的相似变换。对不上（误差超过脸宽的 4.5%，说明表情或角度变了）返回 null。 */
        internal fun similarity(from: List<V2>, to: List<V2>, width: Float): Fit? {
            if (from.size < 12 || from.size != to.size || width <= 0f) return null
            val n = from.size.toDouble()
            val mx = from.sumOf { it.x.toDouble() } / n
            val my = from.sumOf { it.y.toDouble() } / n
            val ux = to.sumOf { it.x.toDouble() } / n
            val uy = to.sumOf { it.y.toDouble() } / n
            var sa = 0.0
            var sb = 0.0
            var ss = 0.0
            for (i in from.indices) {
                val px = from[i].x - mx
                val py = from[i].y - my
                val qx = to[i].x - ux
                val qy = to[i].y - uy
                sa += px * qx + py * qy
                sb += px * qy - py * qx
                ss += px * px + py * py
            }
            if (ss <= 1e-9) return null
            val a = sa / ss
            val b = sb / ss
            val tx = ux - a * mx + b * my
            val ty = uy - b * mx - a * my
            var sum = 0.0
            for (i in from.indices) {
                val x = a * from[i].x - b * from[i].y + tx - to[i].x
                val y = b * from[i].x + a * from[i].y + ty - to[i].y
                sum += x * x + y * y
            }
            val error = sqrt(sum / n) / width
            if (error >= 0.045 || a <= 0) return null
            return Fit(a, b, tx, ty, error)
        }

        /** 脸的范围：下颌线往里收一点，上面盖到眉毛上方的额头，不碰到头发和背景。 */
        internal fun outline(jaw: List<V2>, eyes: List<V2>, brows: List<V2>, lips: List<V2>): List<V2>? {
            if (jaw.size < 5 || eyes.isEmpty() || lips.isEmpty()) return null
            fun center(p: List<V2>) = V2(p.sumOf { it.x.toDouble() }.toFloat() / p.size, p.sumOf { it.y.toDouble() }.toFloat() / p.size)
            val up = center(eyes) - center(lips)
            // 眉毛往上推半个"眼到嘴"的距离，就是额头。
            val top = brows.ifEmpty { eyes }.map { V2(it.x + up.x * 0.32f, it.y + up.y * 0.32f) } + brows
            val hull = convexHull(jaw + top)
            val c = center(hull)
            return hull.map { V2(c.x + (it.x - c.x) * 0.93f, c.y + (it.y - c.y) * 0.93f) }
        }

        internal fun convexHull(points: List<V2>): List<V2> {
            val p = points.sortedWith(compareBy({ it.x }, { it.y }))
            if (p.size <= 2) return p
            fun cross(o: V2, a: V2, b: V2) = (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
            fun half(list: List<V2>): List<V2> {
                val out = ArrayList<V2>()
                for (q in list) {
                    while (out.size >= 2 && cross(out[out.size - 2], out[out.size - 1], q) <= 0) out.removeAt(out.size - 1)
                    out += q
                }
                out.removeAt(out.size - 1)
                return out
            }
            return half(p) + half(p.reversed())
        }

        /** 把原图按相似变换摆到结果图的这一块上。 */
        private const val WARP = Shaders.HEADER + """
uniform sampler2D src;
uniform vec4 region;
uniform float l1;
uniform vec2 unit;
uniform vec2 inv;
uniform vec2 move;
void main() {
    vec2 q = (region.xy + uv * region.zw) / l1 - move;
    vec2 p = vec2(inv.x * q.x + inv.y * q.y, inv.x * q.y - inv.y * q.x);
    o = texture(src, clamp(p / unit, 0.0, 1.0));
}
"""

        private const val CUT = Shaders.HEADER + """
uniform sampler2D src;
uniform vec4 region;
void main() { o = texture(src, (region.xy + uv * region.zw) / src_size); }
"""

        /** 先往里缩再羽化：蒙版模糊后按 1.7m − 0.7 收，羽化的边完全落在脸里面。 */
        private const val PASTE = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
uniform sampler2D fg;
uniform sampler2D mask;
uniform vec4 region;
void main() {
    vec4 a = texture(src, uv);
    vec2 q = (uv * size - region.xy) / region.zw;
    if (q.x <= 0.0 || q.y <= 0.0 || q.x >= 1.0 || q.y >= 1.0) { o = a; return; }
    float m = clamp(texture(mask, q).r * 1.7 - 0.7, 0.0, 1.0);
    o = vec4(toSrgb(mix(toLin(a.rgb), toLin(texture(fg, q).rgb), m)), a.a);
}
"""
    }
}

/** AI 的结果是不是黑白的：只取光影时要把原图残留的颜色也去掉。 */
object MonoCheck {
    private const val SIDE = 48

    fun isMono(image: Bitmap): Boolean {
        val small = Img.scaled(Img.downscale(Img.soft(image), SIDE * 2), SIDE, SIDE)
        val px = IntArray(SIDE * SIDE)
        small.getPixels(px, 0, SIDE, 0, 0, SIDE, SIDE)
        return isMono(px)
    }

    internal fun isMono(px: IntArray): Boolean {
        var colored = 0
        for (p in px) {
            val r = p shr 16 and 255
            val g = p shr 8 and 255
            val b = p and 255
            if (max(r, max(g, b)) - min(r, min(g, b)) > 14) colored++
        }
        return colored * 50 < px.size
    }

    /** 去掉颜色（线性光里按亮度，和 Core Image 一致）。 */
    fun gray(g: GpuScope, src: Tex): Tex = g.pass(GRAY, mapOf("src" to src), width = src.width, height = src.height)

    private const val GRAY = Shaders.HEADER + AIShaders.LINEAR + """
uniform sampler2D src;
void main() {
    vec4 c = texture(src, uv);
    float y = dot(toLin(c.rgb), vec3(0.2125, 0.7154, 0.0721));
    o = vec4(toSrgb(vec3(y)), c.a);
}
"""
}
