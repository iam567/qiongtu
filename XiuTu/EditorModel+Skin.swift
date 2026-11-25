import CoreImage
import SwiftUI
import simd

/// 皮肤面板里当前选中的那一项。
enum SkinItem: Equatable {
    /// 带滑块的项目。
    case key(SkinKey)
    /// 肤色统一（作用在全身，不属于某一张脸）。
    case unify
    /// 点痘：点哪里修哪里。
    case heal
    /// 遮瑕笔。
    case conceal
    /// 修容笔的高光、阴影、橡皮。
    case highlight, shadow, erase

    var isBrush: Bool {
        switch self {
        case .conceal, .highlight, .shadow, .erase: return true
        default: return false
        }
    }
}

/// 皮肤工具打开期间的全部状态。
struct SkinState {
    var tab: SkinTab = .skin
    var item: SkinItem = .key(.smooth)
    var params = SkinParams()
    /// 正在调哪张脸。
    var faceIndex = 0
    var detecting = false
    /// 画笔在屏幕上的粗细（点）和力度。
    var brush: CGFloat = 34
    var strength: CGFloat = 0.6
    /// 点痘的大小，相对脸宽。
    var healSize: CGFloat = 0.07
    /// 正在识别人像（肤色统一第一次用时要等一下）。
    var unifyBusy = false
    /// 这次进工具有没有找过人像蒙版。
    var askedBody = false
    /// 用来丢掉过期的后台结果。
    var token = UUID()
    /// 最近一笔的粗细（以图片长边为 1）。画笔模式下轻点时拿它当这一点的大小。
    var lastWidth: CGFloat = 0.02

    /// true 时画布把单指拖动当成画笔，交给下面的 skinStroke* 函数；false 时单指只是点选。
    var wantsStrokes: Bool { item.isBrush }

    var face: SkinFace? { params.faces.indices.contains(faceIndex) ? params.faces[faceIndex] : nil }

    /// 当前这张脸的五官关键点可不可信。不可信时只有磨皮、肤色这几项能用。
    var reliable: Bool { face?.face.hasReliableLandmarks ?? false }

    func value(_ key: SkinKey) -> CGFloat { face?[key] ?? 0 }

    func isOn(_ preset: SkinPreset) -> Bool { face?.matches(preset) ?? false }

    func usable(_ key: SkinKey) -> Bool { face != nil && (reliable || !key.needsLandmarks) }

    var hasStrokes: Bool { !params.strokes.isEmpty }
}

/// EditorModel 在这些时机调用下面的函数（工具是 .skin 时）。
extension EditorModel {
    func beginSkin() {
        skinState = SkinState()
        guard baseUIImage?.cgImage != nil, let base = basePreview else { return }
        skinState.detecting = true
        let token = skinState.token
        Task { [weak self] in
            guard let self else { return }
            let list = await self.findFaces()
            let found = await Task.detached(priority: .userInitiated) { () -> [SkinFace] in
                list.map { face in
                    // 量不出来（脸贴着画面边缘之类）就用一个常见的肤色顶上。
                    let tone = SkinEngine.measureTone(base, face: face, context: Renderer.shared.context)
                        ?? SIMD3<Float>(0.45, 0.30, 0.24)
                    return SkinFace(face: face, tone: tone)
                }
            }.value
            guard self.tool == .skin, self.skinState.token == token else { return }
            self.skinState.params.faces = found
            self.skinState.faceIndex = 0
            self.skinState.detecting = false
            self.updateSkinFocus()
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没改返回 nil。
    func skinOp() -> EditOp? {
        skinState.params.isIdentity ? nil : .skin(skinState.params)
    }

    /// 还没确认的修改（放大后渲染高清贴片用）。
    func skinPendingOps() -> [EditOp]? {
        skinState.params.isIdentity ? [] : [.skin(skinState.params)]
    }

    // MARK: 画面上的操作

    /// 单击了画面。point 是归一化图片坐标（原点左上角）。
    func skinTapped(at point: CGPoint) {
        if rescueFace(at: point) { return }
        guard tool == .skin, !skinState.detecting else { return }
        switch skinState.item {
        case .heal:
            skinState.params.strokes.append(SkinStroke(kind: .conceal, points: [point], width: skinHealWidth(near: point), strength: 1))
            renderSkin()
        case .conceal, .highlight, .shadow, .erase:
            // 画笔模式下轻点一下 = 点一笔。单击时系统可能先把它当成一笔的开头再取消，也可能不取消；
            // 如果刚才那一点已经留在画面上了，就不重复点。
            if let last = skinState.params.strokes.last, last.points.count == 1, let p = last.points.first,
               hypot(p.x - point.x, p.y - point.y) < 0.01 { return }
            skinState.params.strokes.append(SkinStroke(kind: skinStrokeKind(), points: [point], width: skinState.lastWidth,
                                                       strength: skinState.item == .conceal ? 1 : skinState.strength))
            renderSkin()
        default:
            selectSkinFace(at: point)
        }
    }

    /// 单指画笔（wantsStrokes 为 true 时才会来）。displayScale = 图片长边在屏幕上占多少点。
    func skinStrokeBegan(at point: CGPoint, displayScale: CGFloat) {
        guard tool == .skin, skinState.wantsStrokes, displayScale > 0 else { return }
        skinState.lastWidth = skinState.brush / displayScale
        skinState.params.strokes.append(SkinStroke(kind: skinStrokeKind(), points: [point], width: skinState.brush / displayScale,
                                                   strength: skinState.item == .conceal ? 1 : skinState.strength))
        renderSkin()
    }

    func skinStrokeMoved(to point: CGPoint) {
        guard tool == .skin, skinState.wantsStrokes, let last = skinState.params.strokes.indices.last else { return }
        skinState.params.strokes[last].points.append(point)
        renderSkin()
    }

    func skinStrokeEnded() {}

    /// 第二根手指落下、手势被取消：撤掉刚开始的这一笔。
    func skinStrokeCancelled() {
        undoSkinStroke()
    }

    private func skinStrokeKind() -> SkinStroke.Kind {
        switch skinState.item {
        case .highlight: return .highlight
        case .shadow: return .shadow
        case .erase: return .erase
        default: return .conceal
        }
    }

    /// 点痘的笔触粗细（以图片长边为 1）：按离得最近的那张脸的宽度算。
    private func skinHealWidth(near point: CGPoint) -> CGFloat {
        guard let size = baseUIImage?.size, size.width > 0, size.height > 0 else { return 0.012 }
        let long = max(size.width, size.height)
        let nearest = skinState.params.faces.min {
            hypot($0.face.box.midX - point.x, $0.face.box.midY - point.y) < hypot($1.face.box.midX - point.x, $1.face.box.midY - point.y)
        }
        guard let nearest else { return 0.012 }
        return skinState.healSize * SkinEngine.Frame(nearest.face, size: size).fw / long
    }

    // MARK: 面板用的操作

    func renderSkin() {
        guard tool == .skin, let base = basePreview else { return }
        showLive(skinState.params.apply(to: base))
    }

    func selectSkinTab(_ tab: SkinTab) {
        guard tab != skinState.tab else { return }
        skinState.tab = tab
        switch tab {
        case .brush: skinState.item = .highlight
        default: skinState.item = .key(SkinKey.keys(in: tab).first ?? .smooth)
        }
    }

    func setSkin(_ key: SkinKey, _ value: CGFloat) {
        let i = skinState.faceIndex
        guard skinState.params.faces.indices.contains(i) else { return }
        skinState.params.faces[i][key] = value
        renderSkin()
    }

    func toggleSkinPreset(_ preset: SkinPreset) {
        let i = skinState.faceIndex
        guard skinState.params.faces.indices.contains(i) else { return }
        let on = skinState.params.faces[i].matches(preset)
        skinState.params.faces[i].set(preset, on: !on)
        renderSkin()
    }

    func applySkinTone(_ preset: SkinTonePreset) {
        let i = skinState.faceIndex
        guard skinState.params.faces.indices.contains(i) else { return }
        skinState.params.faces[i][.white] = preset.white
        skinState.params.faces[i][.warmth] = preset.warmth
        skinState.params.faces[i][.rosy] = preset.rosy
        renderSkin()
    }

    /// 肤色统一。第一次用时先在本机认一下人像，之后就只动人身上的皮肤。
    func setSkinUnify(_ value: CGFloat) {
        skinState.params.unify = value < 0.01 ? 0 : min(value, 1)
        renderSkin()
        guard value > 0, !skinState.askedBody, let cg = baseUIImage?.cgImage else { return }
        skinState.askedBody = true
        skinState.unifyBusy = true
        let token = skinState.token
        Task { [weak self] in
            let mask = await Task.detached(priority: .userInitiated) { PersonSegmenter.mask(for: cg) }.value
            guard let self, self.tool == .skin, self.skinState.token == token else { return }
            self.skinState.unifyBusy = false
            self.skinState.params.bodyMask = mask
            self.renderSkin()
        }
    }

    func undoSkinStroke() {
        guard !skinState.params.strokes.isEmpty else { return }
        skinState.params.strokes.removeLast()
        renderSkin()
    }

    func clearSkinStrokes() {
        guard !skinState.params.strokes.isEmpty else { return }
        skinState.params.strokes = []
        renderSkin()
    }

    func selectSkinFace(_ index: Int) {
        guard skinState.params.faces.indices.contains(index) else { return }
        skinState.faceIndex = index
        updateSkinFocus()
    }

    private func selectSkinFace(at point: CGPoint) {
        guard skinState.params.faces.count > 1 else { return }
        var best: (index: Int, distance: CGFloat)?
        for (i, item) in skinState.params.faces.enumerated() {
            let box = item.face.box
            guard box.insetBy(dx: -box.width * 0.35, dy: -box.height * 0.45).contains(point) else { continue }
            let d = hypot(point.x - box.midX, point.y - box.midY)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        if let best { selectSkinFace(best.index) }
    }

    /// 把画面放大到当前这张脸（连额头和脖子）。
    private func updateSkinFocus() {
        guard let face = skinState.face?.face, let size = baseUIImage?.size, size.width > 0, size.height > 0 else {
            focusRect = nil
            return
        }
        let bw = face.box.width * size.width, bh = face.box.height * size.height
        let side = max(bw, bh) * 2.1
        let cx = face.box.midX * size.width
        let cy = face.box.midY * size.height
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size))
        focusRect = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                           width: rect.width / size.width, height: rect.height / size.height)
    }
}

/// 本机算法做不好的情况，交给 AI：只把脸这一块发出去，要求"是修不是画"。
enum SkinAI {
    private static let rules = """
     This is a retouch, not a redraw. The person must remain unmistakably the same individual: every facial feature keeps exactly the same \
    shape, size, position and proportions; same expression, gaze, makeup, hairstyle, lighting and colors. \
    Keep realistic skin texture with visible pores; no plastic, airbrushed or blurred look; do not whiten the skin, do not slim the face. \
    Keep the exact same framing and position of everything so the result can be overlaid on the original. Photorealistic.
    """

    static let acne = AIPreset(title: "AI 祛痘", symbol: "circle.dotted", prompt: """
    This is a close-up crop from a portrait photo. Remove acne, pimples, blackheads, blemishes, dark spots and post-acne marks from the skin, \
    and fill each spot with the natural skin tone and texture around it. Leave moles and freckles that look intentional.
    """ + rules, faceCrop: true)

    static let wrinkles = AIPreset(title: "AI 祛皱", symbol: "line.3.horizontal", prompt: """
    This is a close-up crop from a portrait photo. Soften forehead lines, crow's feet, fine lines under the eyes, nasolabial folds and neck lines \
    so the skin looks naturally rested, as if a few years younger, while still clearly an adult of the same age group. \
    Do not remove the lines completely and do not change the face shape.
    """ + rules, faceCrop: true)
}
