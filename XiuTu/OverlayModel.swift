import CoreGraphics
import Foundation

// MARK: - 文字 / 贴纸的数据

/// 一个不透明的颜色（sRGB，0...1）。存成数值方便比较，也方便存自定义颜色。
struct OverlayColor: Equatable, Hashable {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat

    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    static let white = OverlayColor(1, 1, 1)
    static let black = OverlayColor(0, 0, 0)

    var isLight: Bool { 0.299 * r + 0.587 * g + 0.114 * b > 0.6 }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: min(max(alpha, 0), 1))
    }

    /// 面板上的一排常用色。
    static let palette: [OverlayColor] = [
        .white, .black,
        OverlayColor(0.62, 0.62, 0.64),
        OverlayColor(1.0, 0.27, 0.27),
        OverlayColor(0.80, 0.12, 0.18),
        OverlayColor(1.0, 0.58, 0.0),
        OverlayColor(1.0, 0.84, 0.04),
        OverlayColor(1.0, 0.95, 0.72),
        OverlayColor(0.2, 0.82, 0.35),
        OverlayColor(0.55, 0.9, 0.78),
        OverlayColor(0.2, 0.78, 0.9),
        OverlayColor(0.04, 0.52, 1.0),
        OverlayColor(0.12, 0.2, 0.5),
        OverlayColor(0.69, 0.32, 0.87),
        OverlayColor(1.0, 0.45, 0.7),
        OverlayColor(1.0, 0.8, 0.86),
        OverlayColor(0.55, 0.36, 0.24),
    ]
}

/// 底色的形状。
enum OverlayShape: String, CaseIterable, Identifiable {
    case rect, rounded, capsule, ellipse, bubble, slant, tag, ribbon, marker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rect: return "直角"
        case .rounded: return "圆角"
        case .capsule: return "胶囊"
        case .ellipse: return "椭圆"
        case .bubble: return "气泡"
        case .slant: return "斜切"
        case .tag: return "标签"
        case .ribbon: return "丝带"
        case .marker: return "荧光笔"
        }
    }
}

enum OverlayAlign: String, CaseIterable, Identifiable {
    case left, center, right

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

/// 形状的种类。
enum GraphicKind: String, CaseIterable, Identifiable {
    case rect, ellipse, polygon, star, heart, arrow, bubble

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rect: return "矩形"
        case .ellipse: return "圆形"
        case .polygon: return "多边形"
        case .star: return "星形"
        case .heart: return "心形"
        case .arrow: return "箭头"
        case .bubble: return "气泡"
        }
    }

    var symbol: String {
        switch self {
        case .rect: return "rectangle.fill"
        case .ellipse: return "circle.fill"
        case .polygon: return "hexagon.fill"
        case .star: return "star.fill"
        case .heart: return "heart.fill"
        case .arrow: return "arrowshape.right.fill"
        case .bubble: return "bubble.left.fill"
        }
    }
}

/// 一个形状（方块、圆、多边形……）：画在自己的位图里，和文字、贴纸一样可以拖动、缩放、旋转。
struct GraphicStyle: Equatable {
    var kind: GraphicKind = .rect
    /// 高 / 宽。
    var aspect: CGFloat = 1
    /// 圆角，0...1（矩形、多边形、气泡）。
    var corner: CGFloat = 0
    /// 切角大小，0...0.5（矩形）。
    var cut: CGFloat = 0
    /// 切哪几个角：左上 1、右上 2、右下 4、左下 8。
    var cutCorners = 0
    /// 多边形的边数 / 星形的角数。
    var sides = 6
    /// 是否填充颜色（不填充就只剩描边）。
    var fill = true
}

/// 图片贴纸用的位图。按"是不是同一张图"来比较。
struct OverlayImage: Equatable {
    let cg: CGImage

    static func == (a: OverlayImage, b: OverlayImage) -> Bool { a.cg === b.cg }
}

/// 画面上的一个文字或贴纸。
/// 所有尺寸都是相对值（相对图片宽度或相对字号），所以预览和原图导出的效果一致。
struct OverlayItem: Identifiable, Equatable {
    var id = UUID()
    var text: String
    /// true = 贴纸（表情或图片）：不能改文字内容，也不套文字样式。
    var isSticker = false
    /// 图片贴纸。不为空时画这张图，text 只是个占位。
    var image: OverlayImage? = nil
    /// 形状。不为空时画这个形状（颜色用 color），text 只是个占位。
    var graphic: GraphicStyle? = nil
    /// 中心点，归一化坐标，原点在左上角。
    var center = CGPoint(x: 0.5, y: 0.5)
    /// 字号（图片贴纸是宽度），相对于图片宽度。
    var size: CGFloat = 0.07
    var scale: CGFloat = 1
    /// 弧度，正数 = 顺时针。
    var rotation: CGFloat = 0
    /// 整体不透明度。
    var opacity: CGFloat = 1

    // 字体和排版
    /// 字体的稳定标识：内置的是 "sys.xxx"，其余是字体的 PostScript 名。找不到时退回系统字体。
    var fontID = OverlayItem.defaultFontID
    var bold = false
    var italic = false
    var align: OverlayAlign = .center
    /// 竖排：从上往下写，一列写完换到左边一列（中文直排的习惯）。
    var vertical = false
    /// 文字框拉出来的长度（横排是宽、竖排是高），单位是"字号的倍数"；字排满了自动换行 / 换列。
    /// 0 = 没拉过，框跟着字走，只按回车换行。
    var wrap: CGFloat = 0
    /// 字距、行距，单位是"字号的倍数"。
    var letterSpacing: CGFloat = 0
    var lineSpacing: CGFloat = 0
    var color = OverlayColor.white

    // 描边（图片贴纸上是"白边"）
    var strokeOn = false
    var strokeColor = OverlayColor.black
    /// 0...1
    var strokeWidth: CGFloat = 0.5

    // 阴影
    var shadowOn = false
    var shadowColor = OverlayColor.black
    /// 虚实：0 = 实（边缘清楚），1 = 虚。
    var shadowBlur: CGFloat = 0.35
    /// 方向，度。0 = 向右，90 = 向下。
    var shadowAngle: CGFloat = 60
    /// 距离，0...1。
    var shadowDistance: CGFloat = 0.25
    var shadowOpacity: CGFloat = 0.65

    // 底色
    var boxOn = false
    var boxColor = OverlayColor.black
    var boxOpacity: CGFloat = 1
    var boxShape: OverlayShape = .rounded
    /// 文字四周留白，0...1。
    var boxPadding: CGFloat = 0.5

    // 外发光
    var glowOn = false
    var glowColor = OverlayColor(1.0, 0.45, 0.7)
    var glowSize: CGFloat = 0.5
    var glowStrength: CGFloat = 0.6

    static let defaultFontID = "sys.semibold"
    /// 图片贴纸的 text 占位：编辑器确认时会丢掉"没有文字"的项，图片贴纸靠它留下来。
    static let imagePlaceholder = "\u{FFFC}"

    var isImage: Bool { image != nil }
    var isGraphic: Bool { graphic != nil }

    /// 只保留会影响"画出来长什么样"的部分：位置和角度清零。用来判断要不要重新渲染。
    var appearance: OverlayItem {
        var copy = self
        copy.center = .zero
        copy.rotation = 0
        return copy
    }
}

// MARK: - 花字（一键样式）

/// 一组现成的文字样式。只改样式，不动字体、位置和大小。
struct OverlayPreset: Identifiable {
    let id: String
    let title: String
    let apply: (inout OverlayItem) -> Void

    /// 先把样式清回最朴素的状态，再套这一组。
    func applied(to item: OverlayItem) -> OverlayItem {
        var out = item
        OverlayPreset.reset(&out)
        apply(&out)
        return out
    }

    static func reset(_ item: inout OverlayItem) {
        let blank = OverlayItem(text: "")
        item.color = blank.color
        item.opacity = 1
        item.strokeOn = false
        item.strokeColor = blank.strokeColor
        item.strokeWidth = blank.strokeWidth
        item.shadowOn = false
        item.shadowColor = blank.shadowColor
        item.shadowBlur = blank.shadowBlur
        item.shadowAngle = blank.shadowAngle
        item.shadowDistance = blank.shadowDistance
        item.shadowOpacity = blank.shadowOpacity
        item.boxOn = false
        item.boxColor = blank.boxColor
        item.boxOpacity = 1
        item.boxShape = blank.boxShape
        item.boxPadding = blank.boxPadding
        item.glowOn = false
        item.glowColor = blank.glowColor
        item.glowSize = blank.glowSize
        item.glowStrength = blank.glowStrength
    }

    static let all: [OverlayPreset] = [
        OverlayPreset(id: "plain", title: "纯色") { _ in },
        OverlayPreset(id: "whiteStroke", title: "白字黑边") { i in
            i.color = .white; i.strokeOn = true; i.strokeColor = .black; i.strokeWidth = 0.5
        },
        OverlayPreset(id: "blackStroke", title: "黑字白边") { i in
            i.color = .black; i.strokeOn = true; i.strokeColor = .white; i.strokeWidth = 0.55
        },
        OverlayPreset(id: "variety", title: "综艺") { i in
            i.color = OverlayColor(1.0, 0.84, 0.04); i.strokeOn = true; i.strokeColor = .black; i.strokeWidth = 0.6
            i.shadowOn = true; i.shadowColor = .black; i.shadowBlur = 0; i.shadowDistance = 0.22; i.shadowAngle = 45; i.shadowOpacity = 1
        },
        OverlayPreset(id: "softShadow", title: "柔影") { i in
            i.color = .white; i.shadowOn = true; i.shadowColor = .black; i.shadowBlur = 0.6; i.shadowDistance = 0.12
            i.shadowAngle = 90; i.shadowOpacity = 0.7
        },
        OverlayPreset(id: "hardShadow", title: "立体") { i in
            i.color = .white; i.shadowOn = true; i.shadowColor = OverlayColor(1.0, 0.27, 0.27); i.shadowBlur = 0
            i.shadowDistance = 0.2; i.shadowAngle = 40; i.shadowOpacity = 1
        },
        OverlayPreset(id: "neonPink", title: "霓虹粉") { i in
            i.color = .white; i.glowOn = true; i.glowColor = OverlayColor(1.0, 0.3, 0.65); i.glowSize = 0.55; i.glowStrength = 0.8
        },
        OverlayPreset(id: "neonBlue", title: "霓虹蓝") { i in
            i.color = .white; i.glowOn = true; i.glowColor = OverlayColor(0.2, 0.7, 1.0); i.glowSize = 0.55; i.glowStrength = 0.8
        },
        OverlayPreset(id: "cute", title: "可爱") { i in
            i.color = OverlayColor(1.0, 0.45, 0.7); i.strokeOn = true; i.strokeColor = .white; i.strokeWidth = 0.7
            i.shadowOn = true; i.shadowColor = OverlayColor(1.0, 0.45, 0.7); i.shadowBlur = 0.5; i.shadowDistance = 0.1
            i.shadowAngle = 90; i.shadowOpacity = 0.5
        },
        OverlayPreset(id: "darkBox", title: "黑底") { i in
            i.color = .white; i.boxOn = true; i.boxColor = .black; i.boxOpacity = 0.6; i.boxShape = .rounded
        },
        OverlayPreset(id: "whitePill", title: "白胶囊") { i in
            i.color = .black; i.boxOn = true; i.boxColor = .white; i.boxShape = .capsule
        },
        OverlayPreset(id: "marker", title: "荧光笔") { i in
            i.color = .black; i.boxOn = true; i.boxColor = OverlayColor(1.0, 0.84, 0.04); i.boxShape = .marker
        },
        OverlayPreset(id: "bubble", title: "气泡") { i in
            i.color = .black; i.boxOn = true; i.boxColor = .white; i.boxShape = .bubble
            i.shadowOn = false
        },
        OverlayPreset(id: "redTag", title: "红标签") { i in
            i.color = .white; i.boxOn = true; i.boxColor = OverlayColor(0.9, 0.16, 0.2); i.boxShape = .tag
        },
        OverlayPreset(id: "ribbon", title: "丝带") { i in
            i.color = .white; i.boxOn = true; i.boxColor = OverlayColor(0.12, 0.2, 0.5); i.boxShape = .ribbon
        },
    ]
}
