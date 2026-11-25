package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.PointF
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.sqrt

/** AI 修完的脸和原来的对不对得上：画成了别人、换了姿势的不采用。 */
object FaceCheck {
    /** 两张图是同一块（发出去的和拿回来的）。在后台线程调用。 */
    fun matches(original: Bitmap, result: Bitmap): Boolean {
        // 先比模糊以后的明暗分布：很像就是它，完全不像就不是；中间的再看五官位置。
        val like = similarity(original, result)
        if (like > 0.85) return true
        if (like < 0.6) return false
        val x = FaceDetector.direct(original).firstOrNull { it.hasReliableLandmarks }
        val y = FaceDetector.direct(result).firstOrNull { it.hasReliableLandmarks }
        if (x == null || y == null) return like > 0.75
        // 五官位置对得上：脸的中心差不到三成脸宽，大小差不到三成，五官相对位置差不到一成。
        val w = x.box.width()
        val moved = hypot(x.box.centerX() - y.box.centerX(), x.box.centerY() - y.box.centerY())
        val scale = y.box.width() / max(w, 0.001f)
        return moved < w * 0.3f && scale > 0.7f && scale < 1.4f && layout(x, y) < 0.1f
    }

    /** 五官相对脸框的位置差（占脸宽）。 */
    private fun layout(a: FaceInfo, b: FaceInfo): Float {
        fun c(p: List<PointF>, f: FaceInfo): PointF {
            val x = p.sumOf { it.x.toDouble() }.toFloat() / p.size
            val y = p.sumOf { it.y.toDouble() }.toFloat() / p.size
            return PointF((x - f.box.left) / f.box.width(), (y - f.box.top) / f.box.height())
        }
        var worst = 0f
        for ((p, q) in listOf(a.leftEye to b.leftEye, a.rightEye to b.rightEye, a.nose to b.nose, a.outerLips to b.outerLips)) {
            if (p.isEmpty() || q.isEmpty()) continue
            val u = c(p, a)
            val v = c(q, b)
            worst = max(worst, hypot(u.x - v.x, u.y - v.y))
        }
        return worst
    }

    private const val N = 24

    /** 中间那一块模糊成 24×24 灰度以后的相关系数（1 = 一样）。 */
    private fun similarity(a: Bitmap, b: Bitmap): Double = correlation(gray(a), gray(b))

    private fun gray(image: Bitmap): DoubleArray {
        val s = Img.scaled(Img.downscale(Img.soft(image), N * 2), N, N)
        val px = IntArray(N * N)
        s.getPixels(px, 0, N, 0, 0, N, N)
        return DoubleArray(N * N) { val p = px[it]; (p shr 16 and 255) * 0.299 + (p shr 8 and 255) * 0.587 + (p and 255) * 0.114 }
    }

    /** 只看中间六成：四周是头发和背景，不算。 */
    internal fun correlation(a: DoubleArray, b: DoubleArray): Double {
        val at = ArrayList<Int>()
        for (y in 4 until 20) for (x in 4 until 20) at += y * N + x
        val mx = at.sumOf { a[it] } / at.size
        val my = at.sumOf { b[it] } / at.size
        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for (i in at) {
            sxy += (a[i] - mx) * (b[i] - my)
            sxx += (a[i] - mx) * (a[i] - mx)
            syy += (b[i] - my) * (b[i] - my)
        }
        return if (sxx > 1 && syy > 1) sxy / sqrt(sxx * syy) else 1.0
    }

    /** 脸小、糊、认不出五官时，先让能看图的 AI 说清楚原来的样子，写进指令里。 */
    val DESCRIBE_PROMPT = """
        这是从照片里裁出来的一张人像小图，可能有点糊。请看清楚主角的脸：
        1. 脸的框（贴着脸，上到发际线，下到下巴），坐标用千分比：左上角 (0,0)，右下角 (1000,1000)，依次是 左、上、右、下。
        2. 用英文一句话（不超过 60 个词）客观描述，只写看得见的：头往哪边歪、脸朝哪边、眼睛睁着还是闭着或眯着、看哪里、嘴和表情、刘海和发型、发饰耳饰项链、脸型。不要猜身份。
        只输出 JSON，不要别的字：{"faces":[{"box":[左,上,右,下]}],"desc":"..."}
    """.trimIndent()
}
