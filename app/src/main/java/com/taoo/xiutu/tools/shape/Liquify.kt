package com.taoo.xiutu.tools.shape

import android.graphics.Bitmap
import com.taoo.xiutu.editor.EditOp
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 手动美体（液化）里手指划过的一小段。坐标是归一化的图片坐标，半径以图片长边为 1。 */
data class LiquifySegment(
    val from: V2,
    val to: V2,
    val radius: Float,
    val strength: Float,
    /** true = 恢复笔刷：把这一片推过的变形抹回去。 */
    val restore: Boolean,
    /** 属于第几笔，撤销时按笔撤。 */
    val stroke: Int,
)

/**
 * 位移场：一张低分辨率的网格，每格记录"这里的画面要从哪边取"。
 * 位移以图片长边为单位、y 朝下，所以同一组笔画在预览图和原图上效果一致。
 */
class LiquifyGrid(imageW: Int, imageH: Int) {
    val width: Int
    val height: Int
    private val unitW: Float
    private val unitH: Float
    private val dx: FloatArray
    private val dy: FloatArray
    private val oldX: FloatArray
    private val oldY: FloatArray

    init {
        val m = max(max(imageW, imageH), 1).toFloat()
        width = max(2, (imageW / m * LONG_SIDE).roundToInt())
        height = max(2, (imageH / m * LONG_SIDE).roundToInt())
        unitW = imageW / m
        unitH = imageH / m
        dx = FloatArray(width * height)
        dy = FloatArray(width * height)
        oldX = FloatArray(width * height)
        oldY = FloatArray(width * height)
    }

    fun reset() {
        dx.fill(0f)
        dy.fill(0f)
    }

    fun add(s: LiquifySegment) {
        val m = max(width, height).toFloat()
        val ax = width / m
        val ay = height / m
        val r = max(s.radius, 2 / m)
        val k = s.strength
        if (s.restore) {
            stamp(s.to.x * ax, s.to.y * ay, 0f, 0f, r, k, true)
            return
        }
        // 一次挪得太远会把画面折叠出硬边，所以拆成几小步，每步不超过笔刷半径的四分之一。
        val fx = s.from.x * ax
        val fy = s.from.y * ay
        val tx = s.to.x * ax
        val ty = s.to.y * ay
        val length = hypot(tx - fx, ty - fy) * k
        val steps = max(1, min(24, ceil(length / (r * 0.25f)).toInt()))
        val vx = (tx - fx) / steps
        val vy = (ty - fy) / steps
        for (i in 1..steps) stamp(fx + vx * i, fy + vy * i, vx, vy, r, k, false)
    }

    /** 在 (cx, cy) 处盖一个笔刷印。坐标和位移都以长边为单位，y 朝下。 */
    private fun stamp(cx: Float, cy: Float, vx: Float, vy: Float, r: Float, k: Float, restore: Boolean) {
        val m = max(width, height).toFloat()
        val i0 = max(0, ((cx - r) * m).toInt())
        val i1 = min(width - 1, ((cx + r) * m).toInt() + 1)
        val j0 = max(0, ((cy - r) * m).toInt())
        val j1 = min(height - 1, ((cy + r) * m).toInt() + 1)
        if (i0 > i1 || j0 > j1) return
        if (!restore) {
            dx.copyInto(oldX)
            dy.copyInto(oldY)
        }
        val out = FloatArray(2)
        for (j in j0..j1) {
            val ddy = (j + 0.5f) / m - cy
            for (i in i0..i1) {
                val ddx = (i + 0.5f) / m - cx
                val d2 = (ddx * ddx + ddy * ddy) / (r * r)
                if (d2 >= 1) continue
                // 中间平、边缘缓的钟形衰减，推出来的轮廓是一条顺的弧线。
                val w = (1 - d2) * (1 - d2) * (1 - d2) * k
                val p = j * width + i
                if (restore) {
                    dx[p] *= 1 - w
                    dy[p] *= 1 - w
                } else {
                    // 这一格的内容来自手指来的方向；之前推过的变形也跟着一起带过来，叠加多次也不会起皱。
                    sample(i - vx * w * m, j - vy * w * m, out)
                    dx[p] = out[0] - vx * w
                    dy[p] = out[1] - vy * w
                }
            }
        }
    }

    /** 从旧的位移场里取样（双线性）。 */
    private fun sample(x: Float, y: Float, out: FloatArray) {
        val px = x.coerceIn(0f, (width - 1).toFloat())
        val py = y.coerceIn(0f, (height - 1).toFloat())
        val x0 = px.toInt()
        val y0 = py.toInt()
        val x1 = min(x0 + 1, width - 1)
        val y1 = min(y0 + 1, height - 1)
        val fx = px - x0
        val fy = py - y0
        fun lerp(a: FloatArray): Float {
            val top = a[y0 * width + x0] + (a[y0 * width + x1] - a[y0 * width + x0]) * fx
            val bottom = a[y1 * width + x0] + (a[y1 * width + x1] - a[y1 * width + x0]) * fx
            return top + (bottom - top) * fy
        }
        out[0] = lerp(oldX)
        out[1] = lerp(oldY)
    }

    fun replay(segments: List<LiquifySegment>) {
        reset()
        for (s in segments) add(s)
    }

    /** 拷一份当前的位移场，交给后台线程渲染。 */
    fun snapshot(): WarpField {
        var peak = 0f
        for (i in dx.indices) peak = max(peak, max(abs(dx[i]), abs(dy[i])))
        return WarpField(width, height, dx.copyOf(), dy.copyOf(), unitW, unitH, peak)
    }

    companion object {
        const val LONG_SIDE = 320
    }
}

class LiquifyParams(
    val segments: List<LiquifySegment> = emptyList(),
    /** 固定背景用的人像蒙版；null = 不固定。 */
    val lockMask: Bitmap? = null,
) {
    val isIdentity: Boolean get() = segments.none { !it.restore }

    fun apply(src: Bitmap): Bitmap {
        if (isIdentity) return src
        val grid = LiquifyGrid(src.width, src.height)
        grid.replay(segments)
        return Warp.render(src, grid.snapshot(), lockMask)
    }
}

/** 历史里的一步手动美体。 */
class LiquifyOp(val params: LiquifyParams) : EditOp {
    override val skipsColor: Boolean get() = true
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
}
