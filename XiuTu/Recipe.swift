import CoreGraphics
import CoreImage
import Foundation

/// AI 修图一步是怎么发起的：套到新照片上时按这个再跑一遍（结果会和原来不一样，费用也会再算一次）。
struct AIRecipe: Codable, Equatable {
    var group: String
    /// 用户看到的那条指令（不含"再生成一次"加的变化要求）。
    var prompt: String
    var presetTitle: String
    var masterCompose: Bool
    var faceCrop: Bool
    var hairCrop: Bool
    var reframe: String
    var strength: CGFloat = 1
    var toneOnly = false
    var soften: CGFloat = 0
    /// 贴回原图的脸。
    var keepFace: Bool?
    /// 只在变了的地方用 AI 的像素。
    var changedOnly: Bool?
}

/// 能套到新照片上的一步。
enum RecipeAction: Codable {
    case adjust(AdjustParams)
    case look(id: String, intensity: CGFloat)
    /// aspect = 裁出来的宽高比（像素），area = 裁出来的部分占原图面积的比例。
    case crop(CropParams, aspect: CGFloat, area: CGFloat)
    case frame(FrameParams)
    case backdrop(BackdropParams)
    case instant(InstantParams)
    case effect(EffectParams)
    case ai(AIRecipe)
}

/// 处理过程里的一步：名字、一句细节；action 为空 = 这一步和原图的位置绑在一起（涂抹、文字、涂鸦……），套用时跳过。
struct RecipeStep: Codable, Identifiable {
    var id = UUID()
    var title: String
    var detail: String
    var symbol: String
    var action: RecipeAction?
}

/// 一张图从原图到成品的全部步骤。
struct EditRecipe: Codable {
    var steps: [RecipeStep]

    var copyable: Int { steps.filter { $0.action != nil }.count }

    /// 从编辑历史整理出步骤。input 是原图（算裁剪比例用）。
    init(ops: [EditOp], input: CIImage) {
        var steps: [RecipeStep] = []
        for (i, op) in ops.enumerated() {
            steps.append(Self.step(op, inputSize: {
                EditOp.apply(Array(ops[..<i]), to: input).extent.size
            }))
        }
        self.steps = steps
    }

    private static func percent(_ v: CGFloat) -> String { "\(Int((v * 100).rounded()))" }

    static func step(_ op: EditOp, inputSize: () -> CGSize) -> RecipeStep {
        switch op {
        case .adjust(let p):
            var parts: [String] = []
            for key in AdjustKey.allCases where p[key] != 0 {
                let v = Int((p[key] * 100).rounded())
                parts.append("\(key.title) \(v > 0 ? "+" : "")\(v)")
            }
            if p.hslChanged { parts.append("HSL") }
            if !p.curves.isIdentity { parts.append("曲线") }
            if !p.split.isIdentity { parts.append("色调分离") }
            if p.localChanged { parts.append("局部调色") }
            return RecipeStep(title: "调色", detail: parts.joined(separator: "、"), symbol: "slider.horizontal.3", action: .adjust(p))
        case .look(let id, let intensity):
            let name = FilmLook.byID[id]?.name ?? "滤镜"
            return RecipeStep(title: "滤镜", detail: "\(name) \(percent(intensity))", symbol: "camera.filters",
                              action: .look(id: id, intensity: intensity))
        case .crop(let p):
            var size = inputSize()
            if p.quarterTurns % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
            let w = p.rect.width * size.width, h = p.rect.height * size.height
            let aspect = h > 0 ? w / h : 1
            var parts: [String] = []
            if p.quarterTurns != 0 { parts.append("旋转 \(p.quarterTurns * 90)°") }
            if p.flip { parts.append("翻转") }
            if abs(p.straighten) > 0.05 { parts.append(String(format: "拉直 %.1f°", p.straighten)) }
            if p.rect != CGRect(x: 0, y: 0, width: 1, height: 1) { parts.append(String(format: "裁成 %.2f:1", aspect)) }
            return RecipeStep(title: "裁剪", detail: parts.joined(separator: "、"), symbol: "crop",
                              action: .crop(p, aspect: aspect, area: p.rect.width * p.rect.height))
        case .frame(let p):
            return RecipeStep(title: "边框", detail: "", symbol: "square.dashed", action: .frame(p))
        case .backdrop(let p):
            return RecipeStep(title: "背景", detail: p.ratio.title, symbol: "rectangle.on.rectangle", action: .backdrop(p))
        case .instant(let p):
            return RecipeStep(title: "拍立得", detail: p.stock.title, symbol: "photo", action: .instant(p))
        case .effect(let p):
            let name = p.kind?.title ?? "特效"
            return RecipeStep(title: "特效", detail: "\(name) \(percent(p.strength))", symbol: "sparkles.rectangle.stack",
                              action: .effect(p))
        case .ai(let edit):
            guard let r = edit.recipe, let group = AIPresetGroup(rawValue: r.group) else {
                return RecipeStep(title: "AI", detail: "涂抹或融合的结果", symbol: "sparkles", action: nil)
            }
            var detail = r.presetTitle.isEmpty ? String(r.prompt.prefix(18)) : r.presetTitle
            if group == .master, r.masterCompose { detail += " · 大师构图" }
            return RecipeStep(title: "AI \(group.title)", detail: detail, symbol: "sparkles", action: .ai(r))
        case .mosaic:
            return RecipeStep(title: "马赛克", detail: "", symbol: "checkerboard.rectangle", action: nil)
        case .overlay:
            return RecipeStep(title: "文字 / 贴纸 / 形状", detail: "", symbol: "textformat", action: nil)
        case .doodle:
            return RecipeStep(title: "涂鸦", detail: "", symbol: "scribble.variable", action: nil)
        case .liquify:
            return RecipeStep(title: "推拉", detail: "", symbol: "hand.draw", action: nil)
        case .beauty:
            return RecipeStep(title: "美颜", detail: "", symbol: "face.smiling", action: nil)
        case .makeup:
            return RecipeStep(title: "美妆", detail: "", symbol: "paintbrush.pointed", action: nil)
        case .skin:
            return RecipeStep(title: "皮肤", detail: "", symbol: "drop", action: nil)
        case .reshape:
            return RecipeStep(title: "面部重塑", detail: "", symbol: "face.dashed", action: nil)
        case .bodyTone:
            return RecipeStep(title: "身体提亮", detail: "", symbol: "sun.max", action: nil)
        case .shape:
            return RecipeStep(title: "美体", detail: "", symbol: "figure.stand", action: nil)
        case .layers:
            return RecipeStep(title: "图层", detail: "", symbol: "square.3.layers.3d", action: nil)
        case .collage:
            return RecipeStep(title: "拼图", detail: "", symbol: "square.grid.2x2", action: nil)
        }
    }
}

extension CropParams {
    /// 套到另一张图上：旋转、翻转、拉直照搬；裁剪框保持同样的比例、同样的中心位置、差不多同样占多大，放不下就缩小。
    func adapted(aspect: CGFloat, area: CGFloat, to size: CGSize) -> CropParams {
        var p = self
        guard aspect > 0, size.width > 0, size.height > 0, rect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return p }
        var s = size
        if quarterTurns % 2 == 1 { s = CGSize(width: s.height, height: s.width) }
        // 归一化宽 w、高 h：w * W / (h * H) = aspect，w * h = area。
        var h = (area * s.width / (aspect * s.height)).squareRoot()
        var w = h * aspect * s.height / s.width
        let k = max(w, h, 1)
        w /= k
        h /= k
        var x = rect.midX - w / 2, y = rect.midY - h / 2
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)
        p.rect = CGRect(x: x, y: y, width: w, height: h)
        return p
    }
}
