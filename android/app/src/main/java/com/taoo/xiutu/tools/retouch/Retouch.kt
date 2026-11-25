package com.taoo.xiutu.tools.retouch

import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Shader
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.tools.mosaic.MosaicStroke
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 手动消除的一笔补出来的一块：贴在画面的 rect 上（归一化，左上原点）；图的透明度就是羽化的范围。 */
class RetouchPatch(val rect: RectF, val image: Bitmap) {
    fun draw(c: Canvas, w: Float, h: Float) {
        c.drawBitmap(image, null, RectF(rect.left * w, rect.top * h, rect.right * w, rect.bottom * h), PAINT)
    }

    private companion object {
        val PAINT = Paint(Paint.FILTER_BITMAP_FLAG)
    }
}

/** 手动消除确认后的一步。 */
class RetouchOp(val patches: List<RetouchPatch>) : EditOp {
    override fun apply(src: Bitmap): Bitmap {
        if (patches.isEmpty()) return src
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        val c = Canvas(out)
        for (p in patches) p.draw(c, out.width.toFloat(), out.height.toFloat())
        return out
    }
}

/** 都在后台线程调用。full = 当前步骤之后的整张大图，patches = 这个工具里已经补好的。 */
object RetouchEngine {
    /** 一笔的外接框（像素，整数），四周留余量。 */
    internal fun box(stroke: MosaicStroke, w: Int, h: Int, margin: Float): IntArray {
        val xs = FloatArray(stroke.points.size) { stroke.points[it].x }
        val ys = FloatArray(stroke.points.size) { stroke.points[it].y }
        return box(xs, ys, stroke.width, w, h, margin)
    }

    internal fun box(xs: FloatArray, ys: FloatArray, width: Float, w: Int, h: Int, margin: Float): IntArray {
        val half = width * max(w, h) / 2
        var l = xs.min() * w - half
        var t = ys.min() * h - half
        var r = xs.max() * w + half
        var b = ys.max() * h + half
        val mx = margin * max(r - l, half * 2) + 2
        val my = margin * max(b - t, half * 2) + 2
        l -= mx; r += mx; t -= my; b += my
        return intArrayOf(
            floor(max(l, 0f)).toInt(), floor(max(t, 0f)).toInt(), ceil(min(r, w.toFloat())).toInt(), ceil(min(b, h.toFloat())).toInt(),
        )
    }

    private fun normalized(box: IntArray, w: Int, h: Int) =
        RectF(box[0].toFloat() / w, box[1].toFloat() / h, box[2].toFloat() / w, box[3].toFloat() / h)

    /** 裁出一块，最长 side；dx、dy = 从偏开多少的地方取（像素），超出画面的地方用边缘像素。 */
    private fun piece(full: Bitmap, patches: List<RetouchPatch>, box: IntArray, side: Int, dx: Float = 0f, dy: Float = 0f): Bitmap? {
        val w = box[2] - box[0]
        val h = box[3] - box[1]
        if (w < 4 || h < 4) return null
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        val shader = BitmapShader(full, Shader.TileMode.CLAMP, Shader.TileMode.CLAMP)
        shader.setLocalMatrix(Matrix().apply { setTranslate(-box[0] - dx, -box[1] - dy) })
        c.drawRect(0f, 0f, w.toFloat(), h.toFloat(), Paint(Paint.FILTER_BITMAP_FLAG).apply { this.shader = shader })
        c.translate(-box[0] - dx, -box[1] - dy)
        for (p in patches) p.draw(c, full.width.toFloat(), full.height.toFloat())
        return Img.downscale(out, side)
    }

    /** 这一笔在那一块里的蒙版。soft：边缘羽化多少（占笔刷直径）。fw、fh：整张的大小。 */
    fun mask(stroke: MosaicStroke, box: IntArray, fw: Int, fh: Int, w: Int, h: Int, soft: Float, grow: Float = 0f): Mask8 {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.BLACK)
        val kx = w.toFloat() / (box[2] - box[0])
        val ky = h.toFloat() / (box[3] - box[1])
        val width = stroke.width * max(fw, fh) * kx
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            style = Paint.Style.STROKE
            strokeCap = Paint.Cap.ROUND
            strokeJoin = Paint.Join.ROUND
            strokeWidth = max(width * (1 - soft) + grow, 1f)
        }
        val path = Path()
        stroke.points.forEachIndexed { i, p ->
            val x = (p.x * fw - box[0]) * kx
            val y = (p.y * fh - box[1]) * ky
            if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
            if (stroke.points.size == 1) path.lineTo(x + 0.1f, y)
        }
        c.drawPath(path, paint)
        val m = Mask8.grayOf(bmp)
        val sigma = width * soft * 0.3f
        if (sigma > 0.8f) Mask8.gaussian(m, sigma)
        return m
    }

    /** 颜色用 image 的，透明度用 mask 的。 */
    private fun patch(rect: RectF, image: Bitmap, mask: Mask8): RetouchPatch {
        val px = IntArray(image.width * image.height)
        image.getPixels(px, 0, image.width, 0, 0, image.width, image.height)
        for (i in px.indices) px[i] = (mask[i] shl 24) or (px[i] and 0xFFFFFF)
        return RetouchPatch(rect, Bitmap.createBitmap(px, image.width, image.height, Bitmap.Config.ARGB_8888))
    }

    /** 智能消除：用周围的纹理补。 */
    fun smart(full: Bitmap, patches: List<RetouchPatch>, stroke: MosaicStroke): RetouchPatch? {
        val b = box(stroke, full.width, full.height, 1.1f)
        val part = piece(full, patches, b, 760) ?: return null
        val w = part.width
        val h = part.height
        val hole = mask(stroke, b, full.width, full.height, w, h, soft = 0f, grow = 4f)
        val px = IntArray(w * h)
        part.getPixels(px, 0, w, 0, 0, w, h)
        val filled = Inpaint.fill(px, hole.pixels, w, h) ?: return null
        val edge = mask(stroke, b, full.width, full.height, w, h, soft = 0.06f, grow = 5f)
        return patch(normalized(b, full.width, full.height), Bitmap.createBitmap(filled, w, h, Bitmap.Config.ARGB_8888), edge)
    }

    /** 仿制：照着偏移处（占宽高的比例）的画面搬过来。 */
    fun clone(full: Bitmap, patches: List<RetouchPatch>, stroke: MosaicStroke, dx: Float, dy: Float): RetouchPatch? {
        val b = box(stroke, full.width, full.height, 0.2f)
        val part = piece(full, patches, b, 1800, dx * full.width, dy * full.height) ?: return null
        val m = mask(stroke, b, full.width, full.height, part.width, part.height, soft = 0.3f)
        return patch(normalized(b, full.width, full.height), part, m)
    }

    /** 还原：变回原照片的像素。original 和 full 的画面对得上（大小可以不一样）。 */
    fun restore(full: Bitmap, original: Bitmap, stroke: MosaicStroke): RetouchPatch? {
        val b = box(stroke, full.width, full.height, 0.2f)
        val from = if (original.width == full.width && original.height == full.height) original else Img.scaled(original, full.width, full.height)
        val part = piece(from, emptyList(), b, 1800) ?: return null
        val m = mask(stroke, b, full.width, full.height, part.width, part.height, soft = 0.35f)
        return patch(normalized(b, full.width, full.height), part, m)
    }

    /** 预览里把正在涂的这一笔标红用的蒙版。 */
    fun previewMask(stroke: MosaicStroke, w: Int, h: Int): Bitmap =
        mask(stroke, intArrayOf(0, 0, w, h), w, h, max(1, (w / 2f).roundToInt()), max(1, (h / 2f).roundToInt()), 0f).toGrayBitmap()
}
