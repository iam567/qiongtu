package com.taoo.xiutu.tools.skin

import android.graphics.Bitmap
import android.graphics.PointF
import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.ml.FaceInfo
import kotlin.math.abs

/** 皮肤工具的分类（底部确认栏中间的那排标签）。 */
enum class SkinTab(val title: String) {
    SKIN("皮肤"),
    REPAIR("祛皱祛痘"),
    PLUMP("丰盈"),
    LIFT("提拉"),
    EYES("眼部牙齿"),
    BRUSH("修容笔"),
}

/** 皮肤工具里每一个带滑块的项目。除了"冷暖"是 -1...1，其余都是 0...1。 */
enum class SkinKey(val title: String, val symbol: String, val tab: SkinTab) {
    // 皮肤
    SMOOTH("磨皮", "wand.and.stars", SkinTab.SKIN),
    EVEN("匀肤", "circle.lefthalf.filled", SkinTab.SKIN),
    TEXTURE("肤质", "aqi.medium", SkinTab.SKIN),
    WHITE("美白", "sun.max", SkinTab.SKIN),
    WARMTH("冷暖", "thermometer.medium", SkinTab.SKIN),
    ROSY("红润", "heart", SkinTab.SKIN),
    DESHINE("去油光", "drop", SkinTab.SKIN),

    // 祛皱祛痘
    FOREHEAD_LINES("抬头纹", "line.3.horizontal", SkinTab.REPAIR),
    EYE_LINES("眼周纹", "eye", SkinTab.REPAIR),
    NASOLABIAL("法令纹", "mouth", SkinTab.REPAIR),
    NECK_LINES("颈纹", "person.bust", SkinTab.REPAIR),
    ACNE("祛痘", "circle.dotted", SkinTab.REPAIR),

    // 丰盈
    PLUMP_FOREHEAD("额头", "face.dashed", SkinTab.PLUMP),
    PLUMP_TEAR("泪沟", "face.dashed", SkinTab.PLUMP),
    PLUMP_APPLE("苹果肌", "face.dashed", SkinTab.PLUMP),
    PLUMP_CHEEK("面颊", "face.dashed", SkinTab.PLUMP),
    PLUMP_NOSE_BASE("鼻基底", "face.dashed", SkinTab.PLUMP),
    PLUMP_TEMPLE("太阳穴", "face.dashed", SkinTab.PLUMP),

    // 提拉
    LIFT_CONTOUR("轮廓", "face.dashed", SkinTab.LIFT),
    LIFT_FOREHEAD("额头", "face.dashed", SkinTab.LIFT),
    LIFT_EYE("眼周", "face.dashed", SkinTab.LIFT),
    LIFT_MID("面中", "face.dashed", SkinTab.LIFT),
    LIFT_MOUTH("口周", "face.dashed", SkinTab.LIFT),

    // 眼部牙齿
    EYE_BRIGHT("亮眼", "sparkle", SkinTab.EYES),
    DARK_CIRCLE("黑眼圈", "moon", SkinTab.EYES),
    EYE_BAG("眼袋", "eye.trianglebadge.exclamationmark", SkinTab.EYES),
    RED_EYE("红血丝", "eye.slash", SkinTab.EYES),
    EYE_WHITE("眼白", "eye.circle", SkinTab.EYES),
    TEETH("牙齿", "face.smiling", SkinTab.EYES);

    /** true = 滑块范围 -100...100。 */
    val bipolar: Boolean get() = this == WARMTH

    /** 五官关键点不可信时还能不能用。只有按肤色和人脸框就能做的几项可以。 */
    val needsLandmarks: Boolean
        get() = when (this) {
            SMOOTH, EVEN, TEXTURE, WHITE, WARMTH, ROSY, DESHINE, ACNE -> false
            else -> true
        }

    companion object {
        fun keys(tab: SkinTab): List<SkinKey> = entries.filter { it.tab == tab }
    }
}

/** 一键美肤 / 一键丰盈 / 一键提拉：一组搭配好的数值。 */
data class SkinPreset(val title: String, val symbol: String, val values: Map<SkinKey, Float>) {
    companion object {
        val SKIN = SkinPreset("一键美肤", "sparkles", mapOf(
            SkinKey.SMOOTH to 0.45f, SkinKey.EVEN to 0.4f, SkinKey.WHITE to 0.2f, SkinKey.DESHINE to 0.25f, SkinKey.ACNE to 0.3f,
        ))
        val PLUMP = SkinPreset("一键丰盈", "sparkles", mapOf(
            SkinKey.PLUMP_FOREHEAD to 0.35f, SkinKey.PLUMP_TEAR to 0.45f, SkinKey.PLUMP_APPLE to 0.4f,
            SkinKey.PLUMP_CHEEK to 0.3f, SkinKey.PLUMP_NOSE_BASE to 0.35f, SkinKey.PLUMP_TEMPLE to 0.25f,
        ))
        val LIFT = SkinPreset("一键提拉", "sparkles", mapOf(
            SkinKey.LIFT_CONTOUR to 0.4f, SkinKey.LIFT_FOREHEAD to 0.35f, SkinKey.LIFT_EYE to 0.35f,
            SkinKey.LIFT_MID to 0.4f, SkinKey.LIFT_MOUTH to 0.35f,
        ))
    }
}

/** 肤色的几种现成搭配（美白 / 冷暖 / 红润）。 */
data class SkinTonePreset(val title: String, val white: Float, val warmth: Float, val rosy: Float) {
    companion object {
        val all = listOf(
            SkinTonePreset("自然白", 0.25f, 0f, 0.1f),
            SkinTonePreset("冷白皮", 0.5f, -0.4f, 0f),
            SkinTonePreset("暖白", 0.4f, 0.3f, 0.1f),
            SkinTonePreset("粉白", 0.4f, -0.1f, 0.55f),
            SkinTonePreset("象牙", 0.3f, 0.15f, 0.2f),
            SkinTonePreset("小麦", 0f, 0.55f, 0.15f),
        )
    }
}

/** 线性 RGB 颜色。 */
data class SkinTone(val r: Float, val g: Float, val b: Float) {
    fun array() = floatArrayOf(r, g, b)

    companion object {
        /** 量不出来时用的常见肤色。 */
        val DEFAULT = SkinTone(0.45f, 0.30f, 0.24f)
    }
}

/** 一张脸上的全部皮肤调整。tone = 这张脸的平均肤色（线性 RGB），进工具时量一次。 */
data class SkinFace(val face: FaceInfo, val tone: SkinTone, val values: Map<SkinKey, Float> = emptyMap()) {
    operator fun get(key: SkinKey): Float = values[key] ?: 0f

    fun with(key: SkinKey, value: Float): SkinFace {
        val v = if (key.bipolar) value.coerceIn(-1f, 1f) else value.coerceIn(0f, 1f)
        val m = values.toMutableMap()
        if (abs(v) < 0.005f) m.remove(key) else m[key] = v
        return copy(values = m)
    }

    val isIdentity: Boolean get() = values.isEmpty()

    fun matches(preset: SkinPreset): Boolean = preset.values.all { (k, v) -> abs(this[k] - v) < 0.005f }

    fun set(preset: SkinPreset, on: Boolean): SkinFace {
        var f = this
        for ((k, v) in preset.values) f = f.with(k, if (on) v else 0f)
        return f
    }
}

/** 画笔的一笔：修容笔的高光 / 阴影，遮瑕笔，点痘（只有一个点的遮瑕），橡皮。 */
data class SkinStroke(
    val kind: Kind,
    /** 归一化图片坐标，原点左上角。 */
    val points: List<PointF>,
    /** 笔的粗细，以图片长边为 1。 */
    val width: Float,
    /** 0...1。 */
    val strength: Float,
) {
    enum class Kind {
        HIGHLIGHT, SHADOW, CONCEAL,
        /** 橡皮：只擦修容笔画的高光和阴影。 */
        ERASE,
    }
}

/** 皮肤工具的全部修改。所有位置和大小都是相对值，预览图和原图效果一致。 */
data class SkinParams(
    val faces: List<SkinFace> = emptyList(),
    val strokes: List<SkinStroke> = emptyList(),
    /** 肤色统一：把脖子、身体的肤色往脸上靠。0...1。 */
    val unify: Float = 0f,
    /** 人像蒙版（白 = 人）。有它的话"肤色统一"只动人身上的皮肤。 */
    val bodyMask: Bitmap? = null,
) {
    override fun equals(other: Any?): Boolean =
        other is SkinParams && faces == other.faces && strokes == other.strokes && unify == other.unify && bodyMask === other.bodyMask

    override fun hashCode(): Int = faces.hashCode() * 31 + strokes.hashCode()

    val isIdentity: Boolean
        get() = strokes.all { it.kind == SkinStroke.Kind.ERASE } && faces.all { it.isIdentity } && (unify <= 0f || faces.isEmpty())

    fun apply(src: Bitmap): Bitmap {
        if (isIdentity) return src
        val work = src.copy(Bitmap.Config.ARGB_8888, true)
        // 先遮瑕 / 点痘，后面的磨皮看到的就是干净的皮肤。
        SkinEngine.conceal(work, strokes)
        for (face in faces) if (!face.isIdentity) SkinEngine.retouch(work, face)
        if (unify > 0f) faces.firstOrNull()?.let { SkinEngine.unify(work, it, unify, bodyMask) }
        SkinEngine.contour(work, strokes)
        // 变形放在最后做，这样前面的蒙版还和五官位置对得上。
        for (face in faces) if (!face.isIdentity) SkinEngine.lift(work, face)
        return work
    }
}

/** 皮肤这一步。 */
class SkinOp(val params: SkinParams) : EditOp {
    override val skipsColor: Boolean get() = true
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
}

/** 本机算法做不好的情况，交给 AI：只把脸这一块发出去，要求"是修不是画"。 */
object SkinAI {
    private const val RULES =
        " This is a retouch, not a redraw. The person must remain unmistakably the same individual: every facial feature keeps exactly the same " +
            "shape, size, position and proportions; same expression, gaze, makeup, hairstyle, lighting and colors. " +
            "Keep realistic skin texture with visible pores; no plastic, airbrushed or blurred look; do not whiten the skin, do not slim the face. " +
            "Keep the exact same framing and position of everything so the result can be overlaid on the original. Photorealistic."

    val acne = AIPreset(
        title = "AI 祛痘", symbol = "circle.dotted", faceCrop = true,
        prompt = "This is a close-up crop from a portrait photo. Remove acne, pimples, blackheads, blemishes, dark spots and post-acne marks from the skin, " +
            "and fill each spot with the natural skin tone and texture around it. Leave moles and freckles that look intentional." + RULES,
    )

    val wrinkles = AIPreset(
        title = "AI 祛皱", symbol = "line.3.horizontal", faceCrop = true,
        prompt = "This is a close-up crop from a portrait photo. Soften forehead lines, crow's feet, fine lines under the eyes, nasolabial folds and neck lines " +
            "so the skin looks naturally rested, as if a few years younger, while still clearly an adult of the same age group. " +
            "Do not remove the lines completely and do not change the face shape." + RULES,
    )
}
