import CoreImage
import SwiftUI

struct BodyToneState {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, pick, paint, erase
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "自动"
            case .pick: return "选色"
            case .paint: return "涂抹"
            case .erase: return "擦除"
            }
        }
        var symbol: String {
            switch self {
            case .auto: return "wand.and.stars"
            case .pick: return "eyedropper"
            case .paint: return "paintbrush"
            case .erase: return "eraser"
            }
        }
    }

    var params = BodyToneParams()
    var key: BodyToneKey = .bright
    var mode: Mode = .auto
    var brush: CGFloat = 40
    /// 正在识别。
    var busy = false
    /// 一直显示选中的范围（红色）。
    var showMask = false
    /// 刚涂完、刚改完范围：先把范围亮出来一下。
    var flash = false
    var error: String?
    var autoTone: SIMD3<Float>?
}

extension EditorModel {
    func beginBodyTone() {
        bodyToneState = BodyToneState()
        guard let cg = baseUIImage?.cgImage else { return }
        bodyToneState.busy = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { BodyToneDetector.detect(in: cg) }.value
            guard let self, self.tool == .bodyTone else { return }
            self.bodyToneState.busy = false
            self.bodyToneState.params.person = found.person
            self.bodyToneState.params.face = found.face
            self.bodyToneState.params.faceMean = found.faceMean
            if let tone = found.tone {
                self.bodyToneState.params.tone = tone
                self.bodyToneState.autoTone = tone
            } else {
                self.bodyToneState.params.useColor = false
                self.bodyToneState.mode = .pick
            }
            self.bodyToneMeasure()
            self.renderBodyTone()
        }
    }

    func bodyToneOp() -> EditOp? {
        bodyToneState.params.isIdentity ? nil : .bodyTone(bodyToneState.params)
    }

    func renderBodyTone() {
        guard tool == .bodyTone, let base = basePreview else { return }
        let state = bodyToneState
        var out = state.params.isIdentity ? base : state.params.apply(to: base)
        if state.showMask || state.flash { out = Self.redOverlay(out, mask: state.params.mask(for: base)) }
        showLive(out)
    }

    private static func redOverlay(_ image: CIImage, mask: CIImage) -> CIImage {
        let red = CIImage(color: CIColor(red: 1, green: 0.15, blue: 0.2)).cropped(to: image.extent)
        let half = FX.mix(image, red, t: 0.5)
        return half.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask,
        ]).cropped(to: image.extent)
    }

    /// 范围变了，重新算身体的平均颜色。
    private func bodyToneMeasure() {
        guard let base = basePreview else { return }
        if let mean = BodyToneDetector.mean(base, mask: bodyToneState.params.mask(for: base)) {
            bodyToneState.params.bodyMean = mean
        }
    }

    func setBodyTone(_ value: CGFloat) {
        let key = bodyToneState.key
        var v = min(max(value, key.signed ? -1 : 0), 1)
        if abs(v) < 0.02 { v = 0 }
        bodyToneState.params.values[key] = v == 0 ? nil : v
        bodyToneState.flash = false
        renderBodyTone()
    }

    func setBodyToneRange(_ value: CGFloat, editing: Bool) {
        bodyToneState.params.range = value
        bodyToneState.flash = editing
        if !editing { bodyToneMeasure() }
        renderBodyTone()
    }

    func setBodyToneMode(_ mode: BodyToneState.Mode) {
        bodyToneState.mode = mode
        bodyToneState.error = nil
        if mode == .auto {
            if let tone = bodyToneState.autoTone {
                bodyToneState.params.tone = tone
                bodyToneState.params.useColor = true
            } else {
                bodyToneState.error = "没有认出人脸，用选色或涂抹指定要提亮的地方。"
            }
            bodyToneMeasure()
        }
        renderBodyTone()
    }

    func setBodyToneShowMask(_ on: Bool) {
        bodyToneState.showMask = on
        renderBodyTone()
    }

    /// 选色：点一下身体上的皮肤。
    func bodyToneTapped(at point: CGPoint) {
        guard tool == .bodyTone, bodyToneState.mode == .pick, let cg = baseUIImage?.cgImage else { return }
        let r = 0.006
        guard let tone = BodyToneDetector.mean(cg, CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)) else { return }
        bodyToneState.params.tone = tone
        bodyToneState.params.useColor = true
        bodyToneState.error = nil
        bodyToneMeasure()
        bodyToneFlash()
    }

    /// 把范围亮一下再收回去。
    private func bodyToneFlash() {
        bodyToneState.flash = true
        renderBodyTone()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.tool == .bodyTone, self.bodyToneState.flash else { return }
            self.bodyToneState.flash = false
            self.renderBodyTone()
        }
    }

    var bodyToneWantsStrokes: Bool { bodyToneState.mode == .paint || bodyToneState.mode == .erase }

    func bodyToneStrokeBegan(at point: CGPoint, displayScale: CGFloat) {
        guard tool == .bodyTone, bodyToneWantsStrokes, displayScale > 0 else { return }
        bodyToneState.params.strokes.append(AIRegion.stroke(points: [point], width: bodyToneState.brush / displayScale,
                                                            erase: bodyToneState.mode == .erase))
        bodyToneState.flash = true
        renderBodyTone()
    }

    func bodyToneStrokeMoved(to point: CGPoint) {
        guard tool == .bodyTone, let last = bodyToneState.params.strokes.indices.last else { return }
        bodyToneState.params.strokes[last].points.append(point)
        renderBodyTone()
    }

    func bodyToneStrokeEnded() {
        bodyToneMeasure()
        bodyToneFlash()
    }

    func bodyToneStrokeCancelled() {
        guard tool == .bodyTone, !bodyToneState.params.strokes.isEmpty else { return }
        bodyToneState.params.strokes.removeLast()
        bodyToneState.flash = false
        renderBodyTone()
    }

    func bodyToneUndoStroke() {
        guard !bodyToneState.params.strokes.isEmpty else { return }
        bodyToneState.params.strokes.removeLast()
        bodyToneMeasure()
        renderBodyTone()
    }

    func bodyToneReset() {
        bodyToneState.params.values = [:]
        bodyToneState.params.strokes = []
        bodyToneState.params.range = 0.45
        setBodyToneMode(.auto)
    }

    static let bodyTonePreset = AIPreset(
        title: "身体提亮", symbol: "sun.max",
        prompt: "这张照片里脸比身体白很多。把露出来的身体皮肤（脖子、肩膀、胸口、手臂、手、腰腹、腿）提亮，让它的明暗和颜色与脸自然一致、过渡均匀；" +
            "脸、头发、衣服和背景的明暗颜色都不变。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐，仍然是一张真实的照片。",
        toneOnly: true)
}
