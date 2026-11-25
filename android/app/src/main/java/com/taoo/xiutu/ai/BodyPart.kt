package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.tools.shape.ShapeBodyDetector
import com.taoo.xiutu.tools.shape.V2
import kotlin.math.atan2
import kotlin.math.max
import kotlin.math.min

/** AI 美体只该动的那一块。别处（比如丰胸时的肚子）就算 AI 改了也不采用。 */
enum class BodyPart {
    CHEST, WAIST, HIP, NECK, LEGS;

    /**
     * 这一块在图里的大致范围（白 = 允许），和照片同比例的小图。认不出人体也认不出脸时返回 null（不限制）。
     * 在后台线程调用。
     */
    fun area(image: Bitmap): Mask8? {
        val iw = image.width.toFloat()
        val ih = image.height.toFloat()
        val long = max(iw, ih)
        // 都按长边 = 1、左上原点。
        var shoulder: V2? = null
        var width = 0f
        var down = V2(0f, 1f)
        val body = ShapeBodyDetector.detect(image).firstOrNull()
        val l = body?.left?.shoulder
        val r = body?.right?.shoulder
        if (body != null && l != null && r != null) {
            val s = (l + r) / 2f
            shoulder = s
            width = (l - r).length
            val a = body.left.hip
            val b = body.right.hip
            if (a != null && b != null) {
                val d = (a + b) / 2f - s
                val len = d.length
                if (len > 0.01f) {
                    down = d / len
                    // 侧身时肩膀看起来很窄，用躯干长度兜底。
                    width = max(width, len * 0.6f)
                }
            }
        } else {
            FaceDetector.detect(image).maxByOrNull { it.box.width() }?.let { face ->
                val w = face.box.width() * iw / long
                val h = face.box.height() * ih / long
                width = max(w, h) * 2.3f
                shoulder = V2(face.box.centerX() * iw / long, face.box.centerY() * ih / long + max(w, h) * 1.35f)
            }
        }
        val s = shoulder ?: return null
        if (width <= 0.01f) return null
        val (center, halfW, halfH) = when (this) {
            NECK -> Triple(-0.1f, 1.05f, 0.65f)
            CHEST -> Triple(0.4f, 0.8f, 0.36f)
            WAIST -> Triple(1.1f, 0.9f, 0.62f)
            HIP -> Triple(1.65f, 1.1f, 0.8f)
            LEGS -> Triple(3.2f, 1.6f, 1.75f)
        }
        val k = 640f / long
        val w = max(1, (iw * k).toInt())
        val h = max(1, (ih * k).toInt())
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val c = Canvas(bmp)
        c.drawColor(Color.BLACK)
        c.translate((s.x + down.x * center * width) * 640f, (s.y + down.y * center * width) * 640f)
        // 画布是左上原点、顺时针为正：把竖直方向转到身体的方向。
        c.rotate(-Math.toDegrees(atan2(down.x, down.y).toDouble()).toFloat())
        val box = RectF(-halfW * width * 640, -halfH * width * 640, halfW * width * 640, halfH * width * 640)
        val corner = min(box.width(), box.height()) * 0.35f
        c.drawRoundRect(box, corner, corner, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE })
        val m = Mask8.grayOf(bmp)
        Mask8.gaussian(m, max(width * 640 * 0.06f, 2f))
        return m
    }
}
