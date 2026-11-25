import CoreImage
import SwiftUI

/// 面部重塑工具打开期间的全部状态。
struct ReshapeState {
    /// 每张脸的数值、背景保护的蒙版、变形还原的笔画。
    var params = ReshapeParams()
    var detecting = false
    /// 找不到脸、五官不可信、识别不到人物这类错误提示。
    var error: String?
    var faceIndex = 0
    var category: ReshapeCategory = .shape
    /// 当前在调的项目；这一类里只有 AI 项目时是 nil。
    var key: ReshapeKey? = .faceWidth
    var side: ReshapeSide = .both

    /// 背景保护：变形只动人，背景不动。
    var protect = false
    var protectBusy = false
    /// 变形还原：用手指把涂过的地方恢复成没变形的样子。
    var restoring = false
    /// 还原笔刷的直径（屏幕上的点）。
    var brush: CGFloat = 70

    /// 每张脸的关键点能不能用（和 params.faces 一一对应）；当前这张脸上哪几类因为关键点不对而调不了。
    var usable: [Bool] = []
    var missing: Set<ReshapeCategory> = []

    /// 这次打开工具的标记：后台任务回来时用它判断结果还作不作数。
    var session = UUID()
    /// 提前算好的人像蒙版和"没有人的背景"（实时预览用）。
    var personMask: CGImage?
    var plate: CGImage?
    var strokeRadius: CGFloat = 0

    /// true 时画布把单指拖动当成画笔，交给 reshapeStroke* 这几个函数。
    var wantsStrokes: Bool { restoring }

    var faces: [ReshapeFace] { params.faces }

    var face: ReshapeFace? { params.faces.indices.contains(faceIndex) ? params.faces[faceIndex] : nil }

    /// 当前项目显示在滑块上的数值（-1...1）。
    var value: Float {
        guard let key, let face else { return 0 }
        return face.value(key, side: key.paired ? side : .both)
    }

    func isModified(_ key: ReshapeKey) -> Bool {
        face?.values[key] != nil
    }

    var hasChanges: Bool { !params.isIdentity }
}

/// EditorModel 在这些时机调用下面的函数（工具是 .reshape 时）。
extension EditorModel {
    func beginReshape() {
        reshapeState = ReshapeState()
        focusRect = nil
        guard let cg = baseUIImage?.cgImage else { return }
        let session = reshapeState.session
        reshapeState.detecting = true
        Task { [weak self] in
            guard let self else { return }
            let found = await self.findFaces()
            guard self.tool == .reshape, self.reshapeState.session == session else { return }
            self.reshapeState.detecting = false
            self.reshapeState.params.faces = found.map { ReshapeFace(info: $0) }
            let size = CGSize(width: cg.width, height: cg.height)
            self.reshapeState.usable = found.map { ReshapeParams.usable($0, size: size) }
            if found.isEmpty {
                self.reshapeState.error = "这张图里没有找到人脸。"
            } else if let index = self.reshapeState.usable.firstIndex(of: true) {
                self.selectReshapeFace(index)
            } else {
                self.reshapeState.error = "找到了脸，但五官位置认不准（脸太小、太糊或者侧得太多），没法做面部重塑。"
            }
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没改返回 nil。
    func reshapeOp() -> EditOp? {
        reshapeState.params.isIdentity ? nil : .reshape(reshapeState.params)
    }

    /// 还没确认的修改（放大后渲染高清贴片用）。
    func reshapePendingOps() -> [EditOp]? {
        reshapeState.params.isIdentity ? [] : [.reshape(reshapeState.params)]
    }

    /// 单击了画面：还原模式下在这里点一下还原一小片；否则点哪张脸就选哪张脸。
    func reshapeTapped(at point: CGPoint) {
        if rescueFace(at: point) { return }
        guard !reshapeState.detecting else { return }
        if reshapeState.restoring {
            guard reshapeState.hasChanges, let face = reshapeState.face else { return }
            let size = baseUIImage?.size ?? CGSize(width: 1, height: 1)
            let long = max(size.width, size.height, 1)
            let radius = max(face.info.box.width * size.width / long * 0.22, 0.01)
            reshapeState.params.restore.append(ReshapeRestoreStroke(points: [point], radius: radius))
            renderReshape()
            return
        }
        let faces = reshapeState.faces, usable = reshapeState.usable
        let hits = faces.indices.filter {
            usable.indices.contains($0) && usable[$0] && faces[$0].info.box.insetBy(dx: -faces[$0].info.box.width * 0.2,
                                                                                     dy: -faces[$0].info.box.height * 0.3).contains(point)
        }
        guard let index = hits.min(by: { faces[$0].info.box.width < faces[$1].info.box.width }) else { return }
        selectReshapeFace(index)
    }

    func selectReshapeFace(_ index: Int) {
        guard reshapeState.faces.indices.contains(index) else { return }
        reshapeState.faceIndex = index
        // 这张脸上嘴唇、鼻子、眉毛的关键点各自对不对，不对的那一类不让调。
        let info = reshapeState.faces[index].info
        let size = baseUIImage?.size ?? CGSize(width: 1, height: 1)
        reshapeState.missing = Set([ReshapeCategory.lips, .nose, .brows].filter {
            !ReshapeParams.supports($0, face: info, size: size)
        })
        updateReshapeFocus()
    }

    /// 把画面放大到当前这张脸。
    private func updateReshapeFocus() {
        guard let face = reshapeState.face, let size = baseUIImage?.size, size.width > 0, size.height > 0 else {
            focusRect = nil
            return
        }
        let bw = face.info.box.width * size.width, bh = face.info.box.height * size.height
        let side = max(bw, bh) * 2.1
        let cx = face.info.box.midX * size.width
        // Vision 的框不含额头上半部分，往上挪一点把头顶也框进来。
        let cy = face.info.box.midY * size.height - bh * 0.12
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size))
        focusRect = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                           width: rect.width / size.width, height: rect.height / size.height)
    }

    // MARK: 调数值

    func selectReshapeCategory(_ category: ReshapeCategory) {
        reshapeState.category = category
        reshapeState.key = category.keys.first
        reshapeState.side = .both
    }

    func selectReshapeKey(_ key: ReshapeKey) {
        reshapeState.key = key
        if !key.paired { reshapeState.side = .both }
    }

    /// 改当前项目的数值（-1...1）。
    func setReshape(_ value: Float) {
        guard let key = reshapeState.key, reshapeState.params.faces.indices.contains(reshapeState.faceIndex) else { return }
        let snapped: Float = abs(value) < 0.02 ? 0 : value
        reshapeState.params.faces[reshapeState.faceIndex].set(key, side: reshapeState.side, to: snapped)
        renderReshape()
    }

    /// 全部还原：所有脸的数值和还原笔画都清掉。
    func resetReshape() {
        for index in reshapeState.params.faces.indices { reshapeState.params.faces[index].values = [:] }
        reshapeState.params.restore = []
        renderReshape()
    }

    func renderReshape() {
        guard let base = basePreview else { return }
        showLive(reshapeState.params.apply(to: base, plate: reshapeState.plate))
    }

    // MARK: 背景保护

    /// 开关背景保护。第一次打开时在本机识别一次人像，并把"没有人的背景"提前补好。
    func setReshapeProtect(_ on: Bool) {
        guard tool == .reshape, !reshapeState.protectBusy else { return }
        guard on else {
            reshapeState.protect = false
            reshapeState.params.lockMask = nil
            renderReshape()
            return
        }
        if let mask = reshapeState.personMask {
            reshapeState.protect = true
            reshapeState.params.lockMask = mask
            renderReshape()
            return
        }
        guard let cg = baseUIImage?.cgImage, let base = basePreview else { return }
        let session = reshapeState.session
        reshapeState.protectBusy = true
        reshapeState.error = nil
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                guard let mask = PersonSegmenter.mask(for: cg) else { return (nil, nil) }
                return (mask, Renderer.shared.cgImage(LiquifyGrid.backgroundPlate(base, lock: mask)))
            }.value
            guard let self, self.tool == .reshape, self.reshapeState.session == session else { return }
            self.reshapeState.protectBusy = false
            guard let mask = found.0 else {
                self.reshapeState.error = "这张图里没有识别到人物，没法保护背景。"
                return
            }
            self.reshapeState.personMask = mask
            self.reshapeState.plate = found.1
            self.reshapeState.protect = true
            self.reshapeState.params.lockMask = mask
            self.renderReshape()
        }
    }

    // MARK: 变形还原

    func setReshapeRestoring(_ on: Bool) {
        reshapeState.restoring = on
    }

    func undoReshapeRestore() {
        guard !reshapeState.params.restore.isEmpty else { return }
        reshapeState.params.restore.removeLast()
        renderReshape()
    }

    /// 单指落下。point 是归一化图片坐标（原点左上角）；displayScale = 图片长边在屏幕上占多少点。
    func reshapeStrokeBegan(at point: CGPoint, displayScale: CGFloat) {
        guard reshapeState.restoring, displayScale > 0 else { return }
        reshapeState.strokeRadius = reshapeState.brush / 2 / displayScale
        reshapeState.params.restore.append(ReshapeRestoreStroke(points: [point], radius: reshapeState.strokeRadius))
        renderReshape()
    }

    func reshapeStrokeMoved(to point: CGPoint) {
        guard reshapeState.restoring, let last = reshapeState.params.restore.indices.last else { return }
        reshapeState.params.restore[last].points.append(point)
        renderReshape()
    }

    func reshapeStrokeEnded() {}

    /// 第二根手指落下、手势被取消：撤掉刚开始的这一笔。
    func reshapeStrokeCancelled() {
        undoReshapeRestore()
    }

    // MARK: AI 项目

    /// 点了带 AI 角标的项目：已经调好的先保留成一步，再把脸部发给 AI。
    func runReshapeAI(_ item: ReshapeAIItem) {
        startAIPreset(item.preset, group: .fix)
    }
}
