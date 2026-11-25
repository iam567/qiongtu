package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.RadialGradient
import android.graphics.RectF
import android.graphics.Shader
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * 美发 → 发型 按钮上的小图：用代码画的半身像，每个发型一张，头发是主角。
 * 照搬 iOS HairArt.swift，坐标按 136 × 168 的设计稿写（原点左上，y 向下）。
 */
object HairArt {
    private const val W = 136f
    private const val H = 168f
    private const val cx = 68f
    private const val PIf = PI.toFloat()

    private val cache = HashMap<String, Bitmap>()

    /** 画一次就记住。 */
    fun image(title: String, scale: Float = 3f): Bitmap? = synchronized(cache) {
        cache[title]?.let { return it }
        val build = styles[title] ?: MalePresets.hairArtAlias[title]?.let { styles[it] } ?: return null
        val pw = (W * scale).roundToInt()
        val ph = (H * scale).roundToInt()
        val bmp = Bitmap.createBitmap(pw, ph, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.scale(pw / W, ph / H)
        val scene = Scene()
        build(scene)
        draw(scene, c)
        cache[title] = bmp
        bmp
    }

    // MARK: 配色

    private class Rgb(val r: Float, val g: Float, val b: Float)

    private fun rgb(r: Float, g: Float, b: Float, a: Float = 1f): Int =
        android.graphics.Color.argb((a * 255).roundToInt(), (r * 255).roundToInt(), (g * 255).roundToInt(), (b * 255).roundToInt())

    private object Ink {
        val hair = Rgb(0.23f, 0.155f, 0.125f)
        val light = Rgb(0.62f, 0.44f, 0.33f)
        val dark = Rgb(0.09f, 0.06f, 0.05f)
        val stubble = Rgb(0.36f, 0.30f, 0.27f)
        val skin = Rgb(0.975f, 0.87f, 0.79f)
        val skinShade = Rgb(0.90f, 0.745f, 0.655f)
    }

    private fun ink(c: Rgb, a: Float = 1f) = rgb(c.r, c.g, c.b, a)

    private fun pt(x: Float, y: Float) = PointF(x, y)

    private infix fun MutableList<Piece>.reset(items: List<Piece>) {
        clear()
        addAll(items)
    }

    // MARK: 零件

    /** 一块头发：轮廓，加上画在它上面的亮发丝、暗发丝和大块的光泽。 */
    private class Piece(
        var fill: Path,
        val light: MutableList<Path> = mutableListOf(),
        val dark: MutableList<Path> = mutableListOf(),
        val shine: MutableList<Pair<Path, Float>> = mutableListOf(),
    )

    private class Scene {
        var male = false
        var ears = false
        /** 寸头：头发只是一层青皮，颜色浅。 */
        var pale = false
        /** 在身体后面的头发。 */
        val back = mutableListOf<Piece>()
        /** 在脸和身体前面的头发。 */
        val front = mutableListOf<Piece>()
        /** 发圈。 */
        val ties = mutableListOf<RectF>()
        /** 整个人往下挪多少。 */
        var shift = 0f
    }

    /** 一条从上往下的边：x 随高度怎么变。 */
    private class Edge(
        val top: Float, val bottom: Float, val bulge: Float = 0f,
        val amp: Float = 0f, val period: Float = 26f, val phase: Float = 0f, val grow: Float = 1f,
    ) {
        fun x(t: Float, y: Float): Float {
            val base = top + (bottom - top) * t + bulge * sin(PIf * t)
            val k = (1 - grow) + grow * min(1f, t * 1.7f)
            return base + amp * k * sin(2 * PIf * y / period + phase)
        }
    }

    private enum class End { FLAT, ROUND, TAPER, CURL_RIGHT, CURL_LEFT }

    private fun Path.moveTo(p: PointF) = moveTo(p.x, p.y)
    private fun Path.lineTo(p: PointF) = lineTo(p.x, p.y)
    private fun Path.curve(to: PointF, c1: PointF, c2: PointF) = cubicTo(c1.x, c1.y, c2.x, c2.y, to.x, to.y)
    private fun Path.quad(to: PointF, c: PointF) = quadTo(c.x, c.y, to.x, to.y)

    /** 两条边之间的一片头发。 */
    private fun ribbon(left: Edge, right: Edge, top: Float, bottom: Float, end: End = End.ROUND, strands: Int = 2): Piece {
        val n = 44
        val l = ArrayList<PointF>()
        val r = ArrayList<PointF>()
        for (i in 0..n) {
            val t = i.toFloat() / n
            val y = top + (bottom - top) * t
            l += pt(left.x(t, y), y)
            r += pt(right.x(t, y), y)
        }
        val path = Path()
        path.moveTo(l[0])
        for (p in l.drop(1)) path.lineTo(p)
        val a = l[n]
        val b = r[n]
        val w = b.x - a.x
        when (end) {
            End.FLAT -> path.lineTo(b)
            End.ROUND -> {
                val d = min(w * 0.4f, 7f)
                path.curve(b, pt(a.x + w * 0.12f, a.y + d), pt(b.x - w * 0.12f, b.y + d))
            }
            End.TAPER -> {
                path.quad(pt((a.x + b.x) / 2, a.y + min(w * 0.9f, 12f)), pt(a.x + w * 0.15f, a.y + 6))
                path.quad(b, pt(b.x - w * 0.15f, b.y + 6))
            }
            End.CURL_RIGHT -> {
                path.curve(pt(b.x + 1, b.y + min(w * 0.5f, 6f)), pt(a.x + 0.5f, a.y + min(w * 0.6f, 7f)), pt(b.x - w * 0.45f, b.y + min(w * 0.8f, 9f)))
                path.lineTo(b)
            }
            End.CURL_LEFT -> {
                path.lineTo(pt(a.x - 1, a.y + min(w * 0.5f, 6f)))
                path.curve(b, pt(a.x + w * 0.45f, a.y + min(w * 0.8f, 9f)), pt(b.x - 0.5f, b.y + min(w * 0.6f, 7f)))
            }
        }
        for (p in r.reversed().drop(1)) path.lineTo(p)
        path.close()

        val light = mutableListOf<Path>()
        if (strands > 0) {
            for (s in 1..strands) {
                val f = s.toFloat() / (strands + 1)
                val line = Path()
                for (i in 3 until n - 1) {
                    val p = pt(l[i].x + (r[i].x - l[i].x) * f, l[i].y)
                    if (i == 3) line.moveTo(p) else line.lineTo(p)
                }
                light += line
            }
        }
        return Piece(path, light)
    }

    /** 穿过几个点的平滑曲线，采样成折线。 */
    private fun spline(pts: List<PointF>, samples: Int = 10): List<PointF> {
        if (pts.size < 2) return pts
        val out = ArrayList<PointF>()
        for (i in 0 until pts.size - 1) {
            val p0 = pts[max(i - 1, 0)]
            val p1 = pts[i]
            val p2 = pts[i + 1]
            val p3 = pts[min(i + 2, pts.size - 1)]
            for (s in 0 until samples) {
                val t = s.toFloat() / samples
                val t2 = t * t
                val t3 = t2 * t
                fun f(a: Float, b: Float, c: Float, d: Float) =
                    0.5f * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                out += pt(f(p0.x, p1.x, p2.x, p3.x), f(p0.y, p1.y, p2.y, p3.y))
            }
        }
        out += pts.last()
        return out
    }

    /** 沿着一条曲线走的一束头发（马尾、刘海、碎发），粗细可以一路变。 */
    private fun tube(pts: List<PointF>, strands: Int = 1, width: (Float) -> Float): Piece {
        val c = spline(pts)
        val n = c.size - 1
        val l = ArrayList<PointF>()
        val r = ArrayList<PointF>()
        for (i in 0..n) {
            val a = c[max(i - 1, 0)]
            val b = c[min(i + 1, n)]
            var dx = b.x - a.x
            var dy = b.y - a.y
            val len = max(hypot(dx, dy), 0.001f)
            dx /= len; dy /= len
            val w = max(width(i.toFloat() / n), 0.2f) / 2
            l += pt(c[i].x - dy * w, c[i].y + dx * w)
            r += pt(c[i].x + dy * w, c[i].y - dx * w)
        }
        val path = Path()
        path.moveTo(l[0])
        for (p in l.drop(1)) path.lineTo(p)
        for (p in r.reversed()) path.lineTo(p)
        path.close()
        val light = mutableListOf<Path>()
        if (strands > 0) {
            for (s in 1..strands) {
                val f = s.toFloat() / (strands + 1)
                val line = Path()
                for (i in 1 until n) {
                    val p = pt(l[i].x + (r[i].x - l[i].x) * f, l[i].y + (r[i].y - l[i].y) * f)
                    if (i == 1) line.moveTo(p) else line.lineTo(p)
                }
                light += line
            }
        }
        return Piece(path, light)
    }

    /** 刘海 / 发际线的样子。 */
    private sealed interface Fringe {
        /** 额头露出来；数值是发际线最高处的 y。 */
        data class Open(val y: Float) : Fringe
        /** 男生偏方的发际线。 */
        data class Square(val y: Float) : Fringe
        /** 中分：正中有一道分缝。 */
        data class Part(val y: Float) : Fringe
        /** 齐刘海；数值是下沿的 y。 */
        data class Blunt(val y: Float) : Fringe
        /** 空气刘海。 */
        data class Air(val y: Float) : Fringe
        /** 八字刘海。 */
        data object Curtain : Fringe
        /** 侧分；数值是分缝的 x。 */
        data class Side(val x: Float) : Fringe
        /** 碎刘海：下沿的 y，和小分缝的 x。 */
        data class Choppy(val y: Float, val gap: Float) : Fringe
        /** 卷刘海。 */
        data class Wavy(val y: Float) : Fringe
        /** 很短的斜刘海。 */
        data object Swept : Fringe
    }

    /** 头顶这一块：外沿绕着头骨，内沿就是发际线 / 刘海。 */
    private fun cap(
        lift: Float = 7f, side: Float = 4f, puff: Float = 3f, peak: Float = 0f,
        end: Float = 80f, burn: Float = 0f, fringe: Fringe, origin: Float? = null,
    ): Piece {
        val top = 36 - lift
        val lo = pt(cx - 24 - side, end)
        val ro = pt(cx + 24 + side, end)
        val li = pt(cx - 21.5f, end)
        val ri = pt(cx + 21.5f, end)
        val p = Path()
        p.moveTo(lo)
        p.curve(pt(cx + peak, top), pt(lo.x - puff, end - 30), pt(cx - 22 + peak * 0.5f, top))
        p.curve(ro, pt(cx + 22 + peak * 0.5f, top), pt(ro.x + puff, end - 30))
        if (burn > 0) p.lineTo(pt(cx + 23.2f, end + burn))
        p.lineTo(ri)
        var partX = cx + peak
        when (fringe) {
            is Fringe.Open -> {
                val t = fringe.y
                p.curve(pt(cx, t), pt(cx + 22.5f, end - 20), pt(cx + 15, t))
                p.curve(li, pt(cx - 15, t), pt(cx - 22.5f, end - 20))
            }
            is Fringe.Square -> {
                val t = fringe.y
                p.curve(pt(cx + 15, t + 1.5f), pt(cx + 22.5f, end - 14), pt(cx + 20.5f, t + 3))
                p.quad(pt(cx - 15, t + 1.5f), pt(cx, t - 1.5f))
                p.curve(li, pt(cx - 20.5f, t + 3), pt(cx - 22.5f, end - 14))
            }
            is Fringe.Part -> {
                val t = fringe.y
                p.curve(pt(cx + 3.5f, t + 1.5f), pt(cx + 22.5f, end - 20), pt(cx + 14, t + 1))
                p.lineTo(pt(cx, t - 8))
                p.lineTo(pt(cx - 3.5f, t + 1.5f))
                p.curve(li, pt(cx - 14, t + 1), pt(cx - 22.5f, end - 20))
                partX = cx
            }
            is Fringe.Blunt -> {
                val y = fringe.y
                p.lineTo(pt(cx + 22.5f, y + 1.5f))
                p.curve(pt(cx - 22.5f, y + 1.5f), pt(cx + 9, y - 1.5f), pt(cx - 9, y - 1.5f))
                p.lineTo(li)
            }
            is Fringe.Air -> {
                val y = fringe.y
                var last = pt(cx + 21.5f, y + 2)
                p.lineTo(last)
                for (gx in listOf(13.5f, 4.5f, -4.5f, -13.5f)) {
                    val next = pt(cx + gx, y - 11)
                    p.curve(next, pt(last.x - 2.2f, y + 4), pt(next.x + 2.2f, y + 4))
                    last = next
                }
                val final = pt(cx - 21.5f, y + 2)
                p.curve(final, pt(last.x - 2.2f, y + 4), pt(final.x + 2.2f, y + 4))
                p.lineTo(li)
            }
            Fringe.Curtain -> {
                p.curve(pt(cx, 42f), pt(cx + 17, 64f), pt(cx + 5, 55f))
                p.curve(li, pt(cx - 5, 55f), pt(cx - 17, 64f))
                partX = cx
            }
            is Fringe.Side -> {
                val px = fringe.x
                p.curve(pt(px, 40f), pt(cx + 17, 57f), pt(px + 10, 44f))
                p.curve(li, pt(px - 7, 46f), pt(cx - 22.5f, end - 20))
                partX = px
            }
            is Fringe.Choppy -> {
                val y = fringe.y
                p.lineTo(pt(cx + 22.5f, y))
                var i = 0
                var x = 19f
                val jitter = floatArrayOf(2.6f, -1.4f, 1.2f, -2.4f, 3f, -0.6f, 2f, -2f, 2.8f, -1f)
                while (x >= -19.5f) {
                    val near = abs(cx + x - fringe.gap) < 2.8f
                    p.lineTo(pt(cx + x, if (near) y - 9 else y + jitter[i % jitter.size]))
                    x -= 4.8f
                    i++
                }
                p.lineTo(pt(cx - 22.5f, y))
                p.lineTo(li)
            }
            is Fringe.Wavy -> {
                val y = fringe.y
                p.lineTo(pt(cx + 22, y - 1))
                var x = 22f
                while (x > -21) {
                    val nx = x - 7.33f
                    p.quad(pt(cx + nx, y - 1), pt(cx + (x + nx) / 2, y + 5.5f))
                    x = nx
                }
                p.lineTo(li)
            }
            Fringe.Swept -> {
                p.curve(pt(cx - 13, 46f), pt(cx + 19, 57f), pt(cx + 2, 57f))
                p.curve(li, pt(cx - 19, 48f), pt(cx - 22.5f, end - 16))
                partX = cx - 13
            }
        }
        if (burn > 0) p.lineTo(pt(cx - 23.2f, end + burn))
        p.close()

        // 发丝从分缝 / 头顶往下散开；落在头发外面的部分画的时候自己会被裁掉。
        val o = pt(origin ?: partX, top + 3)
        val light = mutableListOf<Path>()
        for (dx in listOf(-27f, -21f, -13f, -5f, 5f, 13f, 21f, 27f)) {
            val k = abs(dx) / 27
            val target = pt(cx + dx, 60 + k * k * (end - 62))
            val line = Path()
            line.moveTo(o)
            line.quad(target, pt((o.x + target.x) / 2 + (if (dx > 0) 5 else -5) * k, o.y + 3 + 6 * (1 - k)))
            light += line
        }
        // 头顶的一道光泽。
        val shine = Path()
        shine.moveTo(pt(cx - 15, top + 13))
        shine.quad(pt(cx + 15, top + 13), pt(cx, top + 4))
        return Piece(p, light, shine = mutableListOf(shine to 4.5f))
    }

    /** 背后的一大片。 */
    private fun sheet(to: Float, spread: Float = 0f, amp: Float = 0f, period: Float = 26f, grow: Float = 1f, half: Float = 30f): Piece =
        ribbon(
            left = Edge(cx - 25, cx - half - spread, -(2 + spread * 0.4f), amp, period, 0f, grow),
            right = Edge(cx + 25, cx + half + spread, 2 + spread * 0.4f, amp, period, PIf, grow),
            top = 60f, bottom = to, end = End.FLAT, strands = 0,
        )

    /** 垂到身前的左右两缕。 */
    private fun locks(
        to: Float, from: Float = 60f, spread: Float = 0f, bulge: Float = 2f,
        amp: Float = 0f, period: Float = 26f, grow: Float = 1f, inner: Float = 16f,
        curl: Boolean = false, end: End = End.ROUND, strands: Int = 2,
    ): List<Piece> {
        val out = ArrayList<Piece>()
        for (sgn in listOf(-1f, 1f)) {
            val phase = if (sgn > 0) PIf else 0f
            val outer = Edge(cx + sgn * 28, cx + sgn * (31 + spread), sgn * bulge, amp, period, phase, grow)
            val inside = Edge(cx + sgn * 20, cx + sgn * inner, 0f, amp * 0.75f, period, phase, grow)
            val tip = if (curl) (if (sgn < 0) End.CURL_RIGHT else End.CURL_LEFT) else end
            out += if (sgn < 0) ribbon(outer, inside, from, to, tip, strands) else ribbon(inside, outer, from, to, tip, strands)
        }
        return out
    }

    private fun circle(c: PointF, r: Float) = Path().apply { addOval(RectF(c.x - r, c.y - r, c.x + r, c.y + r), Path.Direction.CW) }

    private fun arc(c: PointF, r: Float, start: Float, endA: Float) = Path().apply {
        arcTo(RectF(c.x - r, c.y - r, c.x + r, c.y + r), Math.toDegrees(start.toDouble()).toFloat(), Math.toDegrees((endA - start).toDouble()).toFloat(), true)
    }

    /** 一个小卷：圆，加上里面一道 C 形的亮线。 */
    private fun curl(c: PointF, r: Float, turn: Float): Piece =
        Piece(circle(c, r), mutableListOf(arc(c, r * 0.52f, turn, turn + 3.6f)))

    /** 麻花辫：一行两瓣，左右错开半行，叠成人字纹。 */
    private fun braid(from: PointF, to: PointF, width: Float, count: Int): List<Piece> {
        val out = ArrayList<Piece>()
        val dx = (to.x - from.x) / count
        val dy = (to.y - from.y) / count
        for (i in 0 until count) {
            val w = width * (1 - 0.26f * i / count)
            for (sgn in listOf(-1f, 1f)) {
                val row = i + 0.5f + (if (sgn > 0) 0.5f else 0f)
                val c = pt(from.x + dx * row + sgn * w * 0.21f, from.y + dy * row)
                // 先转再平移
                val m = Matrix().apply {
                    setRotate(Math.toDegrees((sgn * 0.62f).toDouble()).toFloat())
                    postTranslate(c.x, c.y)
                }
                val petal = Path().apply { addOval(RectF(-w * 0.27f, -dy * 0.82f, w * 0.27f, dy * 0.82f), Path.Direction.CW) }
                petal.transform(m)
                val line = Path().apply {
                    moveTo(0f, -dy * 0.45f)
                    lineTo(0f, dy * 0.45f)
                }
                line.transform(m)
                out += Piece(petal, mutableListOf(line), mutableListOf(Path(petal)))
            }
        }
        return out
    }

    /** 简单的伪随机数，保证每次画出来都一样。 */
    private class Dice(var state: ULong) {
        fun next(): Float {
            state = state * 6364136223846793005UL + 1442695040888963407UL
            return ((state shr 33) % 10_000UL).toFloat() / 10_000f
        }
    }

    // MARK: 55 个发型

    /** 刘海 / 分缝这一组共用的中长发。 */
    private fun medium(s: Scene, fringe: Fringe, peak: Float = 0f) {
        s.back reset mutableListOf(sheet(138f))
        s.front reset (listOf(cap(peak = peak, fringe = fringe)) + locks(142f, curl = true)).toMutableList()
    }

    /** 头发全部往后梳起来的头顶。 */
    private fun pulledBack(s: Scene, fringe: Fringe = Fringe.Open(46f)) {
        s.ears = true
        s.front reset mutableListOf(cap(lift = 5.5f, side = 2.5f, puff = 2f, end = 74f, burn = 5f, fringe = fringe))
    }

    private fun men(s: Scene) {
        s.male = true
        s.ears = true
    }

    private fun stride(from: Float, through: Float, by: Float): List<Float> {
        val out = ArrayList<Float>()
        var x = from
        while (x <= through + 1e-4f) { out += x; x += by }
        return out
    }

    private val styles: Map<String, (Scene) -> Unit> = mapOf(
        "长直发" to { s ->
            s.back reset mutableListOf(sheet(170f, half = 31f))
            s.front reset (listOf(cap(lift = 6.5f, fringe = Fringe.Part(46f))) + locks(172f, bulge = 1f, inner = 13f, end = End.FLAT, strands = 3)).toMutableList()
        },
        "大波浪" to { s ->
            s.back reset mutableListOf(sheet(150f, spread = 4f, amp = 3.5f, period = 30f))
            s.front reset (listOf(cap(lift = 8f, peak = 3f, fringe = Fringe.Side(cx - 10)))
                + locks(154f, spread = 5f, bulge = 3f, amp = 4.6f, period = 30f, inner = 15f, strands = 3)).toMutableList()
        },
        "法式卷" to { s ->
            s.back reset mutableListOf(sheet(122f, spread = 6f, amp = 3.2f, period = 16f, grow = 0.7f))
            s.front reset (listOf(cap(lift = 8f, side = 5f, puff = 4f, fringe = Fringe.Air(63f)))
                + locks(127f, spread = 7f, bulge = 4f, amp = 3.8f, period = 16f, grow = 0.6f, inner = 17f, strands = 2)).toMutableList()
        },
        "羊毛卷" to { s ->
            val dice = Dice(11UL)
            s.shift = 11f
            // 背后一大团。
            s.back reset mutableListOf(Piece(Path().apply { addOval(RectF(cx - 37, 30f, cx + 37, 122f), Path.Direction.CW) }))
            var a = 0f
            while (a < 2 * PIf) {
                s.back += curl(pt(cx + 38 * cos(a), 76 + 46 * sin(a)), 7.5f, dice.next() * 6)
                a += 0.36f
            }
            // 头顶和刘海。
            s.front reset mutableListOf(cap(lift = 9f, side = 6f, puff = 5f, end = 84f, fringe = Fringe.Wavy(57f)))
            a = PIf
            while (a < 2 * PIf + 0.01f) {
                s.front += curl(pt(cx + 31 * cos(a), 58 + 31 * sin(a)), 7f, dice.next() * 6)
                a += 0.3f
            }
            for (x in stride(-18f, 18f, 9f)) {
                s.front += curl(pt(cx + x, 41 + abs(x) * 0.25f), 6.5f, dice.next() * 6)
                s.front += curl(pt(cx + x * 0.9f, 51 + abs(x) * 0.2f), 5.5f, dice.next() * 6)
            }
            // 两侧一路卷到肩上。
            for (sgn in listOf(-1f, 1f)) {
                var y = 62f
                while (y <= 120) {
                    s.front += curl(pt(cx + sgn * (28 + dice.next() * 3), y), 7.5f, dice.next() * 6)
                    if (y > 92) s.front += curl(pt(cx + sgn * (19 + dice.next() * 2), y + 3), 6f, dice.next() * 6)
                    y += 8.5f
                }
            }
        },
        "水波纹" to { s ->
            s.back reset mutableListOf(sheet(146f, spread = 2f, amp = 2.4f, period = 13f, grow = 0f))
            val pieces = (listOf(cap(lift = 7f, peak = 4f, fringe = Fringe.Side(cx - 12)))
                + locks(150f, spread = 3f, bulge = 2f, amp = 3f, period = 13f, grow = 0.15f, inner = 15f, strands = 1)).toMutableList()
            // 一道一道横着的光泽，就是"水波"。
            val bands = Piece(Path())
            var y = 67f
            while (y < 150) {
                for (sgn in listOf(-1f, 1f)) {
                    val band = Path()
                    band.moveTo(pt(cx + sgn * 16, y + 1.5f))
                    band.quad(pt(cx + sgn * 35, y - 1.5f), pt(cx + sgn * 26, y - 3.5f))
                    bands.shine += band to 3f
                }
                y += 13
            }
            pieces += bands
            s.front reset pieces
        },
        "锁骨发" to { s ->
            s.back reset mutableListOf(sheet(117f))
            s.front reset (listOf(cap(fringe = Fringe.Side(cx - 7))) + locks(121f, bulge = 3f, inner = 17.5f, curl = true)).toMutableList()
        },
        "波波头" to { s ->
            s.back reset mutableListOf(sheet(97f, half = 27f))
            s.front reset (listOf(cap(lift = 8f, side = 5f, puff = 4f, fringe = Fringe.Blunt(64f)))
                + locks(98f, spread = -2f, bulge = 6.5f, inner = 19f, end = End.ROUND)).toMutableList()
        },
        "短发" to { s ->
            s.back reset mutableListOf(sheet(86f, half = 24f))
            s.front reset (listOf(cap(lift = 7.5f, side = 4f, peak = 3f, fringe = Fringe.Side(cx - 9)))
                + locks(86f, spread = -5f, bulge = 3f, inner = 20f, end = End.TAPER, strands = 1)).toMutableList()
        },
        "精灵短发" to { s ->
            s.ears = true
            s.front reset mutableListOf(cap(lift = 6.5f, side = 2.2f, puff = 2f, peak = -3f, end = 71f, burn = 8f, fringe = Fringe.Swept))
            // 额前几缕碎发。
            s.front += tube(listOf(pt(cx - 12, 45f), pt(cx + 2, 54f), pt(cx + 14, 60f), pt(cx + 20, 63f))) { 5 * (1 - it * 0.75f) }
        },
        "高马尾" to { s ->
            pulledBack(s)
            s.shift = 16f
            s.back reset mutableListOf(tube(listOf(pt(cx + 5, 30f), pt(cx + 22, 15f), pt(cx + 41, 26f), pt(cx + 47, 60f), pt(cx + 43, 100f), pt(cx + 38, 128f)), strands = 2) { t ->
                (7 + 10 * sin(min(t * 1.5f, 1f) * PIf / 2)) * (if (t > 0.8f) 1 - (t - 0.8f) / 0.2f * 0.7f else 1f)
            })
            s.ties += RectF(cx + 9, 19.5f, cx + 17, 25.5f)
        },
        "低马尾" to { s ->
            pulledBack(s, Fringe.Part(46f))
            s.back reset mutableListOf(ribbon(Edge(cx - 22, cx - 6), Edge(cx + 22, cx + 22), 70f, 100f, End.FLAT, 0))
            s.front += tube(listOf(pt(cx + 18, 96f), pt(cx + 23, 110f), pt(cx + 26, 130f), pt(cx + 24, 154f)), strands = 2) { t ->
                (8 + 5 * sin(min(t * 2, 1f) * PIf / 2)) * (if (t > 0.75f) 1 - (t - 0.75f) / 0.25f * 0.75f else 1f)
            }
            s.ties += RectF(cx + 14.5f, 97f, cx + 23.5f, 102f)
        },
        "丸子头" to { s ->
            pulledBack(s)
            s.shift = 20f
            val bun = curl(pt(cx, 19f), 13f, 2.2f)
            bun.light += arc(pt(cx + 1, 19f), 3.5f, 0.5f, 5f)
            s.back reset mutableListOf(bun)
            // 鬓角各留一缕。
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 21.5f, 58f), pt(cx + sgn * 24.5f, 74f), pt(cx + sgn * 22.5f, 91f)), strands = 0) { 2.6f * (1 - it * 0.7f) }
            }
        },
        "双马尾" to { s ->
            s.front reset mutableListOf(cap(lift = 6.5f, side = 3f, puff = 2.5f, end = 76f, fringe = Fringe.Air(63f)))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 26, 60f), pt(cx + sgn * 37, 66f), pt(cx + sgn * 42, 92f), pt(cx + sgn * 39, 124f), pt(cx + sgn * 35, 146f)), strands = 2) { t ->
                    (7 + 8 * sin(min(t * 2.2f, 1f) * PIf / 2)) * (if (t > 0.7f) 1 - (t - 0.7f) / 0.3f * 0.75f else 1f)
                }
                s.ties += RectF(cx + sgn * 30.5f - 3.5f, 58f, cx + sgn * 30.5f + 3.5f, 67f)
            }
        },
        "公主切" to { s ->
            s.back reset mutableListOf(sheet(170f, half = 32f))
            s.front reset mutableListOf(cap(lift = 6.5f, fringe = Fringe.Blunt(64f)))
            for (sgn in listOf(-1f, 1f)) {
                // 脸颊两边齐齐剪断的一截。
                val outer = Edge(cx + sgn * 28, cx + sgn * 29.5f)
                val inside = Edge(cx + sgn * 20, cx + sgn * 14.5f)
                s.front += if (sgn < 0) ribbon(outer, inside, 60f, 93f, End.FLAT, 2) else ribbon(inside, outer, 60f, 93f, End.FLAT, 2)
                // 后面的长发从它外侧垂下去。
                val far = Edge(cx + sgn * 29.5f, cx + sgn * 33)
                val near = Edge(cx + sgn * 23.5f, cx + sgn * 21)
                s.front += if (sgn < 0) ribbon(far, near, 90f, 172f, End.FLAT, 1) else ribbon(near, far, 90f, 172f, End.FLAT, 1)
            }
        },
        "编发" to { s ->
            s.ears = false
            s.back reset mutableListOf(ribbon(Edge(cx - 24, cx - 22), Edge(cx + 24, cx + 14), 60f, 104f, End.FLAT, 0))
            s.front reset mutableListOf(cap(lift = 6.5f, fringe = Fringe.Part(46f)))
            // 左边的头发收成一股。
            s.front += ribbon(Edge(cx - 28, cx - 30, -2f), Edge(cx - 20, cx - 17), 60f, 96f, End.FLAT, 2)
            s.front += ribbon(Edge(cx + 20, cx + 19), Edge(cx + 28, cx + 24, 1f), 60f, 90f, End.TAPER, 1)
            s.front += braid(pt(cx - 24, 91f), pt(cx - 26.5f, 143f), 17f, 6)
            s.front += tube(listOf(pt(cx - 26.5f, 146f), pt(cx - 27, 153f), pt(cx - 25.5f, 161f)), strands = 1) { 8 * (1 - it * 0.65f) }
            s.ties += RectF(cx - 31.5f, 144f, cx - 21.5f, 148.5f)
        },
        "空气刘海" to { s -> medium(s, Fringe.Air(63f)) },
        "八字刘海" to { s ->
            medium(s, Fringe.Curtain)
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 1.5f, 41f), pt(cx + sgn * 9, 51f), pt(cx + sgn * 18, 64f), pt(cx + sgn * 24, 79f), pt(cx + sgn * 28.5f, 87f)), strands = 2) { t ->
                    4 + 5 * sin(t * PIf) + (if (t > 0.8f) -(t - 0.8f) * 12 else 0f)
                }
            }
        },
        "齐刘海" to { s -> medium(s, Fringe.Blunt(64f)) },
        "中分" to { s ->
            medium(s, Fringe.Part(47f))
            // 分缝。
            val line = Path()
            line.moveTo(cx, 30.5f)
            line.lineTo(cx, 40f)
            s.front += Piece(Path(), dark = mutableListOf(line))
        },
        "侧分" to { s -> medium(s, Fringe.Side(cx - 13), peak = 5f) },
        // 下面 30 个
        "层次长发" to { s ->
            s.back reset mutableListOf(sheet(152f, spread = 2f))
            s.front reset (listOf(cap(lift = 7.5f, fringe = Fringe.Curtain)) + locks(150f, spread = 3f, inner = 17f, end = End.TAPER, strands = 2)
                + locks(112f, spread = 4f, bulge = 4f, inner = 22f, end = End.TAPER, strands = 1)).toMutableList()
        },
        "韩系大卷" to { s ->
            s.back reset mutableListOf(sheet(156f, spread = 6f, amp = 4f, period = 36f))
            s.front reset (listOf(cap(lift = 9f, side = 5f, puff = 4f, fringe = Fringe.Curtain))
                + locks(158f, spread = 7f, bulge = 4f, amp = 5.5f, period = 36f, inner = 15f, strands = 3)).toMutableList()
        },
        "木马卷" to { s ->
            s.back reset mutableListOf(sheet(150f, spread = 3f))
            s.front reset mutableListOf(cap(lift = 7f, fringe = Fringe.Air(63f)))
            for (x in listOf(-27f, -19f, 19f, 27f)) {
                var y = 74f
                while (y < 152) {
                    s.front += curl(pt(cx + x, y), 6.4f, if (x > 0) 1f else 4f)
                    y += 8
                }
            }
        },
        "蛋卷头" to { s ->
            s.back reset mutableListOf(sheet(148f, spread = 7f, amp = 2.6f, period = 8f, grow = 0.2f))
            s.front reset (listOf(cap(lift = 9f, side = 6f, puff = 5f, fringe = Fringe.Part(46f)))
                + locks(150f, spread = 8f, bulge = 4f, amp = 2.8f, period = 8f, grow = 0.1f, inner = 15f, strands = 3)).toMutableList()
        },
        "螺旋卷" to { s ->
            s.back reset mutableListOf(sheet(148f, spread = 3f))
            s.front reset mutableListOf(cap(lift = 7f, peak = 3f, fringe = Fringe.Side(cx - 9)))
            for (x in listOf(-30f, -22f, 22f, 30f)) {
                s.front += tube((0..8).map { pt(cx + x + (if (it % 2 == 0) -3 else 3), 64 + it * 11f) }, strands = 1) { 8f }
            }
        },
        "港风卷发" to { s ->
            s.back reset mutableListOf(sheet(140f, spread = 10f, amp = 4f, period = 24f))
            s.front reset (listOf(cap(lift = 13f, side = 7f, puff = 6f, peak = 5f, fringe = Fringe.Side(cx - 12)))
                + locks(144f, spread = 10f, bulge = 6f, amp = 5f, period = 24f, inner = 16f, strands = 3)).toMutableList()
        },
        "复古手推波" to { s ->
            s.back reset mutableListOf(sheet(92f, half = 27f))
            val pieces = (listOf(cap(lift = 6f, side = 3f, peak = 5f, fringe = Fringe.Side(cx - 13)))
                + locks(94f, spread = -3f, bulge = 4f, amp = 3.4f, period = 14f, grow = 0.1f, inner = 20f, curl = true, strands = 1)).toMutableList()
            val bands = Piece(Path())
            var y = 44f
            while (y < 92) {
                for (sgn in listOf(-1f, 1f)) {
                    val band = Path()
                    band.moveTo(pt(cx + sgn * 14, y + 2))
                    band.quad(pt(cx + sgn * 30, y - 1), pt(cx + sgn * 23, y - 4))
                    bands.shine += band to 2.6f
                }
                y += 11
            }
            pieces += bands
            s.front reset pieces
        },
        "内扣长发" to { s ->
            s.back reset mutableListOf(sheet(148f))
            s.front reset (listOf(cap(fringe = Fringe.Part(46f))) + locks(150f, spread = 1f, bulge = 4f, inner = 14f, curl = true, strands = 3)).toMutableList()
        },
        "一刀切" to { s ->
            s.back reset mutableListOf(sheet(128f, half = 32f))
            s.front reset (listOf(cap(lift = 6.5f, fringe = Fringe.Part(46f))) + locks(128f, spread = 2f, bulge = 1f, inner = 13f, end = End.FLAT, strands = 3)).toMutableList()
        },
        "法式短发" to { s ->
            s.back reset mutableListOf(sheet(95f, spread = 1f, half = 27f))
            s.front reset (listOf(cap(lift = 8f, side = 5f, puff = 4f, fringe = Fringe.Air(62f)))
                + locks(97f, spread = 0f, bulge = 5f, amp = 1.8f, period = 18f, inner = 19f, curl = true)).toMutableList()
        },
        "鲻鱼头" to { s ->
            s.back reset mutableListOf(sheet(124f, half = 25f))
            s.front reset mutableListOf(cap(lift = 9.5f, side = 4f, puff = 4f, fringe = Fringe.Choppy(60f, cx + 5), origin = cx + 5))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 25, 66f), pt(cx + sgn * 25, 96f), pt(cx + sgn * 24, 116f), pt(cx + sgn * 30, 128f)), strands = 1) { 9 * (1 - it * 0.75f) }
            }
        },
        "水母头" to { s ->
            s.back reset mutableListOf(sheet(168f, half = 22f))
            s.front reset (listOf(cap(lift = 8.5f, side = 6f, puff = 5f, fringe = Fringe.Blunt(64f)))
                + locks(92f, spread = 1f, bulge = 7f, inner = 19f, end = End.ROUND)).toMutableList()
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 25, 90f), pt(cx + sgn * 25, 130f), pt(cx + sgn * 24, 168f)), strands = 2) { 8 * (1 - it * 0.4f) }
            }
        },
        "外翘短发" to { s ->
            s.back reset mutableListOf(sheet(94f, half = 25f))
            s.front reset (listOf(cap(lift = 7.5f, fringe = Fringe.Air(62f))) + locks(90f, spread = -3f, bulge = 2f, inner = 20f, strands = 1)).toMutableList()
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 25, 78f), pt(cx + sgn * 27, 92f), pt(cx + sgn * 37, 98f)), strands = 1) { 9 * (1 - it * 0.8f) }
            }
        },
        "短卷发" to { s ->
            val dice = Dice(23UL)
            s.shift = 6f
            s.back reset mutableListOf(Piece(Path().apply { addOval(RectF(cx - 33, 34f, cx + 33, 100f), Path.Direction.CW) }))
            s.front reset mutableListOf(cap(lift = 9f, side = 5f, puff = 5f, end = 80f, fringe = Fringe.Wavy(57f)))
            for (sgn in listOf(-1f, 1f)) {
                for (y in stride(58f, 96f, 8f)) s.front += curl(pt(cx + sgn * (29 + dice.next() * 3), y), 7f, dice.next() * 6)
            }
            for (x in stride(-18f, 18f, 9f)) s.front += curl(pt(cx + x, 38 + abs(x) * 0.25f), 6f, dice.next() * 6)
        },
        "锁骨内扣" to { s ->
            s.back reset mutableListOf(sheet(114f, spread = 1f))
            s.front reset (listOf(cap(fringe = Fringe.Air(63f))) + locks(116f, spread = 1f, bulge = 4.5f, inner = 16f, curl = true)).toMutableList()
        },
        "低丸子头" to { s ->
            pulledBack(s, Fringe.Part(46f))
            s.back reset mutableListOf(curl(pt(cx + 4, 98f), 15f, 2f))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 21, 56f), pt(cx + sgn * 25, 74f), pt(cx + sgn * 22, 94f)), strands = 0) { 3 * (1 - it * 0.7f) }
            }
        },
        "双丸子头" to { s ->
            pulledBack(s, Fringe.Air(62f))
            s.shift = 16f
            s.back reset mutableListOf(curl(pt(cx - 21, 25f), 11f, 1f), curl(pt(cx + 21, 25f), 11f, 4f))
        },
        "半扎丸子" to { s ->
            medium(s, Fringe.Part(46f))
            s.shift = 14f
            s.back += curl(pt(cx, 24f), 11f, 2.2f)
        },
        "公主头" to { s ->
            medium(s, Fringe.Part(46f))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 10, 40f), pt(cx + sgn * 23, 48f), pt(cx + sgn * 30, 62f)), strands = 2) { 9 - 3 * it }
            }
            s.ties += RectF(cx - 33, 60f, cx - 27, 66f)
            s.ties += RectF(cx + 27, 60f, cx + 33, 66f)
        },
        "侧马尾" to { s ->
            pulledBack(s, Fringe.Side(cx + 10))
            s.front += tube(listOf(pt(cx - 20, 88f), pt(cx - 28, 100f), pt(cx - 30, 126f), pt(cx - 26, 158f)), strands = 2) { t ->
                (8 + 7 * sin(min(t * 2, 1f) * PIf / 2)) * (if (t > 0.75f) 1 - (t - 0.75f) / 0.25f * 0.75f else 1f)
            }
            s.ties += RectF(cx - 26, 89f, cx - 16, 95f)
        },
        "鱼骨辫" to { s ->
            s.back reset mutableListOf(ribbon(Edge(cx - 22, cx - 12), Edge(cx + 24, cx + 22), 60f, 104f, End.FLAT, 0))
            s.front reset mutableListOf(cap(lift = 6.5f, fringe = Fringe.Part(46f)))
            s.front += ribbon(Edge(cx + 20, cx + 17), Edge(cx + 28, cx + 30, 2f), 60f, 94f, End.FLAT, 2)
            s.front += braid(pt(cx + 24, 90f), pt(cx + 26, 148f), 18f, 11)
            s.ties += RectF(cx + 21, 148f, cx + 31, 152.5f)
        },
        "双麻花辫" to { s ->
            s.front reset mutableListOf(cap(lift = 6.5f, side = 3f, end = 78f, fringe = Fringe.Part(46f)))
            for (sgn in listOf(-1f, 1f)) {
                s.front += braid(pt(cx + sgn * 25, 76f), pt(cx + sgn * 29, 146f), 15f, 8)
                s.ties += RectF(cx + sgn * 29 - 4.5f, 146f, cx + sgn * 29 + 4.5f, 150.5f)
            }
        },
        "拳击辫" to { s ->
            pulledBack(s, Fringe.Part(46f))
            for (sgn in listOf(-1f, 1f)) {
                s.front += braid(pt(cx + sgn * 9, 34f), pt(cx + sgn * 24, 70f), 11f, 5)
                s.front += braid(pt(cx + sgn * 25, 78f), pt(cx + sgn * 27, 140f), 11f, 8)
            }
        },
        "新娘盘发" to { s ->
            pulledBack(s, Fringe.Side(cx - 9))
            s.back reset mutableListOf(curl(pt(cx - 10, 96f), 11f, 1f), curl(pt(cx + 10, 96f), 11f, 3f), curl(pt(cx, 104f), 10f, 5f))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 22, 58f), pt(cx + sgn * 27, 70f), pt(cx + sgn * 23, 82f), pt(cx + sgn * 27, 94f), pt(cx + sgn * 24, 104f)), strands = 0) { 3.4f * (1 - it * 0.6f) }
            }
        },
        "泡泡马尾" to { s ->
            pulledBack(s)
            s.shift = 16f
            var y = 24f
            for (i in 0 until 5) {
                s.back += curl(pt(cx + 24 + i * 4, y + 6), 11f, i.toFloat())
                s.ties += RectF(cx + 20 + i * 4, y - 5, cx + 28 + i * 4, y - 1)
                y += 21
            }
        },
        "脏辫" to { s ->
            s.back reset mutableListOf(sheet(150f, spread = 1f))
            s.front reset mutableListOf(cap(lift = 6f, fringe = Fringe.Open(46f)))
            for (x in stride(-32f, 32f, 5.8f)) {
                if (abs(x) > 17) s.front += braid(pt(cx + x * 0.86f, 58f), pt(cx + x, 152f), 6f, 13)
            }
        },
        "法式刘海" to { s ->
            medium(s, Fringe.Curtain)
            s.front += tube(listOf(pt(cx - 3, 42f), pt(cx - 9, 54f), pt(cx - 11, 63f)), strands = 1) { 8 * (1 - it * 0.5f) }
            s.front += tube(listOf(pt(cx + 3, 42f), pt(cx + 9, 54f), pt(cx + 11, 63f)), strands = 1) { 8 * (1 - it * 0.5f) }
        },
        "眉上刘海" to { s -> medium(s, Fringe.Blunt(55f)) },
        "龙须刘海" to { s ->
            medium(s, Fringe.Part(46f))
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 2, 40f), pt(cx + sgn * 14, 54f), pt(cx + sgn * 17, 74f), pt(cx + sgn * 15, 92f)), strands = 0) { 3.2f * (1 - it * 0.6f) }
            }
        },
        "大光明" to { s ->
            s.ears = true
            s.back reset mutableListOf(sheet(140f))
            s.front reset mutableListOf(cap(lift = 8f, side = 2.5f, puff = 2f, end = 72f, fringe = Fringe.Open(42f), origin = cx))
        },
        "寸头" to { s ->
            men(s)
            s.pale = true
            val c = cap(lift = 2.6f, side = 1.2f, puff = 0.8f, end = 70f, fringe = Fringe.Square(46.5f))
            c.light.clear()
            c.shine.clear()
            s.front reset mutableListOf(c)
        },
        "背头" to { s ->
            men(s)
            val c = cap(lift = 11.5f, side = 1.8f, puff = 1.2f, end = 71f, burn = 5f, fringe = Fringe.Square(47.5f), origin = cx)
            // 往后梳的纹路。
            for (dx in listOf(-14f, -7f, 0f, 7f, 14f)) {
                val line = Path()
                line.moveTo(cx + dx, 47f)
                line.quadTo(cx + dx * 1.15f, 35f, cx + dx * 0.55f, 27f)
                c.dark += line
            }
            s.front reset mutableListOf(c)
        },
        "纹理烫" to { s ->
            men(s)
            val dice = Dice(5UL)
            s.shift = 7f
            s.front reset mutableListOf(cap(lift = 9f, side = 2.6f, puff = 2.5f, end = 70f, burn = 4f, fringe = Fringe.Wavy(56f)))
            var a = PIf * 1.08f
            while (a < PIf * 1.93f) {
                s.front += curl(pt(cx + 26 * cos(a), 52 + 25 * sin(a)), 5.6f, dice.next() * 6)
                a += 0.27f
            }
            for (x in stride(-15f, 15f, 7.5f)) {
                s.front += curl(pt(cx + x, 37 + abs(x) * 0.2f), 5.2f, dice.next() * 6)
                s.front += curl(pt(cx + x * 0.95f, 47 + abs(x) * 0.15f), 4.8f, dice.next() * 6)
            }
        },
        "微分碎盖" to { s ->
            men(s)
            s.front reset mutableListOf(cap(lift = 8.5f, side = 3.2f, puff = 3.2f, end = 72f, burn = 3f, fringe = Fringe.Choppy(63f, cx - 6), origin = cx - 6))
        },
        "狼尾" to { s ->
            men(s)
            s.back reset mutableListOf(ribbon(Edge(cx - 23, cx - 24), Edge(cx + 23, cx + 24), 66f, 116f, End.FLAT, 0))
            s.front reset mutableListOf(cap(lift = 8.5f, side = 3.4f, puff = 3f, end = 76f, burn = 4f, fringe = Fringe.Choppy(61f, cx + 6), origin = cx + 6))
            // 后颈留长，发尾往外翘。
            for (sgn in listOf(-1f, 1f)) {
                s.front += tube(listOf(pt(cx + sgn * 25, 68f), pt(cx + sgn * 25.5f, 94f), pt(cx + sgn * 28, 112f), pt(cx + sgn * 36, 121f)), strands = 1) { t ->
                    10 * (1 - t * 0.8f) * min(1f, 0.5f + t * 3)
                }
                s.front += tube(listOf(pt(cx + sgn * 21, 98f), pt(cx + sgn * 21, 112f), pt(cx + sgn * 26, 124f)), strands = 1) { t ->
                    8.5f * (1 - t * 0.8f)
                }
            }
        },
    )

    // MARK: 画

    private fun fillPaint(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }

    private fun strokePaint(color: Int, width: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeWidth = width
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private fun oval(x: Float, y: Float, w: Float, h: Float) = RectF(x, y, x + w, y + h)

    private fun draw(scene: Scene, c: Canvas) {
        // 背景：暖灰，头后面带一点柔光。
        c.drawRect(0f, 0f, W, H, Paint().apply {
            shader = LinearGradient(0f, 0f, 0f, H, rgb(0.86f, 0.82f, 0.77f), rgb(0.73f, 0.69f, 0.64f), Shader.TileMode.CLAMP)
        })
        c.drawCircle(cx, 66f, 78f, Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = RadialGradient(cx, 66f, 78f, rgb(1f, 0.98f, 0.95f, 0.42f), rgb(1f, 0.98f, 0.95f, 0f), Shader.TileMode.CLAMP)
        })

        // 人像以底边中点为准放大一点，头像把画面占满。
        c.save()
        c.translate(cx, H + scene.shift)
        c.scale(1.14f, 1.14f)
        c.translate(-cx, -H)

        paint(scene.back, behind = true, pale = scene.pale, c = c)
        body(scene.male, c)
        if (scene.ears) {
            val p = fillPaint(ink(Ink.skinShade))
            for (sgn in listOf(-1f, 1f)) c.drawOval(oval(cx + sgn * 24.6f - 3.4f, 71f, 6.8f, 12f), p)
        }
        face(scene.male, c)
        paint(scene.front, behind = false, pale = scene.pale, c = c)
        for (tie in scene.ties) {
            val r = min(tie.width(), tie.height()) / 2
            c.drawRoundRect(tie, r, r, fillPaint(rgb(0.80f, 0.36f, 0.38f)))
        }
        c.restore()
    }

    /** 把一组头发画成一个整体：先平涂，再只在头发上叠明暗和发丝。 */
    private fun paint(pieces: List<Piece>, behind: Boolean, pale: Boolean, c: Canvas) {
        if (pieces.isEmpty()) return
        c.saveLayer(null, null)
        val base = fillPaint(ink(if (pale) Ink.stubble else Ink.hair))
        for (piece in pieces) if (!piece.fill.isEmpty) c.drawPath(piece.fill, base)
        val atop = PorterDuffXfermode(PorterDuff.Mode.SRC_ATOP)
        if (!pale) {
            val g = Paint().apply {
                shader = LinearGradient(
                    0f, 20f, 0f, H,
                    intArrayOf(ink(Ink.light, 0.34f), ink(Ink.hair, 0f), ink(Ink.dark, 0.5f)),
                    floatArrayOf(0f, 0.42f, 1f), Shader.TileMode.CLAMP,
                )
                xfermode = atop
            }
            c.drawRect(-W, -H, W * 2, H * 2, g)
        }
        if (behind) {
            c.drawRect(-W, -H, W * 2, H * 2, fillPaint(ink(Ink.dark, 0.38f)).apply { xfermode = atop })
        }
        for (piece in pieces) {
            for ((path, width) in piece.shine) {
                c.drawPath(path, strokePaint(ink(Ink.light, 0.2f), width).apply { xfermode = atop })
            }
        }
        val light = strokePaint(ink(Ink.light, 0.36f), 0.9f).apply { xfermode = atop }
        for (piece in pieces) for (line in piece.light) c.drawPath(line, light)
        val dark = strokePaint(ink(Ink.dark, 0.55f), 0.9f).apply { xfermode = atop }
        for (piece in pieces) for (line in piece.dark) c.drawPath(line, dark)
        c.restore()
    }

    private fun body(male: Boolean, c: Canvas) {
        val neck = if (male) 11.5f else 8.5f
        val half = if (male) 58f else 47f
        val top = if (male) 113f else 117f
        val shoulders = Path()
        shoulders.moveTo(cx - half, H)
        shoulders.lineTo(cx - half, top + 24)
        shoulders.cubicTo(cx - half, top + 9, cx - neck - 13, top + 6, cx - neck - 1, top)
        shoulders.lineTo(cx + neck + 1, top)
        shoulders.cubicTo(cx + neck + 13, top + 6, cx + half, top + 9, cx + half, top + 24)
        shoulders.lineTo(cx + half, H)
        shoulders.close()
        c.drawPath(shoulders, fillPaint(if (male) rgb(0.31f, 0.35f, 0.41f) else rgb(0.965f, 0.945f, 0.915f)))
        // 领口。
        c.save()
        c.clipPath(shoulders)
        if (male) {
            val r = oval(cx - neck - 3, top - 8, (neck + 3) * 2, 17f)
            c.drawOval(r, fillPaint(ink(Ink.skin)))
            c.drawOval(r, strokePaint(rgb(0.24f, 0.27f, 0.32f), 2f))
        } else {
            c.drawOval(oval(cx - neck - 10, top - 14, (neck + 10) * 2, 30f), fillPaint(ink(Ink.skin)))
        }
        c.restore()

        // 脖子，下巴底下压一点阴影。
        val neckRect = RectF(cx - neck, 90f, cx + neck, 90f + top - 90 + 1.5f)
        c.drawRect(neckRect, fillPaint(ink(Ink.skin)))
        c.save()
        c.clipRect(neckRect)
        c.drawOval(oval(cx - 22, 92f, 44f, 20f), fillPaint(ink(Ink.skinShade)))
        c.restore()
    }

    private fun facePath(male: Boolean): Path {
        val jaw = if (male) 21.5f else 18.5f
        val chinY = if (male) 106f else 105f
        val chin = if (male) 12.5f else 7f
        val p = Path()
        p.moveTo(cx, 36f)
        p.cubicTo(cx + 18, 36f, cx + 24, 50f, cx + 24, 68f)
        p.cubicTo(cx + 24, 78f, cx + jaw + 2.5f, 85f, cx + jaw, 91f)
        p.cubicTo(cx + jaw - 3.5f, 100f, cx + chin, chinY, cx, chinY)
        p.cubicTo(cx - chin, chinY, cx - jaw + 3.5f, 100f, cx - jaw, 91f)
        p.cubicTo(cx - jaw - 2.5f, 85f, cx - 24, 78f, cx - 24, 68f)
        p.cubicTo(cx - 24, 50f, cx - 18, 36f, cx, 36f)
        p.close()
        return p
    }

    private fun face(male: Boolean, c: Canvas) {
        c.drawPath(facePath(male), fillPaint(ink(Ink.skin)))
        // 腮红。
        if (!male) {
            val blush = fillPaint(rgb(0.96f, 0.58f, 0.56f, 0.24f))
            for (sgn in listOf(-1f, 1f)) c.drawOval(oval(cx + sgn * 13.5f - 5, 79f, 10f, 6.5f), blush)
        }
        // 眉毛。
        val brow = strokePaint(ink(Ink.hair, 0.8f), if (male) 1.9f else 1.2f)
        for (sgn in listOf(-1f, 1f)) {
            val p = Path()
            p.moveTo(cx + sgn * 5.5f, 66.2f)
            p.quadTo(cx + sgn * 10.5f, if (male) 64.6f else 63.8f, cx + sgn * 14.5f, if (male) 65.6f else 66f)
            c.drawPath(p, brow)
        }
        // 眼睛。
        val eye = fillPaint(ink(Ink.dark))
        val lash = strokePaint(ink(Ink.dark), 0.9f)
        for (sgn in listOf(-1f, 1f)) {
            c.drawOval(oval(cx + sgn * 9.8f - 1.9f, 70.4f, 3.8f, 4.6f), eye)
            if (!male) {
                val p = Path()
                p.moveTo(cx + sgn * 6.6f, 71.6f)
                p.quadTo(cx + sgn * 10, 68.8f, cx + sgn * 13.8f, 70.6f)
                c.drawPath(p, lash)
            }
        }
        // 鼻子只点一下影子。
        val nose = Path()
        nose.moveTo(cx - 1.8f, 83.5f)
        nose.quadTo(cx, 85f, cx + 1.8f, 83.5f)
        c.drawPath(nose, strokePaint(ink(Ink.skinShade), 1.1f))
        // 嘴。
        if (male) {
            val p = Path()
            p.moveTo(cx - 4.2f, 92.5f)
            p.quadTo(cx, 94f, cx + 4.2f, 92.5f)
            c.drawPath(p, strokePaint(rgb(0.70f, 0.45f, 0.40f), 1.3f))
        } else {
            val lips = Path()
            lips.moveTo(cx - 4.4f, 91.6f)
            lips.quadTo(cx - 2, 89.8f, cx, 90.6f)
            lips.quadTo(cx + 2, 89.8f, cx + 4.4f, 91.6f)
            lips.quadTo(cx, 95.6f, cx - 4.4f, 91.6f)
            c.drawPath(lips, fillPaint(rgb(0.83f, 0.42f, 0.43f)))
        }
    }
}
