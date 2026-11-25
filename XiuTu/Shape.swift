import CoreGraphics
import CoreImage
import Foundation
import simd

// 美体塑形的参数和变形引擎。
//
// 坐标约定：所有点都用"单位坐标"——以原图长边为 1、原点在左上角、y 朝下。
// 所以同一组参数在缩小的预览图和原图上效果完全一样。
// 所有局部变形（瘦身框、缩放圈、各部位塑形）先各自算出"这个位置的画面要从哪里取"，
// 位移加在一起，最后只对图片取样一次，叠多少项都不会越来越糊。

// MARK: - 增高

/// 增高里的一条拉伸带：两条平行线之间的画面沿垂直方向拉长或压短，线外面的整体平移，画布跟着变大变小。
struct ShapeTall: Equatable {
    /// 两条线正中间的点。
    var center: CGPoint
    /// 线的方向（弧度，0 = 水平线，顺时针为正）。
    var angle: CGFloat = 0
    /// 两条线之间距离的一半。
    var halfGap: CGFloat
    /// -1...1：正数拉长，负数压短。
    var amount: CGFloat = 0
    /// 头部保护：这一段（沿垂直于线的方向）不参与拉伸。nil = 不保护。
    var head: CGRect? = nil

    /// 拉伸倍数。
    var factor: CGFloat { amount >= 0 ? 1 + 0.4 * amount : 1 + 0.3 * amount }
}

/// 一条拉伸带在某个画面尺寸下算好的几何：正反两个方向的坐标换算。
struct ShapeTallMap {
    let c: SIMD2<Float>
    /// 垂直于线的方向，主分量为正。
    let n: SIMD2<Float>
    /// 沿 n 方向的分段：(起点, 终点, 倍数)。
    let segments: [(Float, Float, Float)]
    let delta: Float
    /// 输出画面相对输入画面的原点偏移，以及输出画面的大小。
    let origin: SIMD2<Float>
    let outSize: SIMD2<Float>

    init(_ band: ShapeTall, size: SIMD2<Float>) {
        let center = SIMD2(Float(band.center.x), Float(band.center.y))
        c = center
        var normal = SIMD2(-sinf(Float(band.angle)), cosf(Float(band.angle)))
        let vertical = abs(normal.y) >= abs(normal.x)
        if (vertical && normal.y < 0) || (!vertical && normal.x < 0) { normal = -normal }
        n = normal
        let g = max(Float(band.halfGap), 0.002)
        let k = Float(band.factor)
        var segs: [(Float, Float, Float)] = []
        if let head = band.head, k != 1 {
            // 头部的四个角投影到 n 上，得到要跳过的一段。
            let corners = [CGPoint(x: head.minX, y: head.minY), CGPoint(x: head.maxX, y: head.minY),
                           CGPoint(x: head.minX, y: head.maxY), CGPoint(x: head.maxX, y: head.maxY)]
            let ts = corners.map { simd_dot(SIMD2(Float($0.x), Float($0.y)) - center, normal) }
            let h0 = max(ts.min() ?? 0, -g), h1 = min(ts.max() ?? 0, g)
            if h1 > h0 {
                if h0 > -g { segs.append((-g, h0, k)) }
                segs.append((h0, h1, 1))
                if h1 < g { segs.append((h1, g, k)) }
            } else {
                segs.append((-g, g, k))
            }
        } else {
            segs.append((-g, g, k))
        }
        segments = segs
        delta = segs.reduce(0) { $0 + ($1.1 - $1.0) * ($1.2 - 1) }
        // 沿主方向画布变长（或变短）；另一个方向只保留线两边都有画面的那一段，免得边上拉出一条条的残影。
        let shift = normal * delta
        if vertical {
            origin = SIMD2(max(0, shift.x), 0)
            outSize = SIMD2(max(size.x - abs(shift.x), 0.01), max(size.y + shift.y, 0.01))
        } else {
            origin = SIMD2(0, max(0, shift.y))
            outSize = SIMD2(max(size.x + shift.x, 0.01), max(size.y - abs(shift.y), 0.01))
        }
    }

    /// 沿 n 方向：原来的位置 → 拉伸之后的位置。
    private func forward(_ t: Float) -> Float {
        var extra: Float = 0
        for s in segments { extra += min(max(t - s.0, 0), s.1 - s.0) * (s.2 - 1) }
        return t + extra
    }

    /// 沿 n 方向：拉伸之后的位置 → 原来的位置。
    private func inverse(_ value: Float) -> Float {
        guard let first = segments.first, value > first.0 else { return value }
        var start = first.0
        for s in segments {
            let end = start + (s.1 - s.0) * s.2
            if value <= end { return s.0 + (value - start) / max(s.2, 0.05) }
            start = end
        }
        return value - delta
    }

    /// 输出画面上的一点 → 输入画面上对应的点。
    func source(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let q = source(p.x, p.y)
        return SIMD2(q.0, q.1)
    }

    /// 同上，逐点算位移场时用的标量版本（没开优化的调试版里 SIMD 运算很慢）。
    func source(_ x: Float, _ y: Float) -> (Float, Float) {
        let qx = x + origin.x, qy = y + origin.y
        let t = (qx - c.x) * n.x + (qy - c.y) * n.y
        let d = inverse(t) - t
        return (qx + n.x * d, qy + n.y * d)
    }

    /// 输入画面上的一点 → 输出画面上的位置。
    func output(_ q: SIMD2<Float>) -> SIMD2<Float> {
        let t = simd_dot(q - c, n)
        return q + n * (forward(t) - t) - origin
    }
}

// MARK: - 瘦身框 / 缩放圈

/// 瘦身：一个可以移动、旋转、缩放的框。框里的画面朝框的竖直中线收（或往外放），
/// 中间最强，到框的上下两头减到零，形状就是框里那两条弧线。
struct ShapeBox: Equatable {
    var center: CGPoint
    var width: CGFloat
    var height: CGFloat
    /// 弧度，顺时针为正。
    var angle: CGFloat = 0
    /// -1...1：正数变瘦，负数变宽。
    var amount: CGFloat = 0
}

/// 缩放：一个圆圈，圈里的画面放大或缩小，到圈边平滑过渡到不变。
struct ShapeSpot: Equatable {
    var center: CGPoint
    var radius: CGFloat
    /// -1...1：正数放大，负数缩小。
    var amount: CGFloat = 0
}

// MARK: - 塑形

enum ShapeSide: String, CaseIterable, Identifiable {
    case both, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "整体"
        case .left: return "左"
        case .right: return "右"
        }
    }
}

/// 一项塑形的数值：整体，加上只给画面左边 / 右边那一侧的额外量。
struct ShapeAmount: Equatable {
    var both: CGFloat = 0
    var left: CGFloat = 0
    var right: CGFloat = 0

    var isZero: Bool { both == 0 && left == 0 && right == 0 }
    var leftTotal: CGFloat { min(max(both + left, -1), 1) }
    var rightTotal: CGFloat { min(max(both + right, -1), 1) }

    subscript(side: ShapeSide) -> CGFloat {
        get {
            switch side {
            case .both: return both
            case .left: return left
            case .right: return right
            }
        }
        set {
            switch side {
            case .both: both = newValue
            case .left: left = newValue
            case .right: right = newValue
            }
        }
    }
}

enum ShapeGroup: String, CaseIterable, Identifiable {
    case slim, arm, leg, posture, neck, head, chest, hip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slim: return "瘦身"
        case .arm: return "手臂"
        case .leg: return "腿部"
        case .posture: return "体态"
        case .neck: return "肩颈"
        case .head: return "小头"
        case .chest: return "胸部"
        case .hip: return "臀胯"
        }
    }

    var items: [ShapeItem] { ShapeItem.allCases.filter { $0.group == self } }
}

/// 塑形里的各项。本机能调的项都另有一个 AI 版（认不出人体时也能用）；还有几项本机做不好，只有 AI 版。
enum ShapeItem: String, CaseIterable, Identifiable {
    case waist, slimAll, aiWaist, aiSlimAll, aiBelly, aiTummy
    case arm, upperArm, foreArm, aiArm, aiUpperArm, aiForeArm
    case leg, thigh, calf, aiLeg, aiThigh, aiCalf, aiStraightLeg
    case shoulderLevel, aiShoulderLevel, aiStraightBack, aiNeckForward
    case swanNeck, shoulderWidth, squareShoulder, neckWidth, neckLength, aiSwanNeck, aiWideShoulder, aiNarrowShoulder, aiSquareShoulder, aiThinNeck, aiLongNeck, aiTrapezius
    case smallHead, aiSmallHead
    case chest, aiChest, aiChestNatural, aiChestLift
    case hips, waistHip, aiHips, aiWaistHip, aiFullHip, aiLiftHip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .waist: return "瘦腰"
        case .slimAll: return "瘦全身"
        case .aiBelly: return "收腹"
        case .aiTummy: return "瘦肚子"
        case .arm: return "瘦手臂"
        case .upperArm: return "瘦大臂"
        case .foreArm: return "瘦小臂"
        case .leg: return "瘦腿"
        case .thigh: return "瘦大腿"
        case .calf: return "瘦小腿"
        case .aiStraightLeg: return "直腿"
        case .aiStraightBack: return "直背"
        case .aiNeckForward: return "脖子前倾"
        case .shoulderLevel: return "高低肩"
        case .swanNeck: return "天鹅颈"
        case .shoulderWidth: return "肩宽"
        case .squareShoulder: return "直角肩"
        case .aiTrapezius: return "瘦斜方肌"
        case .neckWidth: return "脖子粗细"
        case .neckLength: return "脖子长短"
        case .smallHead: return "小头"
        case .chest: return "丰胸"
        case .aiChestNatural: return "自然胸型"
        case .aiChestLift: return "胸位提升"
        case .hips: return "美胯"
        case .waistHip: return "腰臀比"
        case .aiFullHip: return "丰臀"
        case .aiLiftHip: return "提臀"
        case .aiWaist: return "瘦腰"
        case .aiSlimAll: return "瘦全身"
        case .aiArm: return "瘦手臂"
        case .aiUpperArm: return "瘦大臂"
        case .aiForeArm: return "瘦小臂"
        case .aiLeg: return "瘦腿"
        case .aiThigh: return "瘦大腿"
        case .aiCalf: return "瘦小腿"
        case .aiShoulderLevel: return "高低肩"
        case .aiSwanNeck: return "天鹅颈"
        case .aiWideShoulder: return "宽肩"
        case .aiNarrowShoulder: return "窄肩"
        case .aiSquareShoulder: return "直角肩"
        case .aiThinNeck: return "细脖子"
        case .aiLongNeck: return "长脖子"
        case .aiSmallHead: return "小头"
        case .aiChest: return "丰胸"
        case .aiHips: return "美胯"
        case .aiWaistHip: return "腰臀比"
        }
    }

    var symbol: String {
        switch self {
        case .waist, .waistHip, .aiWaist, .aiWaistHip: return "arrow.right.and.line.vertical.and.arrow.left"
        case .slimAll, .aiSlimAll: return "figure.stand"
        case .aiBelly, .aiTummy: return "circle.bottomhalf.filled"
        case .arm, .upperArm, .foreArm, .aiArm, .aiUpperArm, .aiForeArm: return "figure.arms.open"
        case .leg, .thigh, .calf, .aiStraightLeg, .aiLeg, .aiThigh, .aiCalf: return "figure.walk"
        case .aiStraightBack, .aiNeckForward: return "figure.stand.line.dotted.figure.stand"
        case .shoulderLevel, .aiShoulderLevel: return "level"
        case .swanNeck, .neckWidth, .neckLength, .aiSwanNeck, .aiThinNeck, .aiLongNeck: return "person.bust"
        case .shoulderWidth, .aiWideShoulder, .aiNarrowShoulder: return "arrow.left.and.right"
        case .squareShoulder, .aiTrapezius, .aiSquareShoulder: return "rectangle.tophalf.inset.filled"
        case .smallHead, .aiSmallHead: return "person.crop.circle"
        case .chest, .aiChestNatural, .aiChestLift, .aiChest: return "heart"
        case .hips, .aiFullHip, .aiLiftHip, .aiHips: return "oval.portrait"
        }
    }

    var group: ShapeGroup {
        switch self {
        case .waist, .slimAll, .aiWaist, .aiSlimAll, .aiBelly, .aiTummy: return .slim
        case .arm, .upperArm, .foreArm, .aiArm, .aiUpperArm, .aiForeArm: return .arm
        case .leg, .thigh, .calf, .aiLeg, .aiThigh, .aiCalf, .aiStraightLeg: return .leg
        case .shoulderLevel, .aiShoulderLevel, .aiStraightBack, .aiNeckForward: return .posture
        case .swanNeck, .shoulderWidth, .squareShoulder, .neckWidth, .neckLength, .aiSwanNeck, .aiWideShoulder, .aiNarrowShoulder, .aiSquareShoulder, .aiThinNeck, .aiLongNeck, .aiTrapezius: return .neck
        case .smallHead, .aiSmallHead: return .head
        case .chest, .aiChest, .aiChestNatural, .aiChestLift: return .chest
        case .hips, .waistHip, .aiHips, .aiWaistHip, .aiFullHip, .aiLiftHip: return .hip
        }
    }

    var isAI: Bool { rawValue.hasPrefix("ai") }

    /// 能不能分别调画面左边和右边。
    var hasSides: Bool {
        switch self {
        case .waist, .arm, .upperArm, .foreArm, .leg, .thigh, .calf,
             .shoulderWidth, .squareShoulder, .chest, .hips:
            return true
        default:
            return false
        }
    }

    /// 需要哪些部位被识别出来才能做。
    func available(in body: ShapeBody) -> Bool {
        switch self {
        case .arm: return body.hasUpperArm(.left) || body.hasUpperArm(.right) || body.hasForeArm(.left) || body.hasForeArm(.right)
        case .upperArm: return body.hasUpperArm(.left) || body.hasUpperArm(.right)
        case .foreArm: return body.hasForeArm(.left) || body.hasForeArm(.right)
        case .leg: return body.hasThigh(.left) || body.hasThigh(.right) || body.hasCalf(.left) || body.hasCalf(.right)
        case .thigh: return body.hasThigh(.left) || body.hasThigh(.right)
        case .calf: return body.hasCalf(.left) || body.hasCalf(.right)
        case .swanNeck, .neckWidth, .neckLength, .smallHead: return body.head != nil
        default: return true
        }
    }
}

/// 一个人的身体关键点（单位坐标）。"左 / 右"按画面上的左右算，不是这个人自己的左右。
struct ShapeBody: Equatable {
    struct Limb: Equatable {
        var shoulder: CGPoint?
        var elbow: CGPoint?
        var wrist: CGPoint?
        var hip: CGPoint?
        var knee: CGPoint?
        var ankle: CGPoint?
    }

    var left = Limb()
    var right = Limb()
    /// 头的中心。
    var head: CGPoint?
    /// 头的大致半径。
    var headRadius: CGFloat = 0

    /// 至少要有两个肩膀才能建立身体的坐标系。
    var isUsable: Bool { left.shoulder != nil && right.shoulder != nil }

    private func limb(_ side: ShapeSide) -> Limb { side == .left ? left : right }

    func hasUpperArm(_ side: ShapeSide) -> Bool { limb(side).shoulder != nil && limb(side).elbow != nil }
    func hasForeArm(_ side: ShapeSide) -> Bool { limb(side).elbow != nil && limb(side).wrist != nil }
    func hasThigh(_ side: ShapeSide) -> Bool { limb(side).hip != nil && limb(side).knee != nil }
    func hasCalf(_ side: ShapeSide) -> Bool { limb(side).knee != nil && limb(side).ankle != nil }

    /// 所有关键点的外接框。
    var bounds: CGRect {
        let all = [left.shoulder, left.elbow, left.wrist, left.hip, left.knee, left.ankle,
                   right.shoulder, right.elbow, right.wrist, right.hip, right.knee, right.ankle, head].compactMap { $0 }
        guard let first = all.first else { return .zero }
        var box = CGRect(origin: first, size: .zero)
        for p in all.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        return box
    }
}

/// 一键美体里本机能做的预设：就是一组塑形数值。
struct ShapePreset: Identifiable {
    let title: String
    let values: [ShapeItem: CGFloat]
    var id: String { title }

    static let all: [ShapePreset] = [
        ShapePreset(title: "自然", values: [.waist: 0.4, .arm: 0.3, .leg: 0.3, .smallHead: 0.15, .swanNeck: 0.25]),
        ShapePreset(title: "超模", values: [.waist: 0.65, .arm: 0.5, .leg: 0.55, .smallHead: 0.3, .swanNeck: 0.45,
                                            .waistHip: 0.3, .squareShoulder: 0.3]),
    ]
}

// MARK: - 变形还原

/// 变形还原的一笔：涂过的地方变形减弱，回到原样。
struct ShapeRestoreStroke: Equatable {
    var points: [CGPoint]
    /// 笔刷半径。
    var radius: CGFloat
}

// MARK: - 参数

/// 美体塑形：按人体关键点或用户摆的辅助线对身体做变形，作为编辑历史里的一步。
/// 一步里要么是增高（会改画布大小），要么是不改画布大小的那几种（瘦身框、缩放圈、塑形）。
struct ShapeParams {
    /// 增高：按顺序一条一条做，后一条的位置是在前一条做完之后的画面上量的。
    var talls: [ShapeTall] = []
    var boxes: [ShapeBox] = []
    var spots: [ShapeSpot] = []
    var body: ShapeBody?
    var values: [ShapeItem: ShapeAmount] = [:]
    var restore: [ShapeRestoreStroke] = []
    /// 背景保护用的人像蒙版（白 = 人）；nil = 不保护。
    var lockMask: CGImage?
    /// AI 补好的"没有人的背景"（整张图大小）；有它时，人让出来的地方直接用它，不再拉旁边的背景。
    var aiPlate: CGImage?

    var hasTall: Bool { talls.contains { $0.amount != 0 } }

    var hasLocal: Bool {
        boxes.contains { $0.amount != 0 } || spots.contains { $0.amount != 0 }
            || (body != nil && values.contains { !$0.value.isZero && !$0.key.isAI })
    }

    var isIdentity: Bool { !hasTall && !hasLocal }

    /// plate：提前算好的"没有人的背景"（实时预览用），不传就现算。
    func apply(to image: CIImage, plate: CGImage? = nil) -> CIImage {
        guard !isIdentity else { return image }
        let origin = image.extent.origin
        let source = origin == .zero ? image
            : image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        guard let field = ShapeEngine.field(for: self, imageSize: source.extent.size) else { return image }
        return ShapeEngine.warp(source, field: field, lock: hasTall ? nil : lockMask, plate: aiPlate ?? plate)
    }
}

/// 位移场的一份快照。
struct ShapeField {
    let width: Int
    let height: Int
    /// RGBA 浮点：R、G 以 0.5 为零点，存"取样点 - 当前位置"，单位是原图长边；G 是取反后的 y。
    let data: Data
    /// 输出画面的大小（单位坐标）。
    let outSize: CGSize
    let maxOffset: CGFloat
}

// MARK: - 引擎

enum ShapeEngine {
    static let gridLongSide = 224

    // MARK: 局部变形的基本动作

    private struct Prim {
        enum Kind { case radial, squeeze, shift }
        let kind: Kind
        /// radial：作用范围的圆心；squeeze：轴线起点；shift：圆心。
        let ax: Float, ay: Float
        /// radial：缩放的锚点；shift：画面移动的向量。
        let bx: Float, by: Float
        /// 半径，或者轴线两侧的作用宽度。
        let r: Float
        let k: Float
        /// squeeze 沿轴线的强弱：width == 0 用"中间平、两头缓"的形状；否则是以 peak 为中心的一个鼓包。
        let peak: Float
        let width: Float
        /// squeeze 只作用在轴线的哪一侧：0 两侧，±1 一侧（按法线方向）。
        let side: Float
        /// squeeze 的轴线方向和长度。
        let ux: Float, uy: Float, length: Float
        /// 外接圆：圆外面肯定没有位移，先用它快速跳过。
        let cx: Float, cy: Float, reach2: Float

        init(kind: Kind, a: SIMD2<Float>, b: SIMD2<Float>, r: Float, k: Float,
             peak: Float = 0.5, width: Float = 0, side: Float = 0) {
            self.kind = kind
            ax = a.x; ay = a.y
            bx = b.x; by = b.y
            self.r = max(r, 0.0001)
            self.k = k
            self.peak = peak
            self.width = width
            self.side = side
            if kind == .squeeze {
                let axis = b - a
                let len = max(simd_length(axis), 0.0001)
                length = len
                ux = axis.x / len; uy = axis.y / len
                let lo: Float = width > 0 ? peak - width * 2.2 : -0.15
                let hi: Float = width > 0 ? peak + width * 2.2 : 1.15
                let mid = (lo + hi) / 2 * len
                cx = a.x + ux * mid; cy = a.y + uy * mid
                let half = (hi - lo) / 2 * len
                reach2 = half * half + self.r * self.r
            } else {
                length = 1; ux = 1; uy = 0
                cx = a.x; cy = a.y
                reach2 = self.r * self.r
            }
        }

        /// 把这一个动作在 (x, y) 处的位移加到 dx、dy 上。
        @inline(__always)
        func add(_ x: Float, _ y: Float, _ dx: inout Float, _ dy: inout Float) {
            let ex = x - cx, ey = y - cy
            if ex * ex + ey * ey >= reach2 { return }
            switch kind {
            case .radial:
                let d2 = (ex * ex + ey * ey) / (r * r)
                let f = (1 - d2) * (1 - d2) * k
                dx += (x - bx) * f
                dy += (y - by) * f
            case .shift:
                let d2 = (ex * ex + ey * ey) / (r * r)
                let f = (1 - d2) * (1 - d2) * (1 - d2)
                dx -= bx * f
                dy -= by * f
            case .squeeze:
                let vx = x - ax, vy = y - ay
                // 法线方向是 (-uy, ux)。
                let q = vy * ux - vx * uy
                let xi = abs(q) / r
                if xi >= 1 { return }
                let t = (vx * ux + vy * uy) / length
                var w: Float
                if width > 0 {
                    let u = (t - peak) / (width * 2.2)
                    if abs(u) >= 1 { return }
                    w = (1 - u * u) * (1 - u * u)
                } else {
                    if t <= -0.15 || t >= 1.15 { return }
                    w = ShapeEngine.smooth((t + 0.15) / 0.35) * ShapeEngine.smooth((1.15 - t) / 0.35)
                }
                if side != 0 { w *= ShapeEngine.smooth(side * q / (0.2 * r)) }
                let m = q * k * w * (1 - xi * xi) * (1 - xi * xi)
                dx -= uy * m
                dy += ux * m
            }
        }
    }

    @inline(__always)
    private static func smooth(_ x: Float) -> Float {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func vec(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }

    /// 瘦身框和缩放圈对应的动作。
    private static func manualPrims(_ params: ShapeParams) -> [Prim] {
        var prims: [Prim] = []
        for box in params.boxes where box.amount != 0 {
            let c = vec(box.center)
            let down = SIMD2(-sinf(Float(box.angle)), cosf(Float(box.angle)))
            let half = Float(box.height) / 2
            // 弧线在框的中段离中线大约 0.33 个框宽；作用范围取 0.75 个框宽，位移最大的地方正好落在弧线上。
            prims.append(Prim(kind: .squeeze, a: c - down * half, b: c + down * half,
                              r: Float(box.width) * 0.75, k: Float(box.amount) * 0.34, peak: 0.5, width: 0.227))
        }
        for spot in params.spots where spot.amount != 0 {
            let c = vec(spot.center)
            prims.append(Prim(kind: .radial, a: c, b: c, r: Float(spot.radius), k: -Float(spot.amount) * 0.5))
        }
        return prims
    }

    /// 塑形各项对应的动作：全部从肩、胯、手肘这些关键点推出来。
    private static func bodyPrims(_ params: ShapeParams) -> [Prim] {
        guard let body = params.body, let ls = body.left.shoulder, let rs = body.right.shoulder else { return [] }
        func amount(_ item: ShapeItem) -> ShapeAmount { params.values[item] ?? ShapeAmount() }
        var prims: [Prim] = []

        let sl = vec(ls), sr = vec(rs)
        let sw = max(simd_length(sr - sl), 0.01)
        let ms = (sl + sr) / 2
        let across = (sr - sl) / sw
        // 身体的"下"：垂直于肩线、朝画面下方。
        var down = SIMD2(-across.y, across.x)
        if down.y < 0 { down = -down }
        var mh = ms + down * (sw * 1.5)
        var hw = sw * 0.85
        if let lh = body.left.hip, let rh = body.right.hip {
            mh = (vec(lh) + vec(rh)) / 2
            hw = max(simd_length(vec(rh) - vec(lh)), sw * 0.5)
        } else if let one = body.left.hip ?? body.right.hip {
            // 只看到一边的胯：沿肩线方向挪到身体中线上。
            let h = vec(one)
            mh = h - across * simd_dot(h - ms, across)
        }
        let torso = max(simd_length(mh - ms), sw * 0.6)
        let spine = (mh - ms) / torso
        // 沿脊柱这条轴线的法线朝哪边是画面左边。
        let spineNormal = SIMD2(-spine.y, spine.x)
        let leftSign: Float = simd_dot(sl - ms, spineNormal) >= 0 ? 1 : -1

        /// 沿脊柱的收放：peak 是从肩（0）到胯（1）的位置。左右数值一样就两侧一起，不一样就各做各的。
        func torsoSqueeze(_ l: CGFloat, _ r: CGFloat, peak: Float, width: Float, reach: Float, strength: Float) {
            guard l != 0 || r != 0 else { return }
            if l == r {
                prims.append(Prim(kind: .squeeze, a: ms, b: mh, r: reach, k: Float(l) * strength, peak: peak, width: width))
            } else {
                if l != 0 {
                    prims.append(Prim(kind: .squeeze, a: ms, b: mh, r: reach, k: Float(l) * strength,
                                      peak: peak, width: width, side: leftSign))
                }
                if r != 0 {
                    prims.append(Prim(kind: .squeeze, a: ms, b: mh, r: reach, k: Float(r) * strength,
                                      peak: peak, width: width, side: -leftSign))
                }
            }
        }

        // 瘦腰、美胯、腰臀比
        let waist = amount(.waist), hips = amount(.hips), ratio = Float(amount(.waistHip).both)
        let reach = max(sw, hw) * 0.95
        torsoSqueeze(waist.leftTotal, waist.rightTotal, peak: 0.62, width: 0.2, reach: reach, strength: 0.24)
        torsoSqueeze(hips.leftTotal, hips.rightTotal, peak: 1.02, width: 0.16, reach: max(sw, hw) * 1.05, strength: -0.16)
        if ratio != 0 {
            prims.append(Prim(kind: .squeeze, a: ms, b: mh, r: reach, k: ratio * 0.16, peak: 0.62, width: 0.2))
            prims.append(Prim(kind: .squeeze, a: ms, b: mh, r: max(sw, hw) * 1.05, k: -ratio * 0.12, peak: 1.05, width: 0.16))
        }

        // 瘦全身：沿整个人的长轴往中间收。
        let all = Float(amount(.slimAll).both)
        if all != 0 {
            let box = body.bounds
            let top = body.head.map { vec($0) - spine * Float(body.headRadius) } ?? ms - spine * (sw * 0.9)
            var bottom = mh + spine * (sw * 0.5)
            let lows = [body.left.ankle, body.right.ankle, body.left.knee, body.right.knee].compactMap { $0 }.map(vec)
            if let lowest = lows.max(by: { simd_dot($0 - ms, spine) < simd_dot($1 - ms, spine) }) {
                bottom = ms + spine * max(simd_dot(lowest - ms, spine), torso)
            }
            let half = max(Float(max(box.width, box.height)) * 0.2, sw * 1.2)
            prims.append(Prim(kind: .squeeze, a: top, b: bottom, r: half, k: all * 0.13))
        }

        // 手臂、腿：沿着每一段肢体往它的中轴线收。
        func limb(_ from: CGPoint?, _ to: CGPoint?, _ value: CGFloat, reach: Float, cap: Float, strength: Float) {
            guard value != 0, let from, let to else { return }
            let a = vec(from), b = vec(to)
            let length = simd_length(b - a)
            guard length > sw * 0.15 else { return }
            prims.append(Prim(kind: .squeeze, a: a, b: b, r: min(max(length * reach, sw * 0.16), cap),
                              k: Float(value) * strength))
        }
        let arm = amount(.arm), upper = amount(.upperArm), fore = amount(.foreArm)
        limb(body.left.shoulder, body.left.elbow, arm.leftTotal + upper.leftTotal, reach: 0.42, cap: sw * 0.5, strength: 0.32)
        limb(body.right.shoulder, body.right.elbow, arm.rightTotal + upper.rightTotal, reach: 0.42, cap: sw * 0.5, strength: 0.32)
        limb(body.left.elbow, body.left.wrist, arm.leftTotal + fore.leftTotal, reach: 0.36, cap: sw * 0.42, strength: 0.28)
        limb(body.right.elbow, body.right.wrist, arm.rightTotal + fore.rightTotal, reach: 0.36, cap: sw * 0.42, strength: 0.28)
        let leg = amount(.leg), thigh = amount(.thigh), calf = amount(.calf)
        limb(body.left.hip, body.left.knee, leg.leftTotal + thigh.leftTotal, reach: 0.38, cap: hw * 0.75, strength: 0.24)
        limb(body.right.hip, body.right.knee, leg.rightTotal + thigh.rightTotal, reach: 0.38, cap: hw * 0.75, strength: 0.24)
        limb(body.left.knee, body.left.ankle, leg.leftTotal + calf.leftTotal, reach: 0.3, cap: hw * 0.6, strength: 0.22)
        limb(body.right.knee, body.right.ankle, leg.rightTotal + calf.rightTotal, reach: 0.3, cap: hw * 0.6, strength: 0.22)

        // 肩
        let up = -spine
        let level = Float(amount(.shoulderLevel).both)
        if level != 0 {
            prims.append(Prim(kind: .shift, a: sl, b: up * (level * sw * 0.07), r: sw * 0.6, k: 0))
            prims.append(Prim(kind: .shift, a: sr, b: up * (-level * sw * 0.07), r: sw * 0.6, k: 0))
        }
        let wide = amount(.shoulderWidth)
        if wide.leftTotal != 0 {
            prims.append(Prim(kind: .shift, a: sl, b: -across * (Float(wide.leftTotal) * sw * 0.09), r: sw * 0.5, k: 0))
        }
        if wide.rightTotal != 0 {
            prims.append(Prim(kind: .shift, a: sr, b: across * (Float(wide.rightTotal) * sw * 0.09), r: sw * 0.5, k: 0))
        }
        let square = amount(.squareShoulder)
        if square.leftTotal != 0 {
            prims.append(Prim(kind: .shift, a: sl - across * (sw * 0.06), b: up * (Float(square.leftTotal) * sw * 0.09),
                              r: sw * 0.4, k: 0))
        }
        if square.rightTotal != 0 {
            prims.append(Prim(kind: .shift, a: sr + across * (sw * 0.06), b: up * (Float(square.rightTotal) * sw * 0.09),
                              r: sw * 0.4, k: 0))
        }

        // 脖子和头
        if let headPoint = body.head {
            let hc = vec(headPoint)
            let hr = max(Float(body.headRadius), sw * 0.3)
            let neckBase = ms + (hc - ms) * 0.25
            let neckTop = ms + (hc - ms) * 0.6
            let neckUp = simd_normalize(hc - ms)
            let swan = Float(amount(.swanNeck).both)
            if swan != 0 {
                // 肩线靠脖子的两侧往下沉一点，脖子收细一点，头再往上提一点。
                prims.append(Prim(kind: .shift, a: sl + (ms - sl) * 0.35, b: spine * (swan * sw * 0.07), r: sw * 0.45, k: 0))
                prims.append(Prim(kind: .shift, a: sr + (ms - sr) * 0.35, b: spine * (swan * sw * 0.07), r: sw * 0.45, k: 0))
                prims.append(Prim(kind: .squeeze, a: ms, b: neckTop, r: sw * 0.32, k: swan * 0.14))
                prims.append(Prim(kind: .shift, a: hc, b: neckUp * (swan * sw * 0.035), r: hr * 1.9, k: 0))
            }
            let thin = Float(amount(.neckWidth).both)
            if thin != 0 {
                prims.append(Prim(kind: .squeeze, a: ms, b: neckTop, r: sw * 0.34, k: thin * 0.2))
            }
            let long = Float(amount(.neckLength).both)
            if long != 0 {
                prims.append(Prim(kind: .shift, a: hc, b: neckUp * (long * sw * 0.07), r: hr * 2, k: 0))
            }
            let small = Float(amount(.smallHead).both)
            if small != 0 {
                // 以脖子根为锚点缩放，头变小了也还是接在脖子上。
                prims.append(Prim(kind: .radial, a: hc, b: neckBase, r: hr * 1.75, k: small * 0.22))
            }
        }

        // 胸
        let chest = amount(.chest)
        let chestCenter = ms + spine * (torso * 0.34)
        if chest.leftTotal != 0 {
            let c = chestCenter - across * (sw * 0.24)
            prims.append(Prim(kind: .radial, a: c, b: c, r: sw * 0.3, k: -Float(chest.leftTotal) * 0.34))
        }
        if chest.rightTotal != 0 {
            let c = chestCenter + across * (sw * 0.24)
            prims.append(Prim(kind: .radial, a: c, b: c, r: sw * 0.3, k: -Float(chest.rightTotal) * 0.34))
        }
        return prims
    }

    // MARK: 位移场

    /// 增高的每一条带子在各自画面尺寸下的几何，以及最后的画面大小。
    static func tallMaps(_ talls: [ShapeTall], size: CGSize) -> (maps: [ShapeTallMap], outSize: CGSize) {
        var current = SIMD2(Float(size.width), Float(size.height))
        var maps: [ShapeTallMap] = []
        for band in talls where band.amount != 0 {
            let map = ShapeTallMap(band, size: current)
            maps.append(map)
            current = map.outSize
        }
        return (maps, CGSize(width: CGFloat(current.x), height: CGFloat(current.y)))
    }

    /// 变形还原用：每一笔拆成一段段线段，提前算好。
    private struct RestoreSegment {
        let ax: Float, ay: Float, dx: Float, dy: Float, inverse: Float, r: Float
    }

    private static func restoreSegments(_ strokes: [ShapeRestoreStroke]) -> [RestoreSegment] {
        var out: [RestoreSegment] = []
        for stroke in strokes where !stroke.points.isEmpty {
            let r = max(Float(stroke.radius), 0.002)
            let pts = stroke.points.map(vec)
            if pts.count == 1 {
                out.append(RestoreSegment(ax: pts[0].x, ay: pts[0].y, dx: 0, dy: 0, inverse: 0, r: r))
            } else {
                for i in 1..<pts.count {
                    let d = pts[i] - pts[i - 1]
                    let l2 = simd_length_squared(d)
                    out.append(RestoreSegment(ax: pts[i - 1].x, ay: pts[i - 1].y, dx: d.x, dy: d.y,
                                              inverse: l2 > 1e-9 ? 1 / l2 : 0, r: r))
                }
            }
        }
        return out
    }

    /// 变形还原：某一点离涂抹过的地方有多近（0...1）。笔刷中间一半完全还原，往外平滑过渡。
    @inline(__always)
    private static func restoreWeight(_ segments: [RestoreSegment], _ x: Float, _ y: Float) -> Float {
        var best: Float = 0
        for s in segments {
            let vx = x - s.ax, vy = y - s.ay
            let t = min(max((vx * s.dx + vy * s.dy) * s.inverse, 0), 1)
            let ex = vx - s.dx * t, ey = vy - s.dy * t
            let d2 = ex * ex + ey * ey
            if d2 >= s.r * s.r { continue }
            let w = 1 - smooth((d2.squareRoot() - s.r * 0.5) / (s.r * 0.5))
            if w > best {
                best = w
                if best >= 1 { return 1 }
            }
        }
        return best
    }

    /// 把所有变形合成一张位移场。imageSize 只用来算宽高比，和分辨率无关。
    static func field(for params: ShapeParams, imageSize: CGSize) -> ShapeField? {
        let long = max(imageSize.width, imageSize.height)
        guard long > 0 else { return nil }
        let unit = CGSize(width: imageSize.width / long, height: imageSize.height / long)
        let tall = tallMaps(params.talls, size: unit)
        let prims = tall.maps.isEmpty ? manualPrims(params) + bodyPrims(params) : []
        guard !tall.maps.isEmpty || !prims.isEmpty else { return nil }
        let strokes = tall.maps.isEmpty ? restoreSegments(params.restore) : []
        let reversed = Array(tall.maps.reversed())

        let outLong = max(tall.outSize.width, tall.outSize.height)
        let gw = max(2, Int((tall.outSize.width / outLong * CGFloat(gridLongSide)).rounded()))
        let gh = max(2, Int((tall.outSize.height / outLong * CGFloat(gridLongSide)).rounded()))
        let stepX = Float(tall.outSize.width) / Float(gw), stepY = Float(tall.outSize.height) / Float(gh)
        var values = [Float](repeating: 0, count: gw * gh * 4)
        var rowMax = [Float](repeating: 0, count: gh)
        values.withUnsafeMutableBufferPointer { buffer in
            rowMax.withUnsafeMutableBufferPointer { maxima in
                let out = buffer.baseAddress!, peaks = maxima.baseAddress!
                DispatchQueue.concurrentPerform(iterations: gh) { j in
                    var peak: Float = 0
                    let py = (Float(j) + 0.5) * stepY
                    for i in 0..<gw {
                        let px = (Float(i) + 0.5) * stepX
                        var qx = px, qy = py
                        for map in reversed { (qx, qy) = map.source(qx, qy) }
                        var dx: Float = 0, dy: Float = 0
                        for prim in prims { prim.add(qx, qy, &dx, &dy) }
                        if !strokes.isEmpty, dx != 0 || dy != 0 {
                            let keep = 1 - restoreWeight(strokes, px, py)
                            dx *= keep
                            dy *= keep
                        }
                        let offX = qx + dx - px, offY = qy + dy - py
                        let index = (j * gw + i) * 4
                        out[index] = 0.5 + offX
                        out[index + 1] = 0.5 - offY
                        out[index + 2] = 0
                        out[index + 3] = 1
                        peak = max(peak, max(abs(offX), abs(offY)))
                    }
                    peaks[j] = peak
                }
            }
        }
        return ShapeField(width: gw, height: gh, data: values.withUnsafeBufferPointer { Data(buffer: $0) },
                          outSize: tall.outSize, maxOffset: CGFloat(rowMax.max() ?? 0))
    }

    // MARK: 取样

    /// 按位移图取样。位移图 R、G 以 0.5 为零点，单位是原图长边；shift 是输出画面和原图原点之间的差。
    static let kernelSource = """
    kernel vec4 shapeWarp(sampler image, sampler map, float scale, vec2 shift) {
        vec2 d = destCoord();
        vec4 m = sample(map, samplerTransform(map, d));
        vec2 p = d + shift + (m.rg - vec2(0.5)) * scale;
        return sample(image, samplerTransform(image, p));
    }
    """

    private static let kernel = CIKernel(source: kernelSource)

    /// 和上面一样，但每一点的位移再乘上 weight（0...1）：背景保护时，背景的变形从人的边缘往外平滑地减到零。
    static let fadeKernelSource = """
    kernel vec4 shapeWarpFade(sampler image, sampler map, sampler weight, float scale, vec2 shift) {
        vec2 d = destCoord();
        vec4 m = sample(map, samplerTransform(map, d));
        float w = sample(weight, samplerTransform(weight, d)).r;
        vec2 p = d + shift + (m.rg - vec2(0.5)) * scale * w;
        return sample(image, samplerTransform(image, p));
    }
    """

    private static let fadeKernel = CIKernel(source: fadeKernelSource)

    private static func stretched(_ cg: CGImage, to extent: CGRect, data: Bool) -> CIImage {
        CIImage(cgImage: cg, options: data ? [.colorSpace: NSNull()] : [:])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(cg.width),
                                               y: extent.height / CGFloat(cg.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// "没有人的背景"：把人所在的位置用周围的背景颜色由外向里填上。人让出来的地方显示它，而不是被拉花的画面。
    static func backgroundPlate(_ image: CIImage, lock: CGImage) -> CIImage {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        // 人像蒙版往外扩一点，避免人边缘的颜色混进背景。
        let grown = stretched(lock, to: extent, data: true).clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: long * 0.006])
            .cropped(to: extent)
        let background = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent),
            kCIInputMaskImageKey: grown.applyingFilter("CIColorInvert"),
        ]).cropped(to: extent)
        // 每一层把周围的背景颜色向人的位置里晕开；离背景近的地方用细的，深处才用粗的。
        func level(_ radius: CGFloat) -> (color: CIImage, weight: CIImage) {
            let blurred = background.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: long * radius])
                .cropped(to: extent)
            let color = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            let weight = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).applyingFilter("CIColorClamp")
            return (color, weight)
        }
        var plate = level(0.2).color
        for radius in [0.07, 0.025, 0.008] as [CGFloat] {
            let l = level(radius)
            plate = l.color.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: plate,
                kCIInputMaskImageKey: l.weight,
            ])
        }
        return background.composited(over: plate).cropped(to: extent)
    }

    /// 按位移场取样。lock 不为空时"背景保护"：只有人跟着变形，背景保持原样。
    /// 人让出来的地方：有 plate（AI 补好的背景）就用它；没有就用旁边拉过来的背景，变形出了人的轮廓平滑减到零。
    /// image 的原点必须在 (0,0)。
    static func warp(_ image: CIImage, field: ShapeField, lock: CGImage? = nil, plate: CGImage? = nil) -> CIImage {
        let extent = image.extent
        let scale = max(extent.width, extent.height)
        guard let provider = CGDataProvider(data: field.data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = CGImage(width: field.width, height: field.height, bitsPerComponent: 32, bitsPerPixel: 128,
                               bytesPerRow: field.width * 16, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                                                        | CGBitmapInfo.byteOrder32Little.rawValue
                                                        | CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return image
        }
        let outExtent = CGRect(x: 0, y: 0, width: max(1, (field.outSize.width * scale).rounded()),
                               height: max(1, (field.outSize.height * scale).rounded()))
        // 网格比图片粗得多，放大后再抹平一格左右，否则直线边缘会被推成一段一段的折线。
        let cell = max(outExtent.width, outExtent.height) / CGFloat(max(field.width, field.height))
        let map = stretched(cg, to: outExtent, data: true)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: cell * 0.8])
        // 两张图的原点都在左下角，画布变高之后要把这一段差补回来。
        let shift = CIVector(x: 0, y: extent.height - outExtent.height)
        let reach = field.maxOffset * scale + cell * 2 + 2
        func displaced(_ source: CIImage) -> CIImage {
            guard let kernel = Self.kernel,
                  let out = kernel.apply(extent: outExtent, roiCallback: { index, rect in
                      index == 0 ? rect.offsetBy(dx: 0, dy: shift.y).insetBy(dx: -reach, dy: -reach) : rect
                  }, arguments: [source.clampedToExtent(), map, scale, shift]) else { return source }
            return out.cropped(to: outExtent)
        }
        let warped = displaced(image)
        guard let lock, outExtent.size == extent.size else { return warped }

        let person = stretched(lock, to: extent, data: true)
        let moved = displaced(person)
        if let plate {
            // AI 补背景：人的轮廓动过的地方换成补好的背景，其余地方一个像素都不动。
            let background = stretched(plate, to: extent, data: false)
            let changed = person
                .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: moved])
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: scale * 0.01])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale * 0.005])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0),
                ])
                .applyingFilter("CIColorClamp")
                .cropped(to: extent)
            let behind = background.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: changed,
            ]).cropped(to: extent)
            return warped.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: behind,
                kCIInputMaskImageKey: moved,
            ]).cropped(to: extent)
        }
        // 背景：人身上和人让出来的缝里照常变形（缝里是旁边拉过来的背景，纹理清楚），
        // 出了人的轮廓，变形在一小段距离里平滑地减到零。背景是连续的一整张，不会出现两张图叠在一起的重影。
        // 原来人占着的地方（包括让出来的缝）一定是 1，缝里才不会残留人的边；外面一圈平滑减到 0。
        let falloff = person.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: scale * 0.012])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale * 0.01])
        let weight = person.clampedToExtent()
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: falloff])
            .cropped(to: extent)
        var behind = image
        if let fade = Self.fadeKernel,
           let out = fade.apply(extent: outExtent, roiCallback: { index, rect in
               index == 0 ? rect.offsetBy(dx: 0, dy: shift.y).insetBy(dx: -reach, dy: -reach) : rect
           }, arguments: [image.clampedToExtent(), map, weight.clampedToExtent(), scale, shift]) {
            behind = out.cropped(to: extent)
        }
        return warped.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: moved,
        ]).cropped(to: extent)
    }
}
