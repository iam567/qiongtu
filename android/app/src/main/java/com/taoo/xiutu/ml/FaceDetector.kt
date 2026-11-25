package com.taoo.xiutu.ml

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.Face
import com.google.mlkit.vision.face.FaceContour
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import com.google.mlkit.vision.face.FaceLandmark
import kotlin.math.abs

/** 一张脸的位置和五官关键点。坐标都是归一化的图片坐标，原点在左上角。 */
data class FaceInfo(
    val box: RectF,
    /** 沿下颌从一侧到另一侧的轮廓线。 */
    val contour: List<PointF> = emptyList(),
    val leftEye: List<PointF> = emptyList(),
    val rightEye: List<PointF> = emptyList(),
    val leftBrow: List<PointF> = emptyList(),
    val rightBrow: List<PointF> = emptyList(),
    val outerLips: List<PointF> = emptyList(),
    val innerLips: List<PointF> = emptyList(),
    val nose: List<PointF> = emptyList(),
    val leftPupil: PointF? = null,
    val rightPupil: PointF? = null,
    /** 鼻梁中线（从眉心到鼻尖）。 */
    val noseCrest: List<PointF>? = null,
    /** 脸的正中线（额头到下巴）。 */
    val medianLine: List<PointF>? = null,
    /** 头在画面里歪了多少（弧度，顺时针为正）和左右转了多少；给不出时是 null。 */
    val roll: Float? = null,
    val yaw: Float? = null,
) {
    /** 关键点是否可信。不可信时只做磨皮和美白，不做依赖五官位置的处理。 */
    val hasReliableLandmarks: Boolean
        get() {
            if (contour.size < 5 || leftEye.size < 3 || rightEye.size < 3 || box.width() <= 0) return false
            fun cx(p: List<PointF>) = p.sumOf { it.x.toDouble() }.toFloat() / p.size
            val jaw = abs(contour.first().x - contour.last().x)
            return abs(cx(leftEye) - cx(rightEye)) > box.width() * 0.18f && jaw > box.width() * 0.45f
        }
}

/**
 * 用 ML Kit 找人脸，全部在本机完成。detect 是同步的，要在后台线程调用。
 * ML Kit 只给最显眼的那张脸算轮廓，所以用两个检测器：一个找所有脸和关键点，一个给主脸算轮廓，再按位置合并。
 */
object FaceDetector {
    private val landmarkDetector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setLandmarkMode(FaceDetectorOptions.LANDMARK_MODE_ALL)
                .setMinFaceSize(0.04f)
                .build()
        )
    }

    private val contourDetector by lazy {
        FaceDetection.getClient(
            FaceDetectorOptions.Builder()
                .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
                .setContourMode(FaceDetectorOptions.CONTOUR_MODE_ALL)
                .setMinFaceSize(0.04f)
                .build()
        )
    }

    /** 整张找一遍，找不到再分块放大找小脸。在后台线程调用。 */
    fun detect(image: Bitmap): List<FaceInfo> = direct(image).ifEmpty { FaceFinder.deep(image) }

    /**
     * 只整张找一遍。ML Kit 只给够大、最显眼的那张脸算五官轮廓（脸小于约 200 像素时一个都不给），
     * 所以缺轮廓的脸再单独裁出来放大找一次，坐标换回整张图。
     */
    fun direct(image: Bitmap): List<FaceInfo> {
        check(Looper.myLooper() != Looper.getMainLooper()) { "FaceDetector.direct 要在后台线程调用" }
        val found = detectRaw(image)
        return found.map { f -> if (f.hasReliableLandmarks) f else runCatching { refine(image, f) }.getOrNull() ?: f }
    }

    /** 裁出一张脸（脸宽 2.2 倍的方块），放大到至少 640 再找一次。 */
    private fun refine(image: Bitmap, face: FaceInfo): FaceInfo? {
        val w = image.width.toFloat()
        val h = image.height.toFloat()
        val side = kotlin.math.max(face.box.width() * w, face.box.height() * h) * 2.2f
        val cx = face.box.centerX() * w
        val cy = face.box.centerY() * h
        val x0 = kotlin.math.max(0, (cx - side / 2).toInt())
        val y0 = kotlin.math.max(0, (cy - side / 2).toInt())
        val x1 = kotlin.math.min(image.width, (cx + side / 2).toInt())
        val y1 = kotlin.math.min(image.height, (cy + side / 2).toInt())
        val cw = x1 - x0
        val ch = y1 - y0
        if (cw < 24 || ch < 24) return null
        var crop = Bitmap.createBitmap(image, x0, y0, cw, ch)
        if (kotlin.math.max(cw, ch) < 640) {
            val k = 640f / kotlin.math.max(cw, ch)
            crop = Bitmap.createScaledBitmap(crop, (cw * k).toInt(), (ch * k).toInt(), true)
        }
        fun map(p: PointF) = PointF((x0 + p.x * cw) / w, (y0 + p.y * ch) / h)
        // 裁出来的图里可能还带着别人的半张脸：取换回去以后离原来那张脸最近、而且落在它框里的
        val best = detectRaw(crop).filter { it.hasReliableLandmarks }.minByOrNull { c ->
            val m = map(PointF(c.box.centerX(), c.box.centerY()))
            kotlin.math.hypot(m.x - face.box.centerX(), m.y - face.box.centerY())
        } ?: return null
        val center = map(PointF(best.box.centerX(), best.box.centerY()))
        if (!face.box.contains(center.x, center.y)) return null
        val tl = map(PointF(best.box.left, best.box.top))
        val br = map(PointF(best.box.right, best.box.bottom))
        return best.copy(
            box = RectF(tl.x, tl.y, br.x, br.y),
            contour = best.contour.map(::map),
            leftEye = best.leftEye.map(::map),
            rightEye = best.rightEye.map(::map),
            leftBrow = best.leftBrow.map(::map),
            rightBrow = best.rightBrow.map(::map),
            outerLips = best.outerLips.map(::map),
            innerLips = best.innerLips.map(::map),
            nose = best.nose.map(::map),
            leftPupil = best.leftPupil?.let(::map),
            rightPupil = best.rightPupil?.let(::map),
            noseCrest = best.noseCrest?.map(::map),
            medianLine = best.medianLine?.map(::map),
        ).takeIf { it.hasReliableLandmarks }
    }

    private fun detectRaw(image: Bitmap): List<FaceInfo> {
        val bmp = if (image.config == Bitmap.Config.HARDWARE || image.config == null) image.copy(Bitmap.Config.ARGB_8888, false) else image
        val w = bmp.width.toFloat()
        val h = bmp.height.toFloat()
        if (w <= 0 || h <= 0) return emptyList()
        val input = InputImage.fromBitmap(bmp, 0)
        val faces = runCatching { Tasks.await(landmarkDetector.process(input)) }.getOrElse { emptyList() }
        val contoured = runCatching { Tasks.await(contourDetector.process(input)) }.getOrElse { emptyList() }

        fun n(p: PointF) = PointF(p.x / w, p.y / h)
        fun box(f: Face) = RectF(f.boundingBox.left / w, f.boundingBox.top / h, f.boundingBox.right / w, f.boundingBox.bottom / h)

        // 每个带轮廓的脸配给重叠最多的那张脸
        val matched = HashMap<Int, Face>()
        val extra = mutableListOf<Face>()
        for (c in contoured) {
            val idx = faces.indices.maxByOrNull { iou(box(faces[it]), box(c)) }
            if (idx != null && iou(box(faces[idx]), box(c)) > 0.3f && idx !in matched) matched[idx] = c else extra += c
        }

        val out = faces.mapIndexed { i, f -> build(f, matched[i], ::n, box(f)) } + extra.map { build(it, it, ::n, box(it)) }
        // 最大的脸排最前，默认选它
        return out.sortedByDescending { it.box.width() * it.box.height() }
    }

    private fun iou(a: RectF, b: RectF): Float {
        val l = maxOf(a.left, b.left); val t = maxOf(a.top, b.top)
        val r = minOf(a.right, b.right); val bt = minOf(a.bottom, b.bottom)
        if (r <= l || bt <= t) return 0f
        val inter = (r - l) * (bt - t)
        return inter / (a.width() * a.height() + b.width() * b.height() - inter)
    }

    private fun build(face: Face, c: Face?, n: (PointF) -> PointF, box: RectF): FaceInfo {
        fun pts(type: Int): List<PointF> = c?.getContour(type)?.points?.map(n) ?: emptyList()
        fun mark(type: Int): PointF? = face.getLandmark(type)?.position?.let(n)

        val oval = pts(FaceContour.FACE)
        // 36 点的整圈轮廓从额头正中开始，取经过下巴的那半圈（两侧大约在眼睛高度）
        val jaw = if (oval.size >= 28) oval.subList(9, 28) else emptyList()

        val leftEye = pts(FaceContour.LEFT_EYE)
        val rightEye = pts(FaceContour.RIGHT_EYE)
        val leftBrow = pts(FaceContour.LEFT_EYEBROW_TOP) + pts(FaceContour.LEFT_EYEBROW_BOTTOM).reversed()
        val rightBrow = pts(FaceContour.RIGHT_EYEBROW_TOP) + pts(FaceContour.RIGHT_EYEBROW_BOTTOM).reversed()

        val upperTop = pts(FaceContour.UPPER_LIP_TOP).sortedBy { it.x }
        val upperBottom = pts(FaceContour.UPPER_LIP_BOTTOM).sortedBy { it.x }
        val lowerTop = pts(FaceContour.LOWER_LIP_TOP).sortedBy { it.x }
        val lowerBottom = pts(FaceContour.LOWER_LIP_BOTTOM).sortedBy { it.x }
        // 上沿从左到右、下沿从右到左，连成一圈
        val outerLips = if (upperTop.isNotEmpty() && lowerBottom.isNotEmpty()) upperTop + lowerBottom.reversed() else emptyList()
        val innerLips = if (upperBottom.isNotEmpty() && lowerTop.isNotEmpty()) upperBottom + lowerTop.reversed() else emptyList()

        val bridge = pts(FaceContour.NOSE_BRIDGE)
        val noseBottom = pts(FaceContour.NOSE_BOTTOM).sortedBy { it.x }
        val nose = if (bridge.isNotEmpty() || noseBottom.isNotEmpty()) bridge + noseBottom else
            listOfNotNull(mark(FaceLandmark.NOSE_BASE))
        // 鼻梁只有两个点，插成 5 个点
        val crest = if (bridge.size >= 2) (0..4).map { k ->
            val t = k / 4f
            PointF(bridge.first().x + (bridge.last().x - bridge.first().x) * t, bridge.first().y + (bridge.last().y - bridge.first().y) * t)
        } else null
        val median: List<PointF>? = if (oval.size >= 19 && bridge.isNotEmpty()) buildList<PointF> {
            add(oval[0])
            addAll(bridge)
            if (noseBottom.size == 3) add(noseBottom[1])
            if (upperTop.isNotEmpty()) add(upperTop[upperTop.size / 2])
            if (lowerBottom.isNotEmpty()) add(lowerBottom[lowerBottom.size / 2])
            add(oval[18])
        } else null

        fun center(p: List<PointF>) = if (p.isEmpty()) null else
            PointF(p.sumOf { it.x.toDouble() }.toFloat() / p.size, p.sumOf { it.y.toDouble() }.toFloat() / p.size)

        return FaceInfo(
            box = box,
            contour = jaw,
            leftEye = leftEye,
            rightEye = rightEye,
            leftBrow = leftBrow,
            rightBrow = rightBrow,
            outerLips = outerLips,
            innerLips = innerLips,
            nose = nose,
            leftPupil = mark(FaceLandmark.LEFT_EYE) ?: center(leftEye),
            rightPupil = mark(FaceLandmark.RIGHT_EYE) ?: center(rightEye),
            noseCrest = crest,
            medianLine = median,
            // ML Kit 的 Z 角逆时针为正，换成顺时针为正的弧度
            roll = -Math.toRadians(face.headEulerAngleZ.toDouble()).toFloat(),
            yaw = Math.toRadians(face.headEulerAngleY.toDouble()).toFloat(),
        )
    }
}
