package com.taoo.xiutu.tools.makeup

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.ml.FaceInfo
import java.nio.ByteBuffer

// MARK: 数据

/** 一种化妆品的颜色（sRGB，0...1）。 */
data class MakeupColor(val r: Float, val g: Float, val b: Float) {
    val luma: Float get() = 0.299f * r + 0.587f * g + 0.114f * b

    fun mix(other: MakeupColor, t: Float) = MakeupColor(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)

    fun scaled(k: Float) = MakeupColor(r * k, g * k, b * k)

    /** 最亮的通道拉到 1：用来做"正片叠底"的染色，只变色、尽量不压暗。 */
    val normalized: MakeupColor
        get() {
            val m = maxOf(r, g, b, 0.001f)
            return MakeupColor(r / m, g / m, b / m)
        }

    /** 0xAARRGGBB（不透明）。 */
    fun argb(): Int {
        fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        return (0xFF shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        fun hex(hex: Int) = MakeupColor(((hex shr 16) and 0xFF) / 255f, ((hex shr 8) and 0xFF) / 255f, (hex and 0xFF) / 255f)
        val white = MakeupColor(1f, 1f, 1f)
        val black = MakeupColor(0.07f, 0.06f, 0.06f)
    }
}

enum class MKLipTexture(val title: String) { MATTE("哑光"), VELVET("丝绒"), SATIN("滋润"), GLOSS("水光"), GLAZE("镜面") }

enum class MKLipStyle(val title: String) { FULL("满涂"), GRADIENT("咬唇"), BLURRED("晕染") }

data class LipMakeup(
    val color: MakeupColor,
    val amount: Float = 0.8f,
    val texture: MKLipTexture = MKLipTexture.SATIN,
    val style: MKLipStyle = MKLipStyle.FULL,
    /** 唇线的浓淡，0 = 不画。 */
    val liner: Float = 0f,
)

enum class MKBrowShape(val title: String) {
    NATURAL("自然眉"), STRAIGHT("韩系平眉"), WILD("野生眉"), DROOP("落尾眉"), WILLOW("柳叶眉"), SWORD("剑眉"), ARCH("欧式挑眉"), SOFT("雾感淡眉")
}

data class BrowMakeup(val shape: MKBrowShape, val color: MakeupColor, val amount: Float = 0.55f)

data class ShadowMakeup(
    val lid: MakeupColor,
    val crease: MakeupColor,
    val outer: MakeupColor,
    /** 下眼睑带多少颜色。 */
    val lower: Float = 0.3f,
    /** 眼皮中间的珠光。 */
    val shimmer: Float = 0f,
    /** 亮片。 */
    val sparkle: Boolean = false,
    /** 整只眼睛周围的烟熏。 */
    val smoke: Float = 0f,
    val amount: Float = 0.7f,
)

enum class MKLinerStyle(val title: String) { THIN("内眼线"), NATURAL("自然"), WING("上扬"), PUPPY("下垂"), CAT("猫眼"), FULL("全包") }

data class LinerMakeup(val style: MKLinerStyle, val color: MakeupColor = MakeupColor.black, val amount: Float = 0.85f)

enum class MKLashStyle(val title: String) { NATURAL("自然"), DENSE("浓密"), SUNFLOWER("太阳花"), DOLL("娃娃") }

data class LashMakeup(val style: MKLashStyle, val amount: Float = 0.85f)

data class LensMakeup(val color: MakeupColor, val amount: Float = 0.6f)

enum class MKFoldStyle(val title: String) { FAN("开扇"), PARALLEL("平行") }

enum class MKCatchlight(val title: String) { DOT("圆点"), TWIN("双点"), WINDOW("窗光"), STAR("星芒"), RING("环形") }

data class EyeMakeup(
    val shadow: ShadowMakeup? = null,
    val liner: LinerMakeup? = null,
    val lashes: LashMakeup? = null,
    /** 卧蚕。 */
    val aegyo: Float = 0f,
    val lens: LensMakeup? = null,
    val fold: MKFoldStyle = MKFoldStyle.FAN,
    /** 双眼皮线的深浅，0 = 不画。 */
    val foldAmount: Float = 0f,
    val catchlight: MKCatchlight = MKCatchlight.DOT,
    /** 眼神光，0 = 不画。 */
    val catchlightAmount: Float = 0f,
) {
    val isEmpty: Boolean
        get() = (shadow?.amount ?: 0f) <= 0 && (liner?.amount ?: 0f) <= 0 && (lashes?.amount ?: 0f) <= 0 && aegyo <= 0 &&
            (lens?.amount ?: 0f) <= 0 && foldAmount <= 0 && catchlightAmount <= 0
}

enum class MKFreckleStyle(val title: String) { FEW("点点"), NATURAL("自然"), SUN("晒斑") }

/** 一颗痣的位置：几个常见位置，或者用户自己点的（坐标是图片的万分比）。 */
sealed class MKMoleSpot(val title: String) {
    data object TearLeft : MKMoleSpot("左泪痣")
    data object TearRight : MKMoleSpot("右泪痣")
    data object Lip : MKMoleSpot("唇上痣")
    data object Nose : MKMoleSpot("鼻梁痣")
    data object Cheek : MKMoleSpot("脸颊痣")
    data object Chin : MKMoleSpot("下巴痣")
    data class Custom(val x: Int, val y: Int) : MKMoleSpot("自己点的")

    companion object {
        val presets: List<MKMoleSpot> = listOf(TearLeft, TearRight, Lip, Nose, Cheek, Chin)
    }
}

data class ContourMakeup(
    /** 鼻影、鼻梁高光。 */
    val noseShade: Float = 0f,
    val noseLight: Float = 0f,
    // 高光
    val forehead: Float = 0f,
    val cheekLight: Float = 0f,
    val chinLight: Float = 0f,
    val cupid: Float = 0f,
    val underEye: Float = 0f,
    // 阴影
    val jaw: Float = 0f,
    val cheekShade: Float = 0f,
    val temple: Float = 0f,
    // 雀斑和痣
    val freckles: MKFreckleStyle = MKFreckleStyle.NATURAL,
    val freckleAmount: Float = 0f,
    val moles: List<MKMoleSpot> = emptyList(),
) {
    val isEmpty: Boolean get() = sculptIsEmpty && freckleAmount <= 0 && moles.isEmpty()

    /** 立体、高光、阴影这三组（不含雀斑和痣）。 */
    val sculptIsEmpty: Boolean
        get() = noseShade <= 0 && noseLight <= 0 && forehead <= 0 && cheekLight <= 0 && chinLight <= 0 && cupid <= 0 &&
            underEye <= 0 && jaw <= 0 && cheekShade <= 0 && temple <= 0
}

enum class MKBlushPlacement(val title: String) {
    APPLE("苹果肌"), SWEEP("斜扫"), UNDER_EYE("眼下"), SUNBURN("晒伤"), HIGH("高位"), DOLL("团状"), DRUNK("微醺")
}

data class BlushMakeup(
    val color: MakeupColor,
    val placement: MKBlushPlacement = MKBlushPlacement.APPLE,
    /** 光泽质地：颧骨上带一点亮。 */
    val glow: Boolean = false,
    val amount: Float = 0.55f,
)

/** 这张脸原本的明暗：上妆时要参照它，口红和美瞳才不会在亮脸、暗脸上差很多。 */
data class MKTone(
    /** 嘴唇、瞳孔虹膜原来的平均亮度（sRGB，0...1）。 */
    val lip: Float = 0.5f,
    val iris: Float = 0.2f,
) {
    companion object {
        /** 在照片上量出嘴唇和虹膜原来的平均亮度。量不出来的项保持默认值。 */
        fun measure(face: FaceInfo, image: Bitmap): MKTone {
            var tone = MKTone()
            val w = image.width.toFloat()
            val h = image.height.toFloat()
            val g = MKFace.create(face, w, h) ?: return tone
            val n = 192
            val small = Bitmap.createBitmap(n, n, Bitmap.Config.ARGB_8888)
            // 把这张脸的方框铺满整张小图
            Canvas(small).apply {
                val k = n / g.roi.width
                translate(-g.roi.minX * k, -g.roi.minY * k)
                scale(k, k)
                drawBitmap(image, 0f, 0f, Paint(Paint.FILTER_BITMAP_FLAG))
            }
            val pixels = IntArray(n * n)
            small.getPixels(pixels, 0, n, 0, 0, n, n)
            small.recycle()
            fun average(shape: MKShape): Float? {
                val mask = g.drawMask(shape, n, w, h) ?: return null
                val buf = ByteBuffer.allocate(mask.rowBytes * mask.height)
                mask.copyPixelsToBuffer(buf)
                val bytes = buf.array()
                var sum = 0f
                var total = 0
                for (y in 0 until n) for (x in 0 until n) {
                    if ((bytes[y * mask.rowBytes + x].toInt() and 0xFF) <= 128) continue
                    val c = pixels[y * n + x]
                    val r = ((c shr 16) and 0xFF).toFloat()
                    val gr = ((c shr 8) and 0xFF).toFloat()
                    val b = (c and 0xFF).toFloat()
                    sum += (0.299f * r + 0.587f * gr + 0.114f * b) / 255f
                    total++
                }
                return if (total >= 6) sum / total else null
            }
            average(MKShape.LipFull)?.let { tone = tone.copy(lip = it.coerceIn(0.2f, 0.8f)) }
            average(MKShape.Lens)?.let { tone = tone.copy(iris = it.coerceIn(0.08f, 0.5f)) }
            return tone
        }
    }
}

/** 一张脸上的全部妆。 */
data class FaceMakeup(
    val face: FaceInfo,
    val tone: MKTone = MKTone(),
    val lip: LipMakeup? = null,
    val brow: BrowMakeup? = null,
    val eye: EyeMakeup = EyeMakeup(),
    val contour: ContourMakeup = ContourMakeup(),
    val blush: BlushMakeup? = null,
) {
    val isEmpty: Boolean
        get() = (lip?.amount ?: 0f) <= 0 && (brow?.amount ?: 0f) <= 0 && eye.isEmpty && contour.isEmpty && (blush?.amount ?: 0f) <= 0
}

/** 美妆：按人脸关键点画口红、眉毛、眼妆、修容、腮红，作为编辑历史里的一步。全部在本机完成。 */
data class MakeupParams(val faces: List<FaceMakeup> = emptyList()) : EditOp {
    override val skipsColor: Boolean get() = true
    val isIdentity: Boolean get() = faces.all { it.isEmpty || !it.face.hasReliableLandmarks }

    override fun apply(src: Bitmap): Bitmap {
        if (isIdentity) return src
        val out = src.copy(Bitmap.Config.ARGB_8888, true)
        for (face in faces) {
            if (!face.isEmpty) MakeupRenderer.render(face, out, src.width.toFloat(), src.height.toFloat(), 0, 0)
        }
        return out
    }

    /**
     * 只在一块图上上妆：target 是整张图（fullW × fullH）里从 (offX, offY) 开始的那一块（缩略图用）。
     * target 必须是可改的位图，直接画在上面。
     */
    fun applyInto(target: Bitmap, fullW: Float, fullH: Float, offX: Int, offY: Int) {
        for (face in faces) {
            if (!face.isEmpty) MakeupRenderer.render(face, target, fullW, fullH, offX, offY)
        }
    }
}
