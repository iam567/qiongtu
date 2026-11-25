import CoreImage
import Foundation

/// 把另一张图的处理步骤，一步一步套到当前这张照片上。
/// 调色、滤镜、特效、裁剪、边框这类直接照搬参数；AI 那几步按原来的指令在这张照片上重新生成；
/// 和原图位置绑在一起的（涂抹、文字、涂鸦……）跳过。
extension EditorModel {
    func startRecipe(_ recipe: EditRecipe) {
        recipeTask?.cancel()
        recipeTask = Task { [weak self] in
            await self?.playRecipe(recipe)
        }
    }

    func stopRecipe() {
        recipeTask?.cancel()
        recipeTask = nil
        if aiRunning { cancelAI() }
        recipeStatus = nil
    }

    private func playRecipe(_ recipe: EditRecipe) async {
        let steps = recipe.steps.filter { $0.action != nil }
        for (i, step) in steps.enumerated() {
            guard !Task.isCancelled, let action = step.action else { break }
            recipeStatus = "\(i + 1)/\(steps.count) \(step.title)\(step.detail.isEmpty ? "" : " · " + step.detail)"
            // 等上一步彻底做完（底图重建好）再开始下一步。
            while isBusy || tool != nil {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if case .ai(let r) = action {
                guard await replayAI(r) else {
                    // AI 这一步没做成：停在这里，面板上留着出错的原因。
                    recipeStatus = nil
                    recipeTask = nil
                    return
                }
            } else if let op = localOp(action) {
                await appendOp(op)
            }
        }
        recipeStatus = nil
        recipeTask = nil
    }

    /// 本机那几步：照搬参数；裁剪按这张图的大小重新摆；特效需要主体蒙版的话按这张图重新算。
    private func localOp(_ action: RecipeAction) -> EditOp? {
        switch action {
        case .adjust(let p): return .adjust(p)
        case .look(let id, let intensity): return .look(id: id, intensity: intensity)
        case .crop(let p, let aspect, let area):
            guard let base = basePreview else { return .crop(p) }
            return .crop(p.adapted(aspect: aspect, area: area, to: base.extent.size))
        case .frame(let p): return .frame(p)
        case .backdrop(let p): return .backdrop(p)
        case .instant(let p): return .instant(p)
        case .effect(var p):
            if p.kind?.usesMask == true, let base = basePreview, let cg = Renderer.shared.cgImage(base) {
                p.mask = Cutout.mask(for: cg)
            }
            return .effect(p)
        case .ai:
            return nil
        }
    }

    /// AI 那一步：打开 AI 修图，用原来的指令和设置重新生成，结果出来后按原来的强度、柔化确认。
    private func replayAI(_ r: AIRecipe) async -> Bool {
        guard let group = AIPresetGroup(rawValue: r.group) else { return true }
        beginAI(group: group, prompt: r.prompt)
        guard tool == .ai else { return false }
        aiPresetTitle = r.presetTitle
        aiMasterCompose = r.masterCompose
        aiFaceCrop = r.faceCrop
        aiHairCrop = r.hairCrop
        aiReframe = AIReframe(rawValue: r.reframe) ?? .original
        aiToneOnly = r.toneOnly
        runAI()
        while aiRunning {
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard aiHasResult, tool == .ai else { return false }
        aiStrength = r.strength
        aiToneOnly = r.toneOnly
        aiSoften = r.soften
        aiKeepFace = r.keepFace ?? aiKeepFace
        aiChangedOnly = r.changedOnly ?? aiChangedOnly
        renderAI()
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            commitTool { done.resume() }
        }
        return true
    }
}
