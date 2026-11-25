package com.taoo.xiutu.ai.outfit

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import com.taoo.xiutu.ai.ChangeKeep
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.ml.PersonSegmenter
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 换衣服时算哪里用 AI 的、哪里用原图。都在后台线程调用。 */
object OutfitMask {
    /** 人像分割（太大了慢，缩到 1024），只留主要的人。 */
    private fun person(image: Bitmap) = PersonSegmenter.maskData(Img.downscale(image, 1024))?.let { PersonSegmenter.main(it) }

    /** 人在画面里的范围（归一化，左上原点），四周留出放裙摆和看清环境的余量。认不出人返回 null。 */
    fun crop(image: Bitmap): RectF? {
        val m = Mask8.resized(person(image) ?: return null, 128, 128)
        return crop(m, image.width.toFloat(), image.height.toFloat())
    }

    /** m：128 × 128 的人像蒙版；iw、ih：照片的宽高。 */
    internal fun crop(m: Mask8, iw: Float, ih: Float): RectF? {
        val box = cropBox(m, iw, ih) ?: return null
        return RectF(box[0], box[1], box[2], box[3])
    }

    /** 左、上、右、下。 */
    internal fun cropBox(m: Mask8, iw: Float, ih: Float): FloatArray? {
        var x0 = m.w
        var x1 = -1
        var y0 = m.h
        var y1 = -1
        for (y in 0 until m.h) for (x in 0 until m.w) if (m[y * m.w + x] > 128) {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        if (x1 <= x0 || y1 <= y0) return null
        val bx = x0 / m.w.toFloat()
        val by = y0 / m.h.toFloat()
        val bw = (x1 - x0 + 1) / m.w.toFloat()
        val bh = (y1 - y0 + 1) / m.h.toFloat()
        // 裙子会比原来的衣服宽：左右多留。
        val side = max(bw * 0.45f, bh * ih / iw * 0.22f)
        var l = max(bx - side, 0f)
        val t = max(by - bh * 0.08f, 0f)
        var r = min(bx + bw + side, 1f)
        val b = min(by - bh * 0.08f + bh * 1.2f, 1f)
        // 太瘦长的补宽，接口对比例有限制。
        if ((b - t) * ih > (r - l) * iw * 2.2f) {
            val want = (b - t) * ih / 2.2f / iw
            val mid = (l + r) / 2
            l = max(mid - want / 2, 0f)
            r = min(mid + want / 2, 1f)
        }
        // 几乎就是整张图时不裁。
        return if ((r - l) * (b - t) > 0.72f) null else floatArrayOf(l, t, r, b)
    }

    /** 把裁出来那一块的结果拼回整张图（按结果的清晰度，长边最多 5120，也不超过 GPU 的上限）。 */
    fun paste(piece: Bitmap, crop: RectF, base: Bitmap): Bitmap {
        val limit = min(5120, Gpu.run { Gpu.maxTextureSize })
        val k = min(piece.width / (crop.width() * base.width), limit.toFloat() / max(base.width, base.height))
        val w = (base.width * k).roundToInt().coerceAtLeast(1)
        val h = (base.height * k).roundToInt().coerceAtLeast(1)
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(out)
        c.drawColor(Color.BLACK)
        val paint = Paint(Paint.FILTER_BITMAP_FLAG)
        c.drawBitmap(if (k < 1f) Img.downscale(base, max(w, h)) else base, null, Rect(0, 0, w, h), paint)
        c.drawBitmap(piece, null, RectF(crop.left * w, crop.top * h, crop.right * w, crop.bottom * h), paint)
        out.setHasAlpha(false)
        return out
    }

    class Masks(val area: Mask8?, val core: Mask8?)

    /**
     * area = 允许换的范围（新旧两个人合起来扩一圈；裙摆溢出画面时，胸口以下整片都允许）；
     * core = 一定用 AI 的（新的人身上、下巴以下）。
     */
    fun masks(original: Bitmap, ai: Bitmap, overflow: Boolean, keepHead: Boolean): Masks {
        val before = person(original)
        val after = person(ai)
        var area = ChangeKeep.personArea(before, after, original.width, original.height, grow = 12, blur = 5f) ?: return Masks(null, null)
        val faces = FaceDetector.detect(ai)
        val w = area.w
        val h = area.h
        fun draw(from: Mask8, blur: Float, body: (Canvas) -> Unit): Mask8 {
            val bmp = Mask8.resized(from, w, h).toGrayBitmap().copy(Bitmap.Config.ARGB_8888, true)
            body(Canvas(bmp))
            val m = Mask8.grayOf(bmp)
            Mask8.gaussian(m, blur)
            return m
        }
        val white = Paint().apply { color = Color.WHITE }
        val black = Paint().apply { color = Color.BLACK }
        if (overflow) {
            val top = (faces.maxByOrNull { it.box.width() }?.let { it.box.bottom + it.box.height() * 0.8f } ?: 0.5f).coerceIn(0.2f, 0.85f)
            area = draw(area, 5f) { it.drawRect(0f, top * h, w.toFloat(), h.toFloat(), white) }
        }
        // 头没挪：从头顶到下巴强制用原图。
        fun head(c: Canvas) {
            for (f in faces) {
                val b = f.box
                val chin = f.contour.maxOfOrNull { it.y } ?: b.bottom
                val top = b.top - b.height() * 1.1f
                c.drawRect((b.centerX() - b.width() * 0.95f) * w, top * h, (b.centerX() + b.width() * 0.95f) * w, chin * h, black)
            }
        }
        if (keepHead) area = draw(area, 1.5f) { head(it) }
        if (after == null) return Masks(area, null)
        return Masks(area, draw(after, 2.5f) { head(it) })
    }
}
