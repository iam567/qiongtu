package com.taoo.xiutu.ml

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.tools.shape.ShapeBodyDetector
import com.taoo.xiutu.tools.shape.V2
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 找不到脸时的几道补救：大图分块放大找、在点的位置放大找、让 AI 指出位置。都在后台线程调用。 */
object FaceFinder {
    /** 小脸：把画面里有人的地方切成小块放大了再找。没人的照片很快就放弃。 */
    fun deep(image: Bitmap, thorough: Boolean = false): List<FaceInfo> {
        val w = image.width.toFloat()
        val h = image.height.toFloat()
        val long = max(w, h)
        // iOS 用人体框；安卓用人体关键点估出头在哪。
        val crops = ArrayList<RectF>()
        for (body in ShapeBodyDetector.detect(image)) {
            val l = body.left.shoulder ?: continue
            val r = body.right.shoulder ?: continue
            val mid = (l + r) / 2f
            val span = (l - r).length
            fun add(c: V2, half: Float) =
                crops.add(RectF((c.x - half) * long / w, (c.y - half) * long / h, (c.x + half) * long / w, (c.y + half) * long / h))
            body.head?.let { add(it, max(body.headRadius * 2.4f, 0.02f)) }
            add(V2(mid.x, mid.y - span * 0.6f), max(span * 1.3f, 0.03f))
        }
        var found = search(image, crops)
        if (found.isEmpty() && (thorough || crops.isNotEmpty() || PersonSegmenter.maskData(Img.downscale(image, 1024)) != null)) {
            for (size in if (thorough) listOf(0.5f, 0.3f, 0.18f) else listOf(0.5f, 0.3f)) {
                found = search(image, tiles(size))
                if (found.isNotEmpty()) break
            }
        }
        return found
    }

    /** 盖住整张图的一组方块（归一化），相邻的重叠四成。 */
    private fun tiles(size: Float): List<RectF> = starts(size).let { list ->
        list.flatMap { y -> list.map { x -> RectF(x, y, x + size, y + size) } }
    }

    internal fun starts(size: Float): List<Float> {
        val out = ArrayList<Float>()
        var x = 0f
        while (true) {
            out += min(x, 1 - size)
            if (x + size >= 1f) return out
            x += size * 0.6f
        }
    }

    /** 在点的位置找：从小到大几种范围，放大了再找；都认不出就按点的位置给一个框（没有五官，AI 美颜够用）。 */
    fun at(p: PointF, image: Bitmap): FaceInfo {
        val aspect = image.width.toFloat() / image.height
        for (side in listOf(0.1f, 0.18f, 0.06f, 0.32f)) {
            val h = side * aspect
            search(image, listOf(RectF(p.x - side / 2, p.y - h / 2, p.x + side / 2, p.y + h / 2)))
                .firstOrNull { grown(it.box, 0.4f).contains(p.x, p.y) }?.let { return it }
        }
        val w = 0.045f
        val h = w * aspect * 1.2f
        return FaceInfo(box = RectF(p.x - w / 2, p.y - h / 2, p.x + w / 2, p.y + h / 2))
    }

    /** AI 说脸在这个框里：在那儿放大了量五官，量不出就只用框。 */
    fun refine(box: RectF, image: Bitmap): FaceInfo =
        search(image, listOf(grown(box, 0.8f), grown(box, 0.3f)))
            .firstOrNull { grown(it.box, 0.5f).contains(box.centerX(), box.centerY()) } ?: FaceInfo(box = box)

    private fun grown(r: RectF, k: Float) = RectF(r.left - r.width() * k, r.top - r.height() * k, r.right + r.width() * k, r.bottom + r.height() * k)

    /** 每一块裁出来放大到 1000 像素找脸，坐标换回整张图；同一张脸只留一个。 */
    private fun search(image: Bitmap, crops: List<RectF>): List<FaceInfo> {
        val w = image.width
        val h = image.height
        val out = ArrayList<FaceInfo>()
        for (crop in crops) {
            val x0 = floor(crop.left * w).toInt().coerceIn(0, w)
            val y0 = floor(crop.top * h).toInt().coerceIn(0, h)
            val x1 = ceil(crop.right * w).toInt().coerceIn(0, w)
            val y1 = ceil(crop.bottom * h).toInt().coerceIn(0, h)
            val cw = x1 - x0
            val ch = y1 - y0
            if (cw < 24 || ch < 24) continue
            val k = max(min(6f, 1000f / max(cw, ch)), 0.2f)
            val piece = Bitmap.createBitmap(image, x0, y0, cw, ch)
            val tw = max(1, (cw * k).roundToInt())
            val th = max(1, (ch * k).roundToInt())
            val big = Img.scaled(if (k < 1f) Img.downscale(piece, max(tw, th)) else piece, tw, th)
            for (face in FaceDetector.direct(big)) {
                val moved = face.mapped { PointF((x0 + it.x * cw) / w, (y0 + it.y * ch) / h) }
                val same = out.any { o ->
                    val i = RectF(o.box)
                    i.intersect(moved.box) && i.width() > min(o.box.width(), moved.box.width()) * 0.4f
                }
                if (!same) out += moved
            }
        }
        return out.sortedByDescending { it.box.width() * it.box.height() }
    }

    const val PROMPT = "找出这张照片里所有人的脸（包括很小的、侧着的、逆光的、被头发或帽子挡住一部分的），不要把雕像、画、玩偶和花纹当成脸。" +
        "框要贴着脸：上到发际线，下到下巴，左右到脸颊边缘。坐标用千分比：照片左上角是 (0,0)，右下角是 (1000,1000)，box 依次是 左、上、右、下。" +
        "只输出 JSON，不要别的字：{\"faces\":[{\"box\":[左,上,右,下]}]}。没有人脸就输出 {\"faces\":[]}。"
}

/** 所有坐标换一套。 */
fun FaceInfo.mapped(f: (PointF) -> PointF): FaceInfo {
    val a = f(PointF(box.left, box.top))
    val b = f(PointF(box.right, box.bottom))
    return copy(
        box = RectF(a.x, a.y, b.x, b.y),
        contour = contour.map(f), leftEye = leftEye.map(f), rightEye = rightEye.map(f),
        leftBrow = leftBrow.map(f), rightBrow = rightBrow.map(f),
        outerLips = outerLips.map(f), innerLips = innerLips.map(f), nose = nose.map(f),
        leftPupil = leftPupil?.let(f), rightPupil = rightPupil?.let(f),
        noseCrest = noseCrest?.map(f), medianLine = medianLine?.map(f),
    )
}
