package com.taoo.xiutu.tools.adjust

import android.graphics.Bitmap
import android.graphics.PointF
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.tools.color.ColorParams
import com.taoo.xiutu.tools.color.V3
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.Serializable

enum class AdjustGroup(val title: String) {
    LIGHT("光效"), COLOR("色彩"), DETAIL("细节"), TONE("光影");

    /** 这一组里用滑块直接调的项目（不含子面板和 AI 功能）。 */
    val keys: List<AdjustKey> get() = AdjustKey.entries.filter { it.group == this }
}

/** 一个滑块对应一项。全部在本机算。 */
enum class AdjustKey(val title: String, val symbol: String, val group: AdjustGroup?, val bipolar: Boolean = true) {
    // 光效
    BRIGHTNESS("亮度", "sun.max", AdjustGroup.LIGHT),
    CONTRAST("对比度", "circle.lefthalf.filled", AdjustGroup.LIGHT),
    EXPOSURE("曝光", "plusminus.circle", AdjustGroup.LIGHT),
    LIGHT_SENSE("光感", "sun.min", AdjustGroup.LIGHT),
    HIGHLIGHTS("高光", "sun.haze", AdjustGroup.LIGHT),
    SHADOWS("暗部", "moon", AdjustGroup.LIGHT),
    AMBIANCE("氛围", "circle.hexagongrid", AdjustGroup.LIGHT),
    FILL_LIGHT("智能补光", "lightbulb", AdjustGroup.LIGHT, false),
    // 色彩
    SATURATION("饱和度", "drop", AdjustGroup.COLOR),
    VIBRANCE("自然饱和度", "sparkles", AdjustGroup.COLOR),
    TEMPERATURE("色温", "thermometer.medium", AdjustGroup.COLOR),
    TINT("色调", "eyedropper", AdjustGroup.COLOR),
    DEHAZE("去灰", "sun.dust", AdjustGroup.COLOR, false),
    FADE("褪色", "cloud.fog", AdjustGroup.COLOR, false),
    // 细节
    SHARPEN("锐化", "triangle", AdjustGroup.DETAIL, false),
    CLARITY("清晰度", "diamond", AdjustGroup.DETAIL),
    DENOISE("降噪", "circle.dotted", AdjustGroup.DETAIL, false),
    GRAIN("颗粒", "aqi.medium", AdjustGroup.DETAIL, false),
    FRINGE("色散", "lightspectrum.horizontal", AdjustGroup.DETAIL, false),
    VIGNETTE("暗角", "smallcircle.filled.circle", AdjustGroup.DETAIL),
    // 光影
    NATURAL_LIGHT("自然光", "sun.horizon", AdjustGroup.TONE, false),
    LOW_LIGHT("弱光", "moon.stars", AdjustGroup.TONE, false),
    BACKLIGHT("逆光", "sunset", AdjustGroup.TONE, false),
    EVEN_LIGHT("校正光", "camera.metering.matrix", AdjustGroup.TONE, false),
    MOOD_LIGHT("氛围光", "light.beacon.max", AdjustGroup.TONE),
    BLOOM("柔光", "light.max", AdjustGroup.TONE, false),
    // 肤色调整（只在子面板里）
    SKIN_TONE("肤色", "face.smiling", null),
    SKIN_WHITEN("白皙", "face.smiling", null, false);

    companion object {
        /** 需要先算出"这一带整体有多亮"才能做的项目。 */
        val localToneKeys = listOf(FILL_LIGHT, BACKLIGHT, AMBIANCE, NATURAL_LIGHT, EVEN_LIGHT)
    }
}

/** 调色里要进子面板调的项目。 */
enum class AdjustSub(val title: String, val symbol: String) {
    LOCAL("局部调色", "scope"),
    HSL("HSL", "paintpalette"),
    SKIN("肤色调整", "face.smiling"),
    SPLIT("色调分离", "circle.lefthalf.striped.horizontal"),
    CURVE("曲线", "point.topleft.down.to.point.bottomright.curvepath"),
}

/** HSL 里的八个颜色。顺序和着色器里的色带一一对应。 */
enum class HSLColor(val title: String, val hue: Float) {
    RED("红", 0f), ORANGE("橙", 30f / 360), YELLOW("黄", 60f / 360), GREEN("绿", 120f / 360),
    AQUA("青", 180f / 360), BLUE("蓝", 240f / 360), PURPLE("紫", 280f / 360), MAGENTA("洋红", 320f / 360),
}

/** 曲线上的一个控制点（x、y 都是 0...1）。 */
@Serializable
data class CurvePoint(val x: Float, val y: Float) {
    fun pointF() = PointF(x, y)
}

/** 曲线：总曲线 + 红绿蓝三条。每条至少有头尾两个点，x 递增。 */
@Serializable
data class CurveSet(val channels: List<List<CurvePoint>> = List(4) { IDENTITY }) {
    val isIdentity get() = channels.all { it == IDENTITY }
    fun isChanged(channel: Int) = channels[channel] != IDENTITY
    fun with(channel: Int, points: List<CurvePoint>) = CurveSet(channels.toMutableList().also { it[channel] = points })
    fun pointFs() = channels.map { c -> c.map { it.pointF() } }

    companion object {
        val IDENTITY = listOf(CurvePoint(0f, 0f), CurvePoint(1f, 1f))
    }
}

/** 色调分离：给暗部和亮部各染一个颜色。 */
@Serializable
data class SplitTone(
    val shadowHue: Float = 0.6f,
    val shadowAmount: Float = 0f,
    val highlightHue: Float = 0.1f,
    val highlightAmount: Float = 0f,
    /** -1...1：往左暗部的颜色占得多，往右亮部的颜色占得多。 */
    val balance: Float = 0f,
) {
    val isIdentity get() = shadowAmount == 0f && highlightAmount == 0f
}

/** 局部调色的一个点：只改以它为中心的一个圆里面，边缘渐变过渡。 */
@Serializable
data class LocalAdjust(
    val id: Long = nextId.incrementAndGet(),
    /** 中心，归一化图片坐标，原点左上角。 */
    val cx: Float,
    val cy: Float,
    /** 范围半径，以图片长边为 1。 */
    val radius: Float = 0.22f,
    val brightness: Float = 0f,
    val contrast: Float = 0f,
    val saturation: Float = 0f,
    val temperature: Float = 0f,
) {
    val isNeutral get() = brightness == 0f && contrast == 0f && saturation == 0f && temperature == 0f

    companion object {
        private val nextId = AtomicLong(0)
    }
}

/** 调色的全部参数。和分辨率无关。 */
@Serializable
data class AdjustParams(
    val values: Map<AdjustKey, Float> = emptyMap(),
    /** HSL：每个颜色的（色相、饱和度、明度），都是 -1...1。下标是 HSLColor.ordinal。 */
    val hsl: List<V3> = List(HSLColor.entries.size) { V3.ZERO },
    val curves: CurveSet = CurveSet(),
    val split: SplitTone = SplitTone(),
    val locals: List<LocalAdjust> = emptyList(),
) {
    operator fun get(key: AdjustKey): Float = values[key] ?: 0f

    fun with(key: AdjustKey, value: Float) = copy(values = if (value == 0f) values - key else values + (key to value))

    val hslChanged get() = hsl.any { !it.isZero }
    val skinChanged get() = this[AdjustKey.SKIN_TONE] != 0f || this[AdjustKey.SKIN_WHITEN] != 0f
    val localChanged get() = locals.any { !it.isNeutral }

    fun isChanged(sub: AdjustSub) = when (sub) {
        AdjustSub.LOCAL -> localChanged
        AdjustSub.HSL -> hslChanged
        AdjustSub.SKIN -> skinChanged
        AdjustSub.SPLIT -> !split.isIdentity
        AdjustSub.CURVE -> !curves.isIdentity
    }

    val isIdentity get() = values.isEmpty() && !hslChanged && curves.isIdentity && split.isIdentity && !localChanged

    /** 一次算完的那几项。 */
    val color: ColorParams
        get() = ColorParams(
            exposure = this[AdjustKey.EXPOSURE], brightness = this[AdjustKey.BRIGHTNESS], contrast = this[AdjustKey.CONTRAST],
            highlights = this[AdjustKey.HIGHLIGHTS], shadows = this[AdjustKey.SHADOWS], saturation = this[AdjustKey.SATURATION],
            vibrance = this[AdjustKey.VIBRANCE], temperature = this[AdjustKey.TEMPERATURE], tint = this[AdjustKey.TINT],
            fade = this[AdjustKey.FADE],
        )
}

/** 调色确认后的一步。 */
class AdjustOp(val params: AdjustParams) : EditOp {
    /** 带局部调色的和位置绑在一起，不能拿下来。 */
    override val colors: Boolean get() = !params.localChanged
    override fun apply(src: Bitmap): Bitmap = AdjustRender.apply(src, params)
}
