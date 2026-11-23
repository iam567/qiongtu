package com.taoo.xiutu.tools.overlay

import android.graphics.Bitmap
import com.taoo.xiutu.editor.Tool
import java.util.UUID

// MARK: 文字 / 贴纸的数据

/** 一个不透明的颜色（sRGB，0...1）。存成数值方便比较。 */
data class OverlayColor(val r: Float, val g: Float, val b: Float) {
    val isLight: Boolean get() = 0.299f * r + 0.587f * g + 0.114f * b > 0.6f

    /** 转成 Android 的 ARGB。 */
    fun argb(alpha: Float = 1f): Int {
        fun c(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        return (c(alpha) shl 24) or (c(r) shl 16) or (c(g) shl 8) or c(b)
    }

    companion object {
        fun of(r: Float, g: Float, b: Float) = OverlayColor(r.coerceIn(0f, 1f), g.coerceIn(0f, 1f), b.coerceIn(0f, 1f))
        fun of(r: Double, g: Double, b: Double) = of(r.toFloat(), g.toFloat(), b.toFloat())
        val white = OverlayColor(1f, 1f, 1f)
        val black = OverlayColor(0f, 0f, 0f)

        /** 面板上的一排常用色。 */
        val palette: List<OverlayColor> = listOf(
            white, black,
            of(0.62, 0.62, 0.64),
            of(1.0, 0.27, 0.27),
            of(0.80, 0.12, 0.18),
            of(1.0, 0.58, 0.0),
            of(1.0, 0.84, 0.04),
            of(1.0, 0.95, 0.72),
            of(0.2, 0.82, 0.35),
            of(0.55, 0.9, 0.78),
            of(0.2, 0.78, 0.9),
            of(0.04, 0.52, 1.0),
            of(0.12, 0.2, 0.5),
            of(0.69, 0.32, 0.87),
            of(1.0, 0.45, 0.7),
            of(1.0, 0.8, 0.86),
            of(0.55, 0.36, 0.24),
        )
    }
}

/** 底色的形状。 */
enum class OverlayShape(val title: String) {
    RECT("直角"), ROUNDED("圆角"), CAPSULE("胶囊"), ELLIPSE("椭圆"), BUBBLE("气泡"),
    SLANT("斜切"), TAG("标签"), RIBBON("丝带"), MARKER("荧光笔"),
}

enum class OverlayAlign(val symbol: String) {
    LEFT("text.alignleft"), CENTER("text.aligncenter"), RIGHT("text.alignright"),
}

/** 形状的种类。 */
enum class GraphicKind(val title: String, val symbol: String) {
    RECT("矩形", "rectangle.fill"),
    ELLIPSE("圆形", "circle.fill"),
    POLYGON("多边形", "hexagon.fill"),
    STAR("星形", "star.fill"),
    HEART("心形", "heart.fill"),
    ARROW("箭头", "arrowshape.right.fill"),
    BUBBLE("气泡", "bubble.left.fill"),
}

/** 一个形状（方块、圆、多边形……）：画在自己的位图里，和文字、贴纸一样可以拖动、缩放、旋转。 */
data class GraphicStyle(
    val kind: GraphicKind = GraphicKind.RECT,
    /** 高 / 宽。 */
    val aspect: Float = 1f,
    /** 圆角，0...1（矩形、多边形、气泡）。 */
    val corner: Float = 0f,
    /** 切角大小，0...0.5（矩形）。 */
    val cut: Float = 0f,
    /** 切哪几个角：左上 1、右上 2、右下 4、左下 8。 */
    val cutCorners: Int = 0,
    /** 多边形的边数 / 星形的角数。 */
    val sides: Int = 6,
    /** 是否填充颜色（不填充就只剩描边）。 */
    val fill: Boolean = true,
)

/** 图片贴纸用的位图。按"是不是同一张图"来比较（普通类，equals 就是同一个对象）。 */
class OverlayImage(val bitmap: Bitmap)

/**
 * 画面上的一个文字或贴纸。
 * 所有尺寸都是相对值（相对图片宽度或相对字号），所以预览和原图导出的效果一致。
 */
data class OverlayItem(
    val id: String = UUID.randomUUID().toString(),
    val text: String,
    /** true = 贴纸（表情或图片）：不能改文字内容，也不套文字样式。 */
    val isSticker: Boolean = false,
    /** 图片贴纸。不为空时画这张图，text 只是个占位。 */
    val image: OverlayImage? = null,
    /** 形状。不为空时画这个形状（颜色用 color），text 只是个占位。 */
    val graphic: GraphicStyle? = null,
    /** 中心点，归一化坐标，原点在左上角。 */
    val cx: Float = 0.5f,
    val cy: Float = 0.5f,
    /** 字号（图片贴纸是宽度），相对于图片宽度。 */
    val size: Float = 0.07f,
    val scale: Float = 1f,
    /** 弧度，正数 = 顺时针。 */
    val rotation: Float = 0f,
    /** 整体不透明度。 */
    val opacity: Float = 1f,

    // 字体和排版
    /** 字体标识，见 OverlayFonts。找不到时退回系统字体。 */
    val fontID: String = DEFAULT_FONT_ID,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val align: OverlayAlign = OverlayAlign.CENTER,
    /** 竖排：从上往下写，一列写完换到左边一列（中文直排的习惯）。 */
    val vertical: Boolean = false,
    /**
     * 文字框拉出来的长度（横排是宽、竖排是高），单位是"字号的倍数"；字排满了自动换行 / 换列。
     * 0 = 没拉过，框跟着字走，只按回车换行。
     */
    val wrap: Float = 0f,
    /** 字距、行距，单位是"字号的倍数"。 */
    val letterSpacing: Float = 0f,
    val lineSpacing: Float = 0f,
    val color: OverlayColor = OverlayColor.white,

    // 描边（图片贴纸上是"白边"）
    val strokeOn: Boolean = false,
    val strokeColor: OverlayColor = OverlayColor.black,
    /** 0...1 */
    val strokeWidth: Float = 0.5f,

    // 阴影
    val shadowOn: Boolean = false,
    val shadowColor: OverlayColor = OverlayColor.black,
    /** 虚实：0 = 实，1 = 虚。 */
    val shadowBlur: Float = 0.35f,
    /** 方向，度。0 = 向右，90 = 向下。 */
    val shadowAngle: Float = 60f,
    /** 距离，0...1。 */
    val shadowDistance: Float = 0.25f,
    val shadowOpacity: Float = 0.65f,

    // 底色
    val boxOn: Boolean = false,
    val boxColor: OverlayColor = OverlayColor.black,
    val boxOpacity: Float = 1f,
    val boxShape: OverlayShape = OverlayShape.ROUNDED,
    /** 文字四周留白，0...1。 */
    val boxPadding: Float = 0.5f,

    // 外发光
    val glowOn: Boolean = false,
    val glowColor: OverlayColor = OverlayColor.of(1.0, 0.45, 0.7),
    val glowSize: Float = 0.5f,
    val glowStrength: Float = 0.6f,
) {
    val isImage: Boolean get() = image != null
    val isGraphic: Boolean get() = graphic != null

    /** 接着改这一项用的工具。 */
    val tool: Tool get() = when {
        isGraphic -> Tool.GRAPHIC
        isSticker -> Tool.STICKER
        else -> Tool.TEXT
    }

    /** 只保留会影响"画出来长什么样"的部分：位置和角度清零。用来判断要不要重新渲染。 */
    val appearance: OverlayItem get() = copy(cx = 0f, cy = 0f, rotation = 0f)

    companion object {
        const val DEFAULT_FONT_ID = "sys.semibold"
        /** 图片贴纸的 text 占位：确认时会丢掉"没有文字"的项，图片贴纸靠它留下来。 */
        const val IMAGE_PLACEHOLDER = "￼"
    }
}

// MARK: 花字（一键样式）

/** 一组现成的文字样式。只改样式，不动字体、位置和大小。 */
class OverlayPreset(val id: String, val title: String, private val apply: (OverlayItem) -> OverlayItem) {
    /** 先把样式清回最朴素的状态，再套这一组。 */
    fun applied(to: OverlayItem): OverlayItem = apply(reset(to))

    companion object {
        fun reset(item: OverlayItem): OverlayItem {
            val blank = OverlayItem(text = "")
            return item.copy(
                color = blank.color, opacity = 1f,
                strokeOn = false, strokeColor = blank.strokeColor, strokeWidth = blank.strokeWidth,
                shadowOn = false, shadowColor = blank.shadowColor, shadowBlur = blank.shadowBlur,
                shadowAngle = blank.shadowAngle, shadowDistance = blank.shadowDistance, shadowOpacity = blank.shadowOpacity,
                boxOn = false, boxColor = blank.boxColor, boxOpacity = 1f, boxShape = blank.boxShape, boxPadding = blank.boxPadding,
                glowOn = false, glowColor = blank.glowColor, glowSize = blank.glowSize, glowStrength = blank.glowStrength,
            )
        }

        private val W = OverlayColor.white
        private val B = OverlayColor.black

        val all: List<OverlayPreset> = listOf(
            OverlayPreset("plain", "纯色") { it },
            OverlayPreset("whiteStroke", "白字黑边") { it.copy(color = W, strokeOn = true, strokeColor = B, strokeWidth = 0.5f) },
            OverlayPreset("blackStroke", "黑字白边") { it.copy(color = B, strokeOn = true, strokeColor = W, strokeWidth = 0.55f) },
            OverlayPreset("variety", "综艺") {
                it.copy(
                    color = OverlayColor.of(1.0, 0.84, 0.04), strokeOn = true, strokeColor = B, strokeWidth = 0.6f,
                    shadowOn = true, shadowColor = B, shadowBlur = 0f, shadowDistance = 0.22f, shadowAngle = 45f, shadowOpacity = 1f,
                )
            },
            OverlayPreset("softShadow", "柔影") {
                it.copy(color = W, shadowOn = true, shadowColor = B, shadowBlur = 0.6f, shadowDistance = 0.12f, shadowAngle = 90f, shadowOpacity = 0.7f)
            },
            OverlayPreset("hardShadow", "立体") {
                it.copy(
                    color = W, shadowOn = true, shadowColor = OverlayColor.of(1.0, 0.27, 0.27), shadowBlur = 0f,
                    shadowDistance = 0.2f, shadowAngle = 40f, shadowOpacity = 1f,
                )
            },
            OverlayPreset("neonPink", "霓虹粉") {
                it.copy(color = W, glowOn = true, glowColor = OverlayColor.of(1.0, 0.3, 0.65), glowSize = 0.55f, glowStrength = 0.8f)
            },
            OverlayPreset("neonBlue", "霓虹蓝") {
                it.copy(color = W, glowOn = true, glowColor = OverlayColor.of(0.2, 0.7, 1.0), glowSize = 0.55f, glowStrength = 0.8f)
            },
            OverlayPreset("cute", "可爱") {
                val pink = OverlayColor.of(1.0, 0.45, 0.7)
                it.copy(
                    color = pink, strokeOn = true, strokeColor = W, strokeWidth = 0.7f,
                    shadowOn = true, shadowColor = pink, shadowBlur = 0.5f, shadowDistance = 0.1f, shadowAngle = 90f, shadowOpacity = 0.5f,
                )
            },
            OverlayPreset("darkBox", "黑底") { it.copy(color = W, boxOn = true, boxColor = B, boxOpacity = 0.6f, boxShape = OverlayShape.ROUNDED) },
            OverlayPreset("whitePill", "白胶囊") { it.copy(color = B, boxOn = true, boxColor = W, boxShape = OverlayShape.CAPSULE) },
            OverlayPreset("marker", "荧光笔") {
                it.copy(color = B, boxOn = true, boxColor = OverlayColor.of(1.0, 0.84, 0.04), boxShape = OverlayShape.MARKER)
            },
            OverlayPreset("bubble", "气泡") { it.copy(color = B, boxOn = true, boxColor = W, boxShape = OverlayShape.BUBBLE, shadowOn = false) },
            OverlayPreset("redTag", "红标签") {
                it.copy(color = W, boxOn = true, boxColor = OverlayColor.of(0.9, 0.16, 0.2), boxShape = OverlayShape.TAG)
            },
            OverlayPreset("ribbon", "丝带") {
                it.copy(color = W, boxOn = true, boxColor = OverlayColor.of(0.12, 0.2, 0.5), boxShape = OverlayShape.RIBBON)
            },
        )
    }
}
