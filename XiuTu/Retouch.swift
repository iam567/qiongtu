import CoreImage
import SwiftUI

/// 手动消除的一笔补出来的一块：贴在画面的 rect 上（归一化，左上原点），按 mask 羽化。
struct RetouchPatch: Equatable {
    let rect: CGRect
    let image: CGImage
    let mask: CGImage

    static func == (a: RetouchPatch, b: RetouchPatch) -> Bool { a.image === b.image && a.rect == b.rect }

    func apply(to image: CIImage) -> CIImage {
        let e = image.extent
        let target = CGRect(x: e.minX + rect.minX * e.width, y: e.maxY - rect.maxY * e.height,
                            width: rect.width * e.width, height: rect.height * e.height)
        func placed(_ c: CIImage) -> CIImage {
            c.transformed(by: CGAffineTransform(scaleX: target.width / c.extent.width, y: target.height / c.extent.height))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        }
        let p = placed(CIImage(cgImage: self.image)), m = placed(CIImage(cgImage: mask, options: [.colorSpace: NSNull()]))
        return p.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: m])
            .cropped(to: e)
    }
}

struct RetouchParams: Equatable {
    var patches: [RetouchPatch] = []

    func apply(to image: CIImage) -> CIImage { patches.reduce(image) { $1.apply(to: $0) } }
}

struct RetouchState {
    enum Mode: String, CaseIterable, Identifiable {
        case smart, clone, restore
        var id: String { rawValue }
        var title: String {
            switch self {
            case .smart: return "智能消除"
            case .clone: return "仿制"
            case .restore: return "还原"
            }
        }
        var symbol: String {
            switch self {
            case .smart: return "wand.and.stars"
            case .clone: return "doc.on.doc"
            case .restore: return "clock.arrow.circlepath"
            }
        }
    }

    var mode: Mode = .smart
    var brush: CGFloat = 46
    var params = RetouchParams()
    /// 正在涂的这一笔。
    var stroke: MosaicStroke?
    /// 仿制：取样的地方；取样和涂抹起点的偏移（定下来以后接着涂不变）。
    var source: CGPoint?
    var offset: CGSize?
    var sampling = false
    var busy = false
    var error: String?
}

enum RetouchEngine {
    /// 一笔的外接框（归一化），四周留余量。
    static func box(_ stroke: MosaicStroke, size: CGSize, margin: CGFloat) -> CGRect {
        let long = max(size.width, size.height), half = stroke.width * long / 2
        var b: CGRect?
        for p in stroke.points {
            let r = CGRect(x: p.x * size.width - half, y: p.y * size.height - half, width: half * 2, height: half * 2)
            b = b?.union(r) ?? r
        }
        guard var r = b else { return .zero }
        r = r.insetBy(dx: -margin * max(r.width, half * 2) - 2, dy: -margin * max(r.height, half * 2) - 2)
            .intersection(CGRect(origin: .zero, size: size))
        return CGRect(x: r.minX / size.width, y: r.minY / size.height, width: r.width / size.width, height: r.height / size.height)
    }

    /// 裁出一块（归一化，左上原点），最长 side。
    static func piece(_ image: CIImage, _ rect: CGRect, side: CGFloat) -> CGImage? {
        let e = image.extent
        let r = CGRect(x: e.minX + rect.minX * e.width, y: e.maxY - rect.maxY * e.height, width: rect.width * e.width, height: rect.height * e.height)
            .integral.intersection(e)
        guard r.width >= 4, r.height >= 4 else { return nil }
        let moved = image.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        return Renderer.shared.rasterize(moved, maxDimension: side)?.cg
    }

    /// 这一笔在那一块里的蒙版。soft：边缘羽化多少（占笔刷直径）。
    static func mask(_ stroke: MosaicStroke, rect: CGRect, size: CGSize, w: Int, h: Int, soft: CGFloat, grow: CGFloat = 0) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        let kx = CGFloat(w) / (rect.width * size.width), ky = CGFloat(h) / (rect.height * size.height)
        let width = stroke.width * max(size.width, size.height) * kx
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(gray: 1, alpha: 1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(max(width * (1 - soft) + grow, 1))
        func p(_ q: CGPoint) -> CGPoint {
            CGPoint(x: (q.x - rect.minX) * size.width * kx, y: CGFloat(h) - (q.y - rect.minY) * size.height * ky)
        }
        ctx.move(to: p(stroke.points[0]))
        if stroke.points.count == 1 { ctx.addLine(to: CGPoint(x: p(stroke.points[0]).x + 0.1, y: p(stroke.points[0]).y)) }
        for q in stroke.points.dropFirst() { ctx.addLine(to: p(q)) }
        ctx.strokePath()
        guard let cg = ctx.makeImage() else { return nil }
        guard soft > 0 else { return cg }
        let m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let s = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: width * soft * 0.3]).cropped(to: m.extent)
        return Renderer.shared.context.createCGImage(s, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 智能消除：用周围的纹理补。
    static func smart(_ image: CIImage, stroke: MosaicStroke) -> RetouchPatch? {
        let size = image.extent.size
        let rect = box(stroke, size: size, margin: 1.1)
        guard let part = piece(image, rect, side: 760),
              let hole = mask(stroke, rect: rect, size: size, w: part.width, h: part.height, soft: 0, grow: 4),
              let filled = Inpaint.fill(part, mask: hole),
              let edge = mask(stroke, rect: rect, size: size, w: part.width, h: part.height, soft: 0.06, grow: 5) else { return nil }
        return RetouchPatch(rect: rect, image: filled, mask: edge)
    }

    /// 仿制：照着偏移处的画面搬过来。
    static func clone(_ image: CIImage, stroke: MosaicStroke, offset: CGSize) -> RetouchPatch? {
        let e = image.extent
        let rect = box(stroke, size: e.size, margin: 0.2)
        // 取样处超出画面的地方用边缘像素。
        let shifted = image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -offset.width * e.width, y: offset.height * e.height)).cropped(to: e)
        guard let part = piece(shifted, rect, side: 1800),
              let m = mask(stroke, rect: rect, size: e.size, w: part.width, h: part.height, soft: 0.3) else { return nil }
        return RetouchPatch(rect: rect, image: part, mask: m)
    }

    /// 还原：变回原照片的像素。
    static func restore(_ image: CIImage, original: CIImage, stroke: MosaicStroke) -> RetouchPatch? {
        let rect = box(stroke, size: image.extent.size, margin: 0.2)
        guard let part = piece(original, rect, side: 1800),
              let m = mask(stroke, rect: rect, size: image.extent.size, w: part.width, h: part.height, soft: 0.35) else { return nil }
        return RetouchPatch(rect: rect, image: part, mask: m)
    }
}

extension EditorModel {
    func beginRetouch() { retouchState = RetouchState() }

    func retouchOp() -> EditOp? { retouchState.params.patches.isEmpty ? nil : .retouch(retouchState.params) }

    /// 还原用的"原照片"：打开时的样子；中间裁过、重画过构图的，用那一步之后的样子。没有可还原的返回 nil。
    private var retouchOriginal: [EditOp]? {
        guard !ops.isEmpty else { return nil }
        guard let last = ops.lastIndex(where: \.changesCanvas) else { return [] }
        return last == ops.count - 1 ? nil : Array(ops[...last])
    }

    func renderRetouch() {
        guard tool == .retouch, let base = basePreview else { return }
        var out = retouchState.params.apply(to: base)
        if let stroke = retouchState.stroke,
           let m = RetouchEngine.mask(stroke, rect: CGRect(x: 0, y: 0, width: 1, height: 1), size: base.extent.size,
                                      w: Int(base.extent.width / 2), h: Int(base.extent.height / 2), soft: 0) {
            out = AIRegion.overlay(base: out, mask: m)
        }
        showLive(out)
    }

    func setRetouchMode(_ mode: RetouchState.Mode) {
        retouchState.mode = mode
        retouchState.error = nil
        retouchState.sampling = mode == .clone && retouchState.source == nil
        if mode == .restore, retouchOriginal == nil {
            retouchState.error = ops.isEmpty ? "还没有改过，没有可还原的。" : "最后一步换过构图，没法从原照片还原。"
        }
    }

    func retouchTapped(at point: CGPoint) {
        guard tool == .retouch, retouchState.sampling else { return }
        retouchState.source = point
        retouchState.offset = nil
        retouchState.sampling = false
        retouchState.error = nil
    }

    var retouchWantsStrokes: Bool { !retouchState.sampling && !retouchState.busy }

    func retouchStrokeBegan(at point: CGPoint, displayScale: CGFloat) {
        guard tool == .retouch, retouchWantsStrokes, displayScale > 0 else { return }
        if retouchState.mode == .restore, retouchOriginal == nil { return }
        if retouchState.mode == .clone, retouchState.offset == nil {
            guard let s = retouchState.source else {
                retouchState.sampling = true
                return
            }
            retouchState.offset = CGSize(width: s.x - point.x, height: s.y - point.y)
        }
        retouchState.error = nil
        retouchState.stroke = AIRegion.stroke(points: [point], width: retouchState.brush / displayScale, erase: false)
        renderRetouch()
    }

    func retouchStrokeMoved(to point: CGPoint) {
        guard tool == .retouch, retouchState.stroke != nil else { return }
        retouchState.stroke?.points.append(point)
        renderRetouch()
    }

    func retouchStrokeCancelled() {
        retouchState.stroke = nil
        renderRetouch()
    }

    func retouchStrokeEnded() {
        guard tool == .retouch, let stroke = retouchState.stroke, let source else { return }
        let mode = retouchState.mode, offset = retouchState.offset ?? .zero
        let before = ops, params = retouchState.params, original = retouchOriginal
        retouchState.busy = true
        Task { [weak self] in
            let patch = await Task.detached(priority: .userInitiated) { () -> RetouchPatch? in
                // 按原图分辨率算，放大看也清楚。
                let image = params.apply(to: EditOp.apply(before, to: source))
                switch mode {
                case .smart: return RetouchEngine.smart(image, stroke: stroke)
                case .clone: return RetouchEngine.clone(image, stroke: stroke, offset: offset)
                case .restore: return original.flatMap { RetouchEngine.restore(image, original: EditOp.apply($0, to: source), stroke: stroke) }
                }
            }.value
            guard let self, self.tool == .retouch else { return }
            self.retouchState.busy = false
            self.retouchState.stroke = nil
            if let patch {
                self.retouchState.params.patches.append(patch)
            } else {
                self.retouchState.error = "这一笔补不了，涂小一点再试。"
            }
            self.renderRetouch()
        }
    }

    func retouchUndo() {
        guard !retouchState.busy, !retouchState.params.patches.isEmpty else { return }
        retouchState.params.patches.removeLast()
        renderRetouch()
    }

    func retouchReset() {
        guard !retouchState.busy else { return }
        retouchState.params.patches = []
        renderRetouch()
    }
}

/// 手动消除面板。
struct RetouchPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.retouchState
        VStack(spacing: 12) {
            if let error = state.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HScroll {
                HRow(spacing: 8) {
                    ForEach(RetouchState.Mode.allCases) { mode in
                        Chip(title: mode.title, symbol: mode.symbol, selected: state.mode == mode) { model.setRetouchMode(mode) }
                    }
                    Chip(title: "修手", symbol: "hand.raised", selected: false, badge: "AI") { model.startAIHand() }
                }
            }
            HStack(spacing: 10) {
                Text("笔刷").font(.system(size: 13)).foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { Double(state.brush) }, set: { model.retouchState.brush = CGFloat($0) }), in: 10...140)
                if state.busy { ProgressView().tint(.white) }
                round("arrow.uturn.backward") { model.retouchUndo() }.opacity(state.params.patches.isEmpty ? 0.35 : 1)
                round("arrow.counterclockwise") { model.retouchReset() }.opacity(state.params.patches.isEmpty ? 0.35 : 1)
            }
            if state.mode == .clone {
                HStack(spacing: 8) {
                    Chip(title: state.sampling ? "点画面取样" : "重新取样", symbol: "scope", selected: state.sampling) {
                        model.retouchState.sampling = true
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

extension EditorModel {
    static let handPrompt = "涂抹区域里的手画错了（手指数量、长短、关节或形状不对）。把涂抹区域里的手改成一只自然、解剖正确的手：五根手指，长短粗细和关节正确，指甲自然，" +
        "手的大小、朝向、姿势和手腕、手臂衔接得上；肤色、光线方向、明暗和清晰度与手臂一致。区域外、袖子、首饰和背景都不变，结果是一张真实的照片。"

    /// AI 修手：先把手动消除做的保留成一步，再去涂手。
    func startAIHand() {
        commitTool { [self] in
            beginAI(group: .fix, prompt: Self.handPrompt)
            guard tool == .ai else { return }
            aiPresetTitle = "修手"
            aiHandFix = true
        }
    }

    func runAIHand() {
        guard aiHasRegion else {
            aiError = "先涂住要修的手。"
            return
        }
        aiPrompt = Self.handPrompt
        aiPresetTitle = "修手"
        aiToneOnly = false
        aiPart = nil
        runAI()
    }
}
