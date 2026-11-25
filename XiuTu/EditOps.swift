import CoreImage
import UIKit

// MARK: - 裁剪 / 旋转

struct CropParams: Equatable, Codable {
    /// 先水平翻转，再顺时针转 quarterTurns 个 90°。
    var flip = false
    var quarterTurns = 0
    /// 拉直角度（度），正数 = 画面顺时针转。
    var straighten: CGFloat = 0
    /// 裁剪框，归一化坐标，原点在左上角，相对于旋转翻转之后的画面。
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isIdentity: Bool { self == CropParams() }

    mutating func rotateClockwise() {
        quarterTurns = (quarterTurns + 1) % 4
        rect = CGRect(x: 1 - rect.maxY, y: rect.minX, width: rect.height, height: rect.width)
    }

    mutating func flipHorizontal() {
        flip.toggle()
        quarterTurns = (4 - quarterTurns) % 4
        straighten = -straighten
        rect.origin.x = 1 - rect.maxX
    }

    mutating func flipVertical() {
        flip.toggle()
        quarterTurns = ((2 - quarterTurns) % 4 + 4) % 4
        straighten = -straighten
        rect.origin.y = 1 - rect.maxY
    }

    private func normalized(_ image: CIImage) -> CIImage {
        let e = image.extent
        let moved = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        return moved.cropped(to: CGRect(x: 0, y: 0, width: e.width.rounded(), height: e.height.rounded()))
    }

    /// 只做翻转、旋转、拉直，不裁剪。裁剪界面显示的就是这个结果。
    func oriented(_ image: CIImage) -> CIImage {
        var out = image
        if flip {
            out = normalized(out.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        let k = ((quarterTurns % 4) + 4) % 4
        if k != 0 {
            out = normalized(out.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(k) * .pi / 2)))
        }
        if abs(straighten) > 0.01 {
            let e = out.extent
            let theta = straighten * .pi / 180
            let a = abs(theta)
            // 放大到转过之后仍然铺满原画框。
            let s = cos(a) + sin(a) * max(e.width / e.height, e.height / e.width)
            var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
            t = t.concatenating(CGAffineTransform(rotationAngle: -theta))
            t = t.concatenating(CGAffineTransform(scaleX: s, y: s))
            t = t.concatenating(CGAffineTransform(translationX: e.midX, y: e.midY))
            out = out.transformed(by: t).cropped(to: e)
        }
        return out
    }

    func apply(to image: CIImage) -> CIImage {
        let o = oriented(image)
        let e = o.extent
        let r = CGRect(x: rect.minX * e.width,
                       y: (1 - rect.maxY) * e.height,
                       width: rect.width * e.width,
                       height: rect.height * e.height).integral.intersection(e)
        guard r.width >= 1, r.height >= 1 else { return o }
        return o.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }
}

// MARK: - 马赛克

enum MosaicStyle: String, CaseIterable, Identifiable {
    case pixel, blur, hex, crystal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pixel: return "方块"
        case .blur: return "模糊"
        case .hex: return "蜂窝"
        case .crystal: return "晶格"
        }
    }

    var symbol: String {
        switch self {
        case .pixel: return "square.grid.3x3.fill"
        case .blur: return "drop.fill"
        case .hex: return "hexagon.fill"
        case .crystal: return "seal.fill"
        }
    }

    func effect(on image: CIImage, strength: CGFloat) -> CIImage {
        let extent = image.extent
        let dim = max(extent.width, extent.height)
        let source = image.clampedToExtent()
        let out: CIImage
        switch self {
        case .pixel:
            out = source.applyingFilter("CIPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputScaleKey: max(2, dim * (0.008 + 0.04 * strength)),
            ])
        case .blur:
            out = source.applyingFilter("CIGaussianBlur", parameters: [
                kCIInputRadiusKey: max(1, dim * (0.006 + 0.03 * strength)),
            ])
        case .hex:
            out = source.applyingFilter("CIHexagonalPixellate", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputScaleKey: max(2, dim * (0.008 + 0.04 * strength)),
            ])
        case .crystal:
            out = source.applyingFilter("CICrystallize", parameters: [
                kCIInputCenterKey: CIVector(x: 0, y: 0),
                kCIInputRadiusKey: max(2, dim * (0.006 + 0.03 * strength)),
            ])
        }
        return out.cropped(to: extent)
    }
}

struct MosaicStroke: Equatable {
    /// 归一化坐标（x/宽, y/高），原点在左上角。
    var points: [CGPoint]
    /// 笔刷直径，相对于图片长边。
    var width: CGFloat
    var erase: Bool
    var style: MosaicStyle
    var strength: CGFloat
}

/// 一种样式对应的一张蒙版。
struct MosaicMask {
    let style: MosaicStyle
    let strength: CGFloat
    let image: CGImage
}

/// 把笔画画成蒙版。每种"样式+强度"一张；橡皮擦对所有蒙版生效。
final class MosaicMaskSet {
    private struct Key: Hashable {
        let style: MosaicStyle
        let strength: Int

        init(_ stroke: MosaicStroke) {
            style = stroke.style
            strength = Int((stroke.strength * 100).rounded())
        }
    }

    let width: Int
    let height: Int
    private var order: [Key] = []
    private var contexts: [Key: CGContext] = [:]

    init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    private func makeContext() -> CGContext? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        return ctx
    }

    private func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * CGFloat(width), y: (1 - p.y) * CGFloat(height))
    }

    private func draw(_ points: [CGPoint], width lineWidth: CGFloat, white: Bool, in ctx: CGContext) {
        guard let first = points.first else { return }
        let w = max(1, lineWidth * CGFloat(max(width, height)))
        let gray: CGFloat = white ? 1 : 0
        ctx.setStrokeColor(gray: gray, alpha: 1)
        ctx.setFillColor(gray: gray, alpha: 1)
        if points.count == 1 {
            let c = point(first)
            ctx.fillEllipse(in: CGRect(x: c.x - w / 2, y: c.y - w / 2, width: w, height: w))
            return
        }
        ctx.setLineWidth(w)
        ctx.beginPath()
        ctx.move(to: point(first))
        for p in points.dropFirst() { ctx.addLine(to: point(p)) }
        ctx.strokePath()
    }

    private func context(for key: Key) -> CGContext? {
        if let ctx = contexts[key] { return ctx }
        guard let ctx = makeContext() else { return nil }
        contexts[key] = ctx
        order.append(key)
        return ctx
    }

    /// 增量绘制：涂抹过程中每次只画新的一小段。
    func add(points: [CGPoint], stroke: MosaicStroke) {
        if stroke.erase {
            for ctx in contexts.values { draw(points, width: stroke.width, white: false, in: ctx) }
        } else if let ctx = context(for: Key(stroke)) {
            draw(points, width: stroke.width, white: true, in: ctx)
        }
    }

    func rebuild(_ strokes: [MosaicStroke]) {
        order.removeAll()
        contexts.removeAll()
        for stroke in strokes { add(points: stroke.points, stroke: stroke) }
    }

    func snapshot() -> [MosaicMask] {
        order.compactMap { key in
            guard let image = contexts[key]?.makeImage() else { return nil }
            return MosaicMask(style: key.style, strength: CGFloat(key.strength) / 100, image: image)
        }
    }
}

struct MosaicParams: Equatable {
    var strokes: [MosaicStroke] = []

    var hasPaint: Bool { strokes.contains { !$0.erase } }

    static func composite(base: CIImage, masks: [MosaicMask]) -> CIImage {
        let extent = base.extent
        var out = base
        for mask in masks {
            var m = CIImage(cgImage: mask.image, options: [.colorSpace: NSNull()])
            let sx = extent.width / m.extent.width
            let sy = extent.height / m.extent.height
            if sx != 1 || sy != 1 {
                m = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }
            let effect = mask.style.effect(on: base, strength: mask.strength)
            out = effect.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: m,
            ])
        }
        return out.cropped(to: extent)
    }

    func apply(to image: CIImage) -> CIImage {
        guard hasPaint else { return image }
        let extent = image.extent
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let set = MosaicMaskSet(width: Int((extent.width * scale).rounded()),
                                height: Int((extent.height * scale).rounded()))
        set.rebuild(strokes)
        return Self.composite(base: image, masks: set.snapshot())
    }
}

// MARK: - 编辑历史

/// 一步已确认的编辑。参数都和分辨率无关，预览图和原图走同一套操作。
enum EditOp {
    case crop(CropParams)
    case adjust(AdjustParams)
    case look(id: String, intensity: CGFloat)
    case mosaic(MosaicParams)
    case overlay([OverlayItem])
    case ai(AIEdit)
    case beauty(BeautyParams)
    case liquify(LiquifyParams)
    case doodle(DoodleParams)
    case frame(FrameParams)
    case backdrop(BackdropParams)
    case collage(CollageParams)
    case layers(LayerStack)
    case reshape(ReshapeParams)
    case makeup(MakeupParams)
    case skin(SkinParams)
    case shape(ShapeParams)
    case instant(InstantParams)
    case effect(EffectParams)
    case bodyTone(BodyToneParams)
    case retouch(RetouchParams)

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .crop(let p):
            return p.apply(to: image)
        case .adjust(let p):
            return p.apply(to: image)
        case .look(let id, let intensity):
            return FilmLook.byID[id]?.apply(to: image, intensity: intensity) ?? image
        case .mosaic(let p):
            return p.apply(to: image)
        case .overlay(let items):
            return OverlayRenderer.composite(items, over: image)
        case .ai(let edit):
            return edit.apply(to: image)
        case .beauty(let params):
            return params.apply(to: image)
        case .liquify(let params):
            return params.apply(to: image)
        case .doodle(let params):
            return params.apply(to: image)
        case .frame(let params):
            return params.apply(to: image)
        case .backdrop(let params):
            return params.apply(to: image)
        case .collage(let params):
            return params.apply(to: image)
        case .layers(let stack):
            return stack.apply(to: image)
        case .reshape(let params):
            return params.apply(to: image)
        case .makeup(let params):
            return params.apply(to: image)
        case .skin(let params):
            return params.apply(to: image)
        case .shape(let params):
            return params.apply(to: image)
        case .instant(let params):
            return params.apply(to: image)
        case .effect(let params):
            return params.apply(to: image)
        case .bodyTone(let params):
            return params.apply(to: image)
        case .retouch(let params):
            return params.apply(to: image)
        }
    }

    static func apply(_ ops: [EditOp], to image: CIImage) -> CIImage {
        ops.reduce(image) { $1.apply(to: $0) }
    }
}

extension EditOp {
    /// 结果里把输入的画面整张画死了（AI 整张重画）：它前面那些步骤再改也透不出来。
    var bakesInput: Bool {
        if case .ai(let edit) = self {
            return edit.frame == nil && edit.ellipse == nil && !edit.hasRegion && !edit.toneOnly
        }
        return false
    }

    /// 浮在照片上面的装饰（文字、贴纸、形状、图层）：AI 只处理下面的照片，它们一直留在最上面。
    var floats: Bool {
        switch self {
        case .overlay, .layers: return true
        default: return false
        }
    }

    /// 把历史末尾那些浮在照片上的装饰挑出来（它们后面没有改画布的步骤，挪到最后不会变位置）。
    /// photo = 照片本身的步骤，floating = 可以一直浮在最上面的装饰。
    static func splitFloating(_ ops: [EditOp]) -> (photo: [EditOp], floating: [EditOp]) {
        var photo: [EditOp] = []
        var floating: [EditOp] = []
        var movable = true
        for op in ops.reversed() {
            if movable, op.floats {
                floating.insert(op, at: 0)
            } else {
                if op.changesCanvas { movable = false }
                photo.insert(op, at: 0)
            }
        }
        return (photo, floating)
    }

    /// AI 改内容时，把历史末尾的滤镜和整张调色先拿下来：AI 只看没调色的照片，出来以后再盖回最上面，
    /// 不然颜色会被 AI 重新算一遍，滤镜就没了。美颜、美妆、美体这些和滤镜换先后差别很小，越过它们继续找。
    static func splitColor(_ ops: [EditOp]) -> (base: [EditOp], color: [EditOp]) {
        var base: [EditOp] = []
        var color: [EditOp] = []
        var open = true
        for op in ops.reversed() {
            guard open else {
                base.insert(op, at: 0)
                continue
            }
            switch op {
            case .look:
                color.insert(op, at: 0)
            case .adjust(let p) where !p.localChanged:
                color.insert(op, at: 0)
            case .beauty, .makeup, .skin, .liquify, .reshape, .shape, .bodyTone:
                base.insert(op, at: 0)
            default:
                open = false
                base.insert(op, at: 0)
            }
        }
        return (base, color)
    }

    /// 会改变画布大小、或者把整个画面挪了位置的步骤。
    var changesCanvas: Bool {
        switch self {
        case .crop, .frame, .backdrop, .collage, .shape, .instant: return true
        case .ai(let edit): return edit.reframed
        default: return false
        }
    }

    /// 再次进入这个工具时，这一步是不是该被重新打开接着改。
    func reopens(with tool: Tool) -> Bool {
        switch (self, tool) {
        case (.overlay, .text), (.overlay, .sticker), (.overlay, .graphic), (.mosaic, .mosaic), (.doodle, .doodle), (.doodle, .mark),
             (.frame, .frame), (.backdrop, .backdrop), (.effect, .effect):
            return true
        default:
            return false
        }
    }
}
