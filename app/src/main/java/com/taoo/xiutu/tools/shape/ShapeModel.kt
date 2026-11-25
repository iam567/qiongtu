package com.taoo.xiutu.tools.shape

import android.graphics.Bitmap
import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.editor.EditOp
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

// 美体塑形的参数和变形引擎（iOS Shape.swift）。
//
// 坐标约定：所有点都用"单位坐标"——以原图长边为 1、原点在左上角、y 朝下。
// 所以同一组参数在缩小的预览图和原图上效果完全一样。
// 所有局部变形（瘦身框、缩放圈、各部位塑形）先各自算出"这个位置的画面要从哪里取"，
// 位移加在一起，最后只对图片取样一次，叠多少项都不会越来越糊。

/** 二维向量 / 点。 */
data class V2(val x: Float, val y: Float) {
    operator fun plus(o: V2) = V2(x + o.x, y + o.y)
    operator fun minus(o: V2) = V2(x - o.x, y - o.y)
    operator fun times(k: Float) = V2(x * k, y * k)
    operator fun div(k: Float) = V2(x / k, y / k)
    operator fun unaryMinus() = V2(-x, -y)
    fun dot(o: V2) = x * o.x + y * o.y
    val length: Float get() = sqrt(x * x + y * y)
    fun normalized(): V2 { val l = length; return if (l > 0) this / l else this }

    companion object { val ZERO = V2(0f, 0f) }
}

/** 矩形（单位坐标）。 */
data class URect(val minX: Float, val minY: Float, val maxX: Float, val maxY: Float) {
    val width get() = maxX - minX
    val height get() = maxY - minY
    fun union(o: URect) = URect(min(minX, o.minX), min(minY, o.minY), max(maxX, o.maxX), max(maxY, o.maxY))

    companion object {
        fun of(x: Float, y: Float, w: Float, h: Float) = URect(x, y, x + w, y + h)
        fun point(p: V2) = URect(p.x, p.y, p.x, p.y)
    }
}

// MARK: - 增高

/** 增高里的一条拉伸带：两条平行线之间的画面沿垂直方向拉长或压短，线外面的整体平移，画布跟着变大变小。 */
data class ShapeTall(
    /** 两条线正中间的点。 */
    val center: V2,
    /** 线的方向（弧度，0 = 水平线，顺时针为正）。 */
    val angle: Float = 0f,
    /** 两条线之间距离的一半。 */
    val halfGap: Float,
    /** -1...1：正数拉长，负数压短。 */
    val amount: Float = 0f,
    /** 头部保护：这一段（沿垂直于线的方向）不参与拉伸。null = 不保护。 */
    val head: URect? = null,
) {
    /** 拉伸倍数。 */
    val factor: Float get() = if (amount >= 0) 1 + 0.4f * amount else 1 + 0.3f * amount
}

/** 一条拉伸带在某个画面尺寸下算好的几何：正反两个方向的坐标换算。 */
class ShapeTallMap(band: ShapeTall, size: V2) {
    val c: V2 = band.center
    /** 垂直于线的方向，主分量为正。 */
    val n: V2
    /** 沿 n 方向的分段：(起点, 终点, 倍数)。 */
    private val segments: List<FloatArray>
    private val delta: Float
    /** 输出画面相对输入画面的原点偏移，以及输出画面的大小。 */
    val origin: V2
    val outSize: V2

    init {
        var normal = V2(-sin(band.angle), cos(band.angle))
        val vertical = abs(normal.y) >= abs(normal.x)
        if ((vertical && normal.y < 0) || (!vertical && normal.x < 0)) normal = -normal
        n = normal
        val g = max(band.halfGap, 0.002f)
        val k = band.factor
        val segs = ArrayList<FloatArray>()
        val head = band.head
        if (head != null && k != 1f) {
            // 头部的四个角投影到 n 上，得到要跳过的一段。
            val ts = listOf(V2(head.minX, head.minY), V2(head.maxX, head.minY), V2(head.minX, head.maxY), V2(head.maxX, head.maxY))
                .map { (it - c).dot(normal) }
            val h0 = max(ts.min(), -g)
            val h1 = min(ts.max(), g)
            if (h1 > h0) {
                if (h0 > -g) segs += floatArrayOf(-g, h0, k)
                segs += floatArrayOf(h0, h1, 1f)
                if (h1 < g) segs += floatArrayOf(h1, g, k)
            } else {
                segs += floatArrayOf(-g, g, k)
            }
        } else {
            segs += floatArrayOf(-g, g, k)
        }
        segments = segs
        delta = segs.fold(0f) { acc, s -> acc + (s[1] - s[0]) * (s[2] - 1) }
        // 沿主方向画布变长（或变短）；另一个方向只保留线两边都有画面的那一段，免得边上拉出一条条的残影。
        val shift = normal * delta
        if (vertical) {
            origin = V2(max(0f, shift.x), 0f)
            outSize = V2(max(size.x - abs(shift.x), 0.01f), max(size.y + shift.y, 0.01f))
        } else {
            origin = V2(0f, max(0f, shift.y))
            outSize = V2(max(size.x + shift.x, 0.01f), max(size.y - abs(shift.y), 0.01f))
        }
    }

    /** 沿 n 方向：原来的位置 → 拉伸之后的位置。 */
    private fun forward(t: Float): Float {
        var extra = 0f
        for (s in segments) extra += min(max(t - s[0], 0f), s[1] - s[0]) * (s[2] - 1)
        return t + extra
    }

    /** 沿 n 方向：拉伸之后的位置 → 原来的位置。 */
    private fun inverse(value: Float): Float {
        val first = segments.firstOrNull() ?: return value
        if (value <= first[0]) return value
        var start = first[0]
        for (s in segments) {
            val end = start + (s[1] - s[0]) * s[2]
            if (value <= end) return s[0] + (value - start) / max(s[2], 0.05f)
            start = end
        }
        return value - delta
    }

    /** 输出画面上的一点 → 输入画面上对应的点。 */
    fun source(x: Float, y: Float): V2 {
        val qx = x + origin.x
        val qy = y + origin.y
        val t = (qx - c.x) * n.x + (qy - c.y) * n.y
        val d = inverse(t) - t
        return V2(qx + n.x * d, qy + n.y * d)
    }

    /** 输入画面上的一点 → 输出画面上的位置。 */
    fun output(q: V2): V2 {
        val t = (q - c).dot(n)
        return q + n * (forward(t) - t) - origin
    }
}

// MARK: - 瘦身框 / 缩放圈

/** 瘦身：一个可以移动、旋转、缩放的框。框里的画面朝框的竖直中线收（或往外放），中间最强，到框的上下两头减到零。 */
data class ShapeBox(
    val center: V2,
    val width: Float,
    val height: Float,
    /** 弧度，顺时针为正。 */
    val angle: Float = 0f,
    /** -1...1：正数变瘦，负数变宽。 */
    val amount: Float = 0f,
)

/** 缩放：一个圆圈，圈里的画面放大或缩小，到圈边平滑过渡到不变。 */
data class ShapeSpot(
    val center: V2,
    val radius: Float,
    /** -1...1：正数放大，负数缩小。 */
    val amount: Float = 0f,
)

// MARK: - 塑形

enum class ShapeSide(val title: String) { BOTH("整体"), LEFT("左"), RIGHT("右") }

/** 一项塑形的数值：整体，加上只给画面左边 / 右边那一侧的额外量。 */
data class ShapeAmount(val both: Float = 0f, val left: Float = 0f, val right: Float = 0f) {
    val isZero: Boolean get() = both == 0f && left == 0f && right == 0f
    val leftTotal: Float get() = (both + left).coerceIn(-1f, 1f)
    val rightTotal: Float get() = (both + right).coerceIn(-1f, 1f)

    operator fun get(side: ShapeSide): Float = when (side) {
        ShapeSide.BOTH -> both
        ShapeSide.LEFT -> left
        ShapeSide.RIGHT -> right
    }

    fun with(side: ShapeSide, value: Float): ShapeAmount = when (side) {
        ShapeSide.BOTH -> copy(both = value)
        ShapeSide.LEFT -> copy(left = value)
        ShapeSide.RIGHT -> copy(right = value)
    }
}

enum class ShapeGroup(val title: String) {
    SLIM("瘦身"), ARM("手臂"), LEG("腿部"), POSTURE("体态"), NECK("肩颈"), HEAD("小头"), CHEST("胸部"), HIP("臀胯");

    val items: List<ShapeItem> get() = ShapeItem.entries.filter { it.group == this }
}

/** 塑形里的各项。本机能调的项都另有一个 AI 版（认不出人体时也能用）；还有几项本机做不好，只有 AI 版。 */
enum class ShapeItem(val title: String, val symbol: String, val group: ShapeGroup, val isAI: Boolean = false) {
    WAIST("瘦腰", "arrow.right.and.line.vertical.and.arrow.left", ShapeGroup.SLIM),
    SLIM_ALL("瘦全身", "figure.stand", ShapeGroup.SLIM),
    AI_WAIST("瘦腰", "arrow.right.and.line.vertical.and.arrow.left", ShapeGroup.SLIM, true),
    AI_SLIM_ALL("瘦全身", "figure.stand", ShapeGroup.SLIM, true),
    AI_BELLY("收腹", "circle.bottomhalf.filled", ShapeGroup.SLIM, true),
    AI_TUMMY("瘦肚子", "circle.bottomhalf.filled", ShapeGroup.SLIM, true),
    ARM("瘦手臂", "figure.arms.open", ShapeGroup.ARM),
    UPPER_ARM("瘦大臂", "figure.arms.open", ShapeGroup.ARM),
    FORE_ARM("瘦小臂", "figure.arms.open", ShapeGroup.ARM),
    AI_ARM("瘦手臂", "figure.arms.open", ShapeGroup.ARM, true),
    AI_UPPER_ARM("瘦大臂", "figure.arms.open", ShapeGroup.ARM, true),
    AI_FORE_ARM("瘦小臂", "figure.arms.open", ShapeGroup.ARM, true),
    LEG("瘦腿", "figure.walk", ShapeGroup.LEG),
    THIGH("瘦大腿", "figure.walk", ShapeGroup.LEG),
    CALF("瘦小腿", "figure.walk", ShapeGroup.LEG),
    AI_LEG("瘦腿", "figure.walk", ShapeGroup.LEG, true),
    AI_THIGH("瘦大腿", "figure.walk", ShapeGroup.LEG, true),
    AI_CALF("瘦小腿", "figure.walk", ShapeGroup.LEG, true),
    AI_STRAIGHT_LEG("直腿", "figure.walk", ShapeGroup.LEG, true),
    SHOULDER_LEVEL("高低肩", "level", ShapeGroup.POSTURE),
    AI_SHOULDER_LEVEL("高低肩", "level", ShapeGroup.POSTURE, true),
    AI_STRAIGHT_BACK("直背", "figure.stand.line.dotted.figure.stand", ShapeGroup.POSTURE, true),
    AI_NECK_FORWARD("脖子前倾", "figure.stand.line.dotted.figure.stand", ShapeGroup.POSTURE, true),
    SWAN_NECK("天鹅颈", "person.bust", ShapeGroup.NECK),
    SHOULDER_WIDTH("肩宽", "arrow.left.and.right", ShapeGroup.NECK),
    SQUARE_SHOULDER("直角肩", "rectangle.tophalf.inset.filled", ShapeGroup.NECK),
    NECK_WIDTH("脖子粗细", "person.bust", ShapeGroup.NECK),
    NECK_LENGTH("脖子长短", "person.bust", ShapeGroup.NECK),
    AI_SWAN_NECK("天鹅颈", "person.bust", ShapeGroup.NECK, true),
    AI_WIDE_SHOULDER("宽肩", "arrow.left.and.right", ShapeGroup.NECK, true),
    AI_NARROW_SHOULDER("窄肩", "arrow.left.and.right", ShapeGroup.NECK, true),
    AI_SQUARE_SHOULDER("直角肩", "rectangle.tophalf.inset.filled", ShapeGroup.NECK, true),
    AI_THIN_NECK("细脖子", "person.bust", ShapeGroup.NECK, true),
    AI_LONG_NECK("长脖子", "person.bust", ShapeGroup.NECK, true),
    AI_TRAPEZIUS("瘦斜方肌", "rectangle.tophalf.inset.filled", ShapeGroup.NECK, true),
    SMALL_HEAD("小头", "person.crop.circle", ShapeGroup.HEAD),
    AI_SMALL_HEAD("小头", "person.crop.circle", ShapeGroup.HEAD, true),
    CHEST("丰胸", "heart", ShapeGroup.CHEST),
    AI_CHEST("丰胸", "heart", ShapeGroup.CHEST, true),
    AI_CHEST_NATURAL("自然胸型", "heart", ShapeGroup.CHEST, true),
    AI_CHEST_LIFT("胸位提升", "heart", ShapeGroup.CHEST, true),
    HIPS("美胯", "oval.portrait", ShapeGroup.HIP),
    WAIST_HIP("腰臀比", "arrow.right.and.line.vertical.and.arrow.left", ShapeGroup.HIP),
    AI_HIPS("美胯", "oval.portrait", ShapeGroup.HIP, true),
    AI_WAIST_HIP("腰臀比", "arrow.right.and.line.vertical.and.arrow.left", ShapeGroup.HIP, true),
    AI_FULL_HIP("丰臀", "oval.portrait", ShapeGroup.HIP, true),
    AI_LIFT_HIP("提臀", "oval.portrait", ShapeGroup.HIP, true);

    /** 能不能分别调画面左边和右边。 */
    val hasSides: Boolean
        get() = when (this) {
            WAIST, ARM, UPPER_ARM, FORE_ARM, LEG, THIGH, CALF, SHOULDER_WIDTH, SQUARE_SHOULDER, CHEST, HIPS -> true
            else -> false
        }

    /** 需要哪些部位被识别出来才能做。 */
    fun available(body: ShapeBody): Boolean = when (this) {
        ARM -> body.hasUpperArm(ShapeSide.LEFT) || body.hasUpperArm(ShapeSide.RIGHT) || body.hasForeArm(ShapeSide.LEFT) || body.hasForeArm(ShapeSide.RIGHT)
        UPPER_ARM -> body.hasUpperArm(ShapeSide.LEFT) || body.hasUpperArm(ShapeSide.RIGHT)
        FORE_ARM -> body.hasForeArm(ShapeSide.LEFT) || body.hasForeArm(ShapeSide.RIGHT)
        LEG -> body.hasThigh(ShapeSide.LEFT) || body.hasThigh(ShapeSide.RIGHT) || body.hasCalf(ShapeSide.LEFT) || body.hasCalf(ShapeSide.RIGHT)
        THIGH -> body.hasThigh(ShapeSide.LEFT) || body.hasThigh(ShapeSide.RIGHT)
        CALF -> body.hasCalf(ShapeSide.LEFT) || body.hasCalf(ShapeSide.RIGHT)
        SWAN_NECK, NECK_WIDTH, NECK_LENGTH, SMALL_HEAD -> body.head != null
        else -> true
    }
}

/** 一个人的身体关键点（单位坐标）。"左 / 右"按画面上的左右算，不是这个人自己的左右。 */
data class ShapeBody(
    val left: Limb = Limb(),
    val right: Limb = Limb(),
    /** 头的中心。 */
    val head: V2? = null,
    /** 头的大致半径。 */
    val headRadius: Float = 0f,
) {
    data class Limb(
        val shoulder: V2? = null,
        val elbow: V2? = null,
        val wrist: V2? = null,
        val hip: V2? = null,
        val knee: V2? = null,
        val ankle: V2? = null,
    )

    /** 至少要有两个肩膀才能建立身体的坐标系。 */
    val isUsable: Boolean get() = left.shoulder != null && right.shoulder != null

    private fun limb(side: ShapeSide) = if (side == ShapeSide.LEFT) left else right

    fun hasUpperArm(side: ShapeSide) = limb(side).shoulder != null && limb(side).elbow != null
    fun hasForeArm(side: ShapeSide) = limb(side).elbow != null && limb(side).wrist != null
    fun hasThigh(side: ShapeSide) = limb(side).hip != null && limb(side).knee != null
    fun hasCalf(side: ShapeSide) = limb(side).knee != null && limb(side).ankle != null

    /** 所有关键点的外接框。 */
    val bounds: URect
        get() {
            val all = listOfNotNull(
                left.shoulder, left.elbow, left.wrist, left.hip, left.knee, left.ankle,
                right.shoulder, right.elbow, right.wrist, right.hip, right.knee, right.ankle, head,
            )
            if (all.isEmpty()) return URect(0f, 0f, 0f, 0f)
            return all.drop(1).fold(URect.point(all[0])) { b, p -> b.union(URect.point(p)) }
        }
}

/** 一键美体里本机能做的预设：就是一组塑形数值。 */
class ShapePreset(val title: String, val values: Map<ShapeItem, Float>) {
    val id: String get() = title

    companion object {
        val all = listOf(
            ShapePreset("自然", mapOf(ShapeItem.WAIST to 0.4f, ShapeItem.ARM to 0.3f, ShapeItem.LEG to 0.3f, ShapeItem.SMALL_HEAD to 0.15f, ShapeItem.SWAN_NECK to 0.25f)),
            ShapePreset("超模", mapOf(
                ShapeItem.WAIST to 0.65f, ShapeItem.ARM to 0.5f, ShapeItem.LEG to 0.55f, ShapeItem.SMALL_HEAD to 0.3f, ShapeItem.SWAN_NECK to 0.45f,
                ShapeItem.WAIST_HIP to 0.3f, ShapeItem.SQUARE_SHOULDER to 0.3f,
            )),
        )
    }
}

// MARK: - 变形还原

/** 变形还原的一笔：涂过的地方变形减弱，回到原样。 */
data class ShapeRestoreStroke(val points: List<V2>, /** 笔刷半径。 */ val radius: Float)

// MARK: - 做法 / AI

/** 美体塑形里的几种做法。主菜单"美体"下面的入口直接对应这几种（名字和个数不要改）。 */
enum class ShapeMode(val key: String, val title: String) {
    /** 一键美体：几套整体预设。 */
    PRESET("preset", "一键美体"),
    /** 塑形：按部位用滑块调。 */
    SHAPE("shape", "塑形"),
    /** 增高：两条辅助线框出拉伸区域，滑块把这一段拉长或压短。 */
    TALL("tall", "增高"),
    /** 瘦身：一个带弧线的框放在要瘦的地方，滑块沿弧线往里收或往外放。 */
    SLIM("slim", "瘦身"),
    /** 缩放：一个圆圈放在要改的地方，滑块把圈里的内容放大或缩小。 */
    ZOOM("zoom", "缩放");

    /** 面板顶上那排切换用的短名字。 */
    val short: String get() = if (this == PRESET) "一键" else title
}

/** 一键美体和塑形里交给 AI 做的那几项。 */
object ShapeAI {
    private const val KEEP = "人物长相、发型、姿势、服装的款式和颜色、背景都不变，结果仍然是一张真实的照片。"

    fun preset(item: ShapeItem): AIPreset? {
        val prompt = when (item) {
            ShapeItem.AI_WAIST -> "让腰部明显变细一些，腰线收紧，左右对称，上身和胯部的比例自然。"
            ShapeItem.AI_SLIM_ALL -> "让全身整体瘦一圈：脸以外的躯干、腰、手臂、腿都按比例变细，自然协调，不要夸张。"
            ShapeItem.AI_ARM -> "让两只手臂（大臂和小臂）变细一些，去掉松弛的赘肉，线条紧致，手的大小和位置不变。"
            ShapeItem.AI_UPPER_ARM -> "让大臂（肩膀到手肘）变细一些，去掉松弛的赘肉，小臂和手不变。"
            ShapeItem.AI_FORE_ARM -> "让小臂（手肘到手腕）变细一些，线条流畅，大臂和手不变。"
            ShapeItem.AI_LEG -> "让双腿（大腿和小腿）变细一些，线条流畅修长，腿的长度和位置、脚不变。"
            ShapeItem.AI_THIGH -> "让大腿变细一些，去掉内侧和外侧的赘肉，小腿和腿的长度不变。"
            ShapeItem.AI_CALF -> "让小腿变细一些，小腿肚的肌肉块更柔和，大腿和脚不变。"
            ShapeItem.AI_SHOULDER_LEVEL -> "改善高低肩：让左右两边肩膀一样高，肩线水平，头和手臂的姿势基本不变。"
            ShapeItem.AI_SWAN_NECK -> "让脖子更修长纤细，肩颈线条舒展优美，头的大小不变，保持自然。"
            ShapeItem.AI_WIDE_SHOULDER -> "让肩膀稍微宽一些，左右对称，头和手臂的大小不变，保持自然。"
            ShapeItem.AI_NARROW_SHOULDER -> "让肩膀稍微窄一些，左右对称，头和手臂的大小不变，保持自然。"
            ShapeItem.AI_SQUARE_SHOULDER -> "把溜肩改成平直利落的直角肩，肩头轮廓清楚，保持自然。"
            ShapeItem.AI_THIN_NECK -> "让脖子变细一些，颈部线条干净，头和肩膀的大小不变。"
            ShapeItem.AI_LONG_NECK -> "让脖子稍微长一些，头的大小不变，比例自然。"
            ShapeItem.AI_SMALL_HEAD -> "让头部（包括头发）整体按比例缩小一点，头身比更好，五官和脸型不变，脖子和肩膀衔接自然，头周围露出来的背景补自然。"
            ShapeItem.AI_CHEST -> "让胸部比现在明显丰满一些，左右对称，衣服被自然撑起、褶皱合理，领口的位置和露出的范围不变，不要夸张。"
            ShapeItem.AI_HIPS -> "让胯部两侧的线条更圆润流畅，填平胯部凹陷，腰到大腿过渡自然。"
            ShapeItem.AI_WAIST_HIP -> "改善腰臀比：腰细一些、臀胯稍宽一些，曲线自然，不要夸张。"
            ShapeItem.AI_BELLY -> "把腹部收平一些，腰腹线条紧致自然，衣服的褶皱保持合理。"
            ShapeItem.AI_TUMMY -> "让肚子小一圈，去掉小肚腩，腰线更明显，保持自然。"
            ShapeItem.AI_STRAIGHT_LEG -> "把腿型调直，改善 O 型腿或 X 型腿，让双腿线条笔直修长，腿的长度和位置不变。"
            ShapeItem.AI_STRAIGHT_BACK -> "改善驼背：让背部挺直、肩膀自然打开、体态挺拔。"
            ShapeItem.AI_NECK_FORWARD -> "改善脖子前倾（探颈）：让头部回到肩膀正上方，颈部线条舒展。"
            ShapeItem.AI_TRAPEZIUS -> "让斜方肌（脖子到肩膀之间）变薄一些，肩颈线条更平直修长。"
            ShapeItem.AI_CHEST_NATURAL -> "让胸型更自然饱满、左右对称，尺寸不要夸张。"
            ShapeItem.AI_CHEST_LIFT -> "把胸部的位置稍微提高一些，胸型更挺拔，保持自然。"
            ShapeItem.AI_FULL_HIP -> "让臀部更圆润饱满一些，曲线自然，衣服的褶皱保持合理。"
            ShapeItem.AI_LIFT_HIP -> "把臀线提高一些，臀部更上翘紧致，保持自然。"
            else -> return null
        }
        // 体态类本来就要改姿势，不能再说"姿势不变"。
        val tail = if (item.group == ShapeGroup.POSTURE) {
            "人物长相、发型、服装的款式和颜色、背景都不变；除了上面说的体态，其余姿势不变。结果仍然是一张真实的照片。"
        } else KEEP
        return AIPreset(title = item.title, symbol = item.symbol, prompt = prompt + tail)
    }

    /** 一键美体里的 AI 预设。 */
    val looks: List<AIPreset> = listOf(
        AIPreset(title = "自然", symbol = "figure.stand",
            prompt = "让身材比例稍微更好一些：腰、手臂、腿略微变细，脖子略修长，改动很轻、看不出修过。$KEEP"),
        AIPreset(title = "超模", symbol = "figure.walk",
            prompt = "让身材接近超模比例：头身比更好，腰和四肢更细，双腿和脖子更修长，肩线平直，仍然真实自然。$KEEP"),
        AIPreset(title = "纤细", symbol = "figure.stand",
            prompt = "让全身更纤细苗条一些：腰、手臂、腿都适度变细，比例自然协调，不要夸张。$KEEP"),
        AIPreset(title = "紧致", symbol = "figure.cooldown",
            prompt = "让身体线条更紧致：收紧腰腹、手臂和大腿的松弛感，体型大小基本不变。$KEEP"),
        AIPreset(title = "曲线", symbol = "figure.dance",
            prompt = "让身材曲线更明显：腰更细、胸和臀更饱满，呈现自然的沙漏型比例，不要夸张。$KEEP"),
        AIPreset(title = "增肌", symbol = "figure.strengthtraining.traditional",
            prompt = "让肌肉线条更明显一些：手臂、肩膀、腹部有健康的肌肉轮廓，不要夸张。$KEEP"),
    )
}

// MARK: - 参数

/**
 * 美体塑形：按人体关键点或用户摆的辅助线对身体做变形，作为编辑历史里的一步。
 * 一步里要么是增高（会改画布大小），要么是不改画布大小的那几种（瘦身框、缩放圈、塑形）。
 */
data class ShapeParams(
    /** 增高：按顺序一条一条做，后一条的位置是在前一条做完之后的画面上量的。 */
    val talls: List<ShapeTall> = emptyList(),
    val boxes: List<ShapeBox> = emptyList(),
    val spots: List<ShapeSpot> = emptyList(),
    val body: ShapeBody? = null,
    val values: Map<ShapeItem, ShapeAmount> = emptyMap(),
    val restore: List<ShapeRestoreStroke> = emptyList(),
    /** 背景保护用的人像蒙版（白 = 人）；null = 不保护。 */
    val lockMask: Bitmap? = null,
    /** AI 补好的"没有人的背景"（任意尺寸，拉到整张图）；有它时人让出来的地方直接用它。 */
    val aiPlate: Bitmap? = null,
) {
    val hasTall: Boolean get() = talls.any { it.amount != 0f }

    val hasLocal: Boolean
        get() = boxes.any { it.amount != 0f } || spots.any { it.amount != 0f } ||
            (body != null && values.any { !it.value.isZero && !it.key.isAI })

    val isIdentity: Boolean get() = !hasTall && !hasLocal

    /** plate：提前算好的背景变形权重（实时预览用），不传就现算。 */
    fun apply(src: Bitmap, plate: Warp.Plate? = null): Bitmap {
        if (isIdentity) return src
        val field = ShapeEngine.field(this, src.width, src.height) ?: return src
        return Warp.render(src, field, if (hasTall) null else lockMask, plate, aiPlate)
    }
}

/** 历史里的一步美体塑形。 */
class ShapeOp(val params: ShapeParams) : EditOp {
    override fun apply(src: Bitmap): Bitmap = params.apply(src)
    // 和 iOS 一样：塑形会挪动画面内容（增高还改画布大小），之前的文字贴纸等不能再单独合并改。
    override val changesCanvas: Boolean get() = true
}

// MARK: - 引擎

object ShapeEngine {
    const val GRID_LONG_SIDE = 224

    private enum class Kind { RADIAL, SQUEEZE, SHIFT }

    /** 局部变形的基本动作。 */
    private class Prim(
        val kind: Kind, a: V2, b: V2, r: Float, val k: Float,
        /** squeeze 沿轴线的强弱：width == 0 用"中间平、两头缓"的形状；否则是以 peak 为中心的一个鼓包。 */
        val peak: Float = 0.5f, val width: Float = 0f,
        /** squeeze 只作用在轴线的哪一侧：0 两侧，±1 一侧（按法线方向）。 */
        val side: Float = 0f,
    ) {
        val ax = a.x; val ay = a.y
        val bx = b.x; val by = b.y
        val r = max(r, 0.0001f)
        val ux: Float; val uy: Float; val length: Float
        /** 外接圆：圆外面肯定没有位移，先用它快速跳过。 */
        val cx: Float; val cy: Float; val reach2: Float

        init {
            if (kind == Kind.SQUEEZE) {
                val axis = b - a
                val len = max(axis.length, 0.0001f)
                length = len
                ux = axis.x / len; uy = axis.y / len
                val lo = if (width > 0) peak - width * 2.2f else -0.15f
                val hi = if (width > 0) peak + width * 2.2f else 1.15f
                val mid = (lo + hi) / 2 * len
                cx = a.x + ux * mid; cy = a.y + uy * mid
                val half = (hi - lo) / 2 * len
                reach2 = half * half + this.r * this.r
            } else {
                length = 1f; ux = 1f; uy = 0f
                cx = a.x; cy = a.y
                reach2 = this.r * this.r
            }
        }

        /** 把这一个动作在 (x, y) 处的位移加到 d 上。 */
        fun add(x: Float, y: Float, d: FloatArray) {
            val ex = x - cx
            val ey = y - cy
            if (ex * ex + ey * ey >= reach2) return
            when (kind) {
                Kind.RADIAL -> {
                    val d2 = (ex * ex + ey * ey) / (r * r)
                    val f = (1 - d2) * (1 - d2) * k
                    d[0] += (x - bx) * f
                    d[1] += (y - by) * f
                }
                Kind.SHIFT -> {
                    val d2 = (ex * ex + ey * ey) / (r * r)
                    val f = (1 - d2) * (1 - d2) * (1 - d2)
                    d[0] -= bx * f
                    d[1] -= by * f
                }
                Kind.SQUEEZE -> {
                    val vx = x - ax
                    val vy = y - ay
                    // 法线方向是 (-uy, ux)。
                    val q = vy * ux - vx * uy
                    val xi = abs(q) / r
                    if (xi >= 1) return
                    val t = (vx * ux + vy * uy) / length
                    var w: Float
                    if (width > 0) {
                        val u = (t - peak) / (width * 2.2f)
                        if (abs(u) >= 1) return
                        w = (1 - u * u) * (1 - u * u)
                    } else {
                        if (t <= -0.15f || t >= 1.15f) return
                        w = smooth((t + 0.15f) / 0.35f) * smooth((1.15f - t) / 0.35f)
                    }
                    if (side != 0f) w *= smooth(side * q / (0.2f * r))
                    val m = q * k * w * (1 - xi * xi) * (1 - xi * xi)
                    d[0] -= uy * m
                    d[1] += ux * m
                }
            }
        }
    }

    private fun smooth(x: Float): Float {
        val t = x.coerceIn(0f, 1f)
        return t * t * (3 - 2 * t)
    }

    /** 瘦身框和缩放圈对应的动作。 */
    private fun manualPrims(params: ShapeParams): List<Prim> {
        val prims = ArrayList<Prim>()
        for (box in params.boxes) {
            if (box.amount == 0f) continue
            val c = box.center
            val down = V2(-sin(box.angle), cos(box.angle))
            val half = box.height / 2
            // 弧线在框的中段离中线大约 0.33 个框宽；作用范围取 0.75 个框宽，位移最大的地方正好落在弧线上。
            prims += Prim(Kind.SQUEEZE, c - down * half, c + down * half, box.width * 0.75f, box.amount * 0.34f, peak = 0.5f, width = 0.227f)
        }
        for (spot in params.spots) {
            if (spot.amount == 0f) continue
            prims += Prim(Kind.RADIAL, spot.center, spot.center, spot.radius, -spot.amount * 0.5f)
        }
        return prims
    }

    /** 塑形各项对应的动作：全部从肩、胯、手肘这些关键点推出来。 */
    private fun bodyPrims(params: ShapeParams): List<Prim> {
        val body = params.body ?: return emptyList()
        val sl = body.left.shoulder ?: return emptyList()
        val sr = body.right.shoulder ?: return emptyList()
        fun amount(item: ShapeItem) = params.values[item] ?: ShapeAmount()
        val prims = ArrayList<Prim>()

        val sw = max((sr - sl).length, 0.01f)
        val ms = (sl + sr) / 2f
        val across = (sr - sl) / sw
        // 身体的"下"：垂直于肩线、朝画面下方。
        var down = V2(-across.y, across.x)
        if (down.y < 0) down = -down
        var mh = ms + down * (sw * 1.5f)
        var hw = sw * 0.85f
        val lh = body.left.hip
        val rh = body.right.hip
        if (lh != null && rh != null) {
            mh = (lh + rh) / 2f
            hw = max((rh - lh).length, sw * 0.5f)
        } else {
            val one = lh ?: rh
            if (one != null) {
                // 只看到一边的胯：沿肩线方向挪到身体中线上。
                mh = one - across * (one - ms).dot(across)
            }
        }
        val torso = max((mh - ms).length, sw * 0.6f)
        val spine = (mh - ms) / torso
        // 沿脊柱这条轴线的法线朝哪边是画面左边。
        val spineNormal = V2(-spine.y, spine.x)
        val leftSign = if ((sl - ms).dot(spineNormal) >= 0) 1f else -1f

        /** 沿脊柱的收放：peak 是从肩（0）到胯（1）的位置。左右数值一样就两侧一起，不一样就各做各的。 */
        fun torsoSqueeze(l: Float, r: Float, peak: Float, width: Float, reach: Float, strength: Float) {
            if (l == 0f && r == 0f) return
            if (l == r) {
                prims += Prim(Kind.SQUEEZE, ms, mh, reach, l * strength, peak = peak, width = width)
            } else {
                if (l != 0f) prims += Prim(Kind.SQUEEZE, ms, mh, reach, l * strength, peak = peak, width = width, side = leftSign)
                if (r != 0f) prims += Prim(Kind.SQUEEZE, ms, mh, reach, r * strength, peak = peak, width = width, side = -leftSign)
            }
        }

        // 瘦腰、美胯、腰臀比
        val waist = amount(ShapeItem.WAIST)
        val hips = amount(ShapeItem.HIPS)
        val ratio = amount(ShapeItem.WAIST_HIP).both
        val reach = max(sw, hw) * 0.95f
        torsoSqueeze(waist.leftTotal, waist.rightTotal, 0.62f, 0.2f, reach, 0.24f)
        torsoSqueeze(hips.leftTotal, hips.rightTotal, 1.02f, 0.16f, max(sw, hw) * 1.05f, -0.16f)
        if (ratio != 0f) {
            prims += Prim(Kind.SQUEEZE, ms, mh, reach, ratio * 0.16f, peak = 0.62f, width = 0.2f)
            prims += Prim(Kind.SQUEEZE, ms, mh, max(sw, hw) * 1.05f, -ratio * 0.12f, peak = 1.05f, width = 0.16f)
        }

        // 瘦全身：沿整个人的长轴往中间收。
        val all = amount(ShapeItem.SLIM_ALL).both
        if (all != 0f) {
            val box = body.bounds
            val top = body.head?.let { it - spine * body.headRadius } ?: (ms - spine * (sw * 0.9f))
            var bottom = mh + spine * (sw * 0.5f)
            val lows = listOfNotNull(body.left.ankle, body.right.ankle, body.left.knee, body.right.knee)
            val lowest = lows.maxByOrNull { (it - ms).dot(spine) }
            if (lowest != null) bottom = ms + spine * max((lowest - ms).dot(spine), torso)
            val half = max(max(box.width, box.height) * 0.2f, sw * 1.2f)
            prims += Prim(Kind.SQUEEZE, top, bottom, half, all * 0.13f)
        }

        // 手臂、腿：沿着每一段肢体往它的中轴线收。
        fun limb(from: V2?, to: V2?, value: Float, reach: Float, cap: Float, strength: Float) {
            if (value == 0f || from == null || to == null) return
            val length = (to - from).length
            if (length <= sw * 0.15f) return
            prims += Prim(Kind.SQUEEZE, from, to, min(max(length * reach, sw * 0.16f), cap), value * strength)
        }
        val arm = amount(ShapeItem.ARM)
        val upper = amount(ShapeItem.UPPER_ARM)
        val fore = amount(ShapeItem.FORE_ARM)
        limb(body.left.shoulder, body.left.elbow, arm.leftTotal + upper.leftTotal, 0.42f, sw * 0.5f, 0.32f)
        limb(body.right.shoulder, body.right.elbow, arm.rightTotal + upper.rightTotal, 0.42f, sw * 0.5f, 0.32f)
        limb(body.left.elbow, body.left.wrist, arm.leftTotal + fore.leftTotal, 0.36f, sw * 0.42f, 0.28f)
        limb(body.right.elbow, body.right.wrist, arm.rightTotal + fore.rightTotal, 0.36f, sw * 0.42f, 0.28f)
        val leg = amount(ShapeItem.LEG)
        val thigh = amount(ShapeItem.THIGH)
        val calf = amount(ShapeItem.CALF)
        limb(body.left.hip, body.left.knee, leg.leftTotal + thigh.leftTotal, 0.38f, hw * 0.75f, 0.24f)
        limb(body.right.hip, body.right.knee, leg.rightTotal + thigh.rightTotal, 0.38f, hw * 0.75f, 0.24f)
        limb(body.left.knee, body.left.ankle, leg.leftTotal + calf.leftTotal, 0.3f, hw * 0.6f, 0.22f)
        limb(body.right.knee, body.right.ankle, leg.rightTotal + calf.rightTotal, 0.3f, hw * 0.6f, 0.22f)

        // 肩
        val up = -spine
        val level = amount(ShapeItem.SHOULDER_LEVEL).both
        if (level != 0f) {
            prims += Prim(Kind.SHIFT, sl, up * (level * sw * 0.07f), sw * 0.6f, 0f)
            prims += Prim(Kind.SHIFT, sr, up * (-level * sw * 0.07f), sw * 0.6f, 0f)
        }
        val wide = amount(ShapeItem.SHOULDER_WIDTH)
        if (wide.leftTotal != 0f) prims += Prim(Kind.SHIFT, sl, -across * (wide.leftTotal * sw * 0.09f), sw * 0.5f, 0f)
        if (wide.rightTotal != 0f) prims += Prim(Kind.SHIFT, sr, across * (wide.rightTotal * sw * 0.09f), sw * 0.5f, 0f)
        val square = amount(ShapeItem.SQUARE_SHOULDER)
        if (square.leftTotal != 0f) {
            prims += Prim(Kind.SHIFT, sl - across * (sw * 0.06f), up * (square.leftTotal * sw * 0.09f), sw * 0.4f, 0f)
        }
        if (square.rightTotal != 0f) {
            prims += Prim(Kind.SHIFT, sr + across * (sw * 0.06f), up * (square.rightTotal * sw * 0.09f), sw * 0.4f, 0f)
        }

        // 脖子和头
        val hc = body.head
        if (hc != null) {
            val hr = max(body.headRadius, sw * 0.3f)
            val neckBase = ms + (hc - ms) * 0.25f
            val neckTop = ms + (hc - ms) * 0.6f
            val neckUp = (hc - ms).normalized()
            val swan = amount(ShapeItem.SWAN_NECK).both
            if (swan != 0f) {
                // 肩线靠脖子的两侧往下沉一点，脖子收细一点，头再往上提一点。
                prims += Prim(Kind.SHIFT, sl + (ms - sl) * 0.35f, spine * (swan * sw * 0.07f), sw * 0.45f, 0f)
                prims += Prim(Kind.SHIFT, sr + (ms - sr) * 0.35f, spine * (swan * sw * 0.07f), sw * 0.45f, 0f)
                prims += Prim(Kind.SQUEEZE, ms, neckTop, sw * 0.32f, swan * 0.14f)
                prims += Prim(Kind.SHIFT, hc, neckUp * (swan * sw * 0.035f), hr * 1.9f, 0f)
            }
            val thin = amount(ShapeItem.NECK_WIDTH).both
            if (thin != 0f) prims += Prim(Kind.SQUEEZE, ms, neckTop, sw * 0.34f, thin * 0.2f)
            val long = amount(ShapeItem.NECK_LENGTH).both
            if (long != 0f) prims += Prim(Kind.SHIFT, hc, neckUp * (long * sw * 0.07f), hr * 2f, 0f)
            val small = amount(ShapeItem.SMALL_HEAD).both
            if (small != 0f) {
                // 以脖子根为锚点缩放，头变小了也还是接在脖子上。
                prims += Prim(Kind.RADIAL, hc, neckBase, hr * 1.75f, small * 0.22f)
            }
        }

        // 胸
        val chest = amount(ShapeItem.CHEST)
        val chestCenter = ms + spine * (torso * 0.34f)
        if (chest.leftTotal != 0f) {
            val c = chestCenter - across * (sw * 0.24f)
            prims += Prim(Kind.RADIAL, c, c, sw * 0.3f, -chest.leftTotal * 0.34f)
        }
        if (chest.rightTotal != 0f) {
            val c = chestCenter + across * (sw * 0.24f)
            prims += Prim(Kind.RADIAL, c, c, sw * 0.3f, -chest.rightTotal * 0.34f)
        }
        return prims
    }

    // MARK: 位移场

    /** 增高的每一条带子在各自画面尺寸下的几何，以及最后的画面大小。 */
    fun tallMaps(talls: List<ShapeTall>, size: V2): Pair<List<ShapeTallMap>, V2> {
        var current = size
        val maps = ArrayList<ShapeTallMap>()
        for (band in talls) {
            if (band.amount == 0f) continue
            val map = ShapeTallMap(band, current)
            maps += map
            current = map.outSize
        }
        return maps to current
    }

    /** 变形还原用：每一笔拆成一段段线段，提前算好。 */
    private class RestoreSegment(val ax: Float, val ay: Float, val dx: Float, val dy: Float, val inverse: Float, val r: Float)

    private fun restoreSegments(strokes: List<ShapeRestoreStroke>): List<RestoreSegment> {
        val out = ArrayList<RestoreSegment>()
        for (stroke in strokes) {
            if (stroke.points.isEmpty()) continue
            val r = max(stroke.radius, 0.002f)
            val pts = stroke.points
            if (pts.size == 1) {
                out += RestoreSegment(pts[0].x, pts[0].y, 0f, 0f, 0f, r)
            } else {
                for (i in 1 until pts.size) {
                    val d = pts[i] - pts[i - 1]
                    val l2 = d.x * d.x + d.y * d.y
                    out += RestoreSegment(pts[i - 1].x, pts[i - 1].y, d.x, d.y, if (l2 > 1e-9f) 1 / l2 else 0f, r)
                }
            }
        }
        return out
    }

    /** 变形还原：某一点离涂抹过的地方有多近（0...1）。笔刷中间一半完全还原，往外平滑过渡。 */
    private fun restoreWeight(segments: List<RestoreSegment>, x: Float, y: Float): Float {
        var best = 0f
        for (s in segments) {
            val vx = x - s.ax
            val vy = y - s.ay
            val t = ((vx * s.dx + vy * s.dy) * s.inverse).coerceIn(0f, 1f)
            val ex = vx - s.dx * t
            val ey = vy - s.dy * t
            val d2 = ex * ex + ey * ey
            if (d2 >= s.r * s.r) continue
            val w = 1 - smooth((sqrt(d2) - s.r * 0.5f) / (s.r * 0.5f))
            if (w > best) {
                best = w
                if (best >= 1) return 1f
            }
        }
        return best
    }

    /** 把所有变形合成一张位移场。宽高只用来算宽高比，和分辨率无关。 */
    fun field(params: ShapeParams, imageW: Int, imageH: Int): WarpField? {
        val long = max(imageW, imageH).toFloat()
        if (long <= 0) return null
        val unit = V2(imageW / long, imageH / long)
        val (maps, outSize) = tallMaps(params.talls, unit)
        val prims = if (maps.isEmpty()) manualPrims(params) + bodyPrims(params) else emptyList()
        if (maps.isEmpty() && prims.isEmpty()) return null
        val strokes = if (maps.isEmpty()) restoreSegments(params.restore) else emptyList()
        val reversed = maps.reversed()

        val outLong = max(outSize.x, outSize.y)
        val gw = max(2, (outSize.x / outLong * GRID_LONG_SIDE).roundToInt())
        val gh = max(2, (outSize.y / outLong * GRID_LONG_SIDE).roundToInt())
        val stepX = outSize.x / gw
        val stepY = outSize.y / gh
        val dxs = FloatArray(gw * gh)
        val dys = FloatArray(gw * gh)
        val d = FloatArray(2)
        var peak = 0f
        for (j in 0 until gh) {
            val py = (j + 0.5f) * stepY
            for (i in 0 until gw) {
                val px = (i + 0.5f) * stepX
                var qx = px
                var qy = py
                for (map in reversed) {
                    val q = map.source(qx, qy)
                    qx = q.x; qy = q.y
                }
                d[0] = 0f; d[1] = 0f
                for (prim in prims) prim.add(qx, qy, d)
                if (strokes.isNotEmpty() && (d[0] != 0f || d[1] != 0f)) {
                    val keep = 1 - restoreWeight(strokes, px, py)
                    d[0] *= keep
                    d[1] *= keep
                }
                val offX = qx + d[0] - px
                val offY = qy + d[1] - py
                val index = j * gw + i
                dxs[index] = offX
                dys[index] = offY
                peak = max(peak, max(abs(offX), abs(offY)))
            }
        }
        return WarpField(gw, gh, dxs, dys, outSize.x, outSize.y, peak)
    }
}
