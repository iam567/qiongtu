import CoreImage
import SwiftUI
import UIKit

/// 美妆底部的大类。
enum MakeupCategory: String, CaseIterable, Identifiable {
    case look, lip, brow, eye, contour, blush, nail, decor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .look: return "妆容"
        case .lip: return "口红"
        case .brow: return "眉毛"
        case .eye: return "眼妆"
        case .contour: return "修容"
        case .blush: return "腮红"
        case .nail: return "美甲"
        case .decor: return "装饰"
        }
    }

    /// 这一类下面的小分类；空 = 没有。
    var tabs: [String] {
        switch self {
        case .look, .nail: return []
        case .lip: return ["唇妆", "颜色", "质地", "晕染", "唇线"]
        case .brow: return ["眉形", "颜色"]
        case .eye: return ["眼妆", "眼影", "眼线", "睫毛", "卧蚕", "美瞳", "双眼皮", "眼神光"]
        case .contour: return ["立体", "高光", "阴影", "雀斑", "痣"]
        case .blush: return ["套装", "颜色", "部位", "质地"]
        case .decor: return ["面部", "纹身贴"]
        }
    }

    /// 美甲和装饰交给 AI，不需要在本机找脸。
    var isLocal: Bool { self != .nail && self != .decor }
}

/// 面板上的一个选项。
struct MakeupOption: Identifiable {
    enum Kind {
        /// 用这张脸渲染出来的缩略图。
        case thumb
        /// 色块。
        case swatch(MakeupColor)
        /// 图标按钮。
        case symbol(String)
        /// 交给 AI 做的。
        case ai(AIPreset)
    }

    /// 缩略图取脸上的哪一块。
    enum Crop { case face, eye, lips }

    let id: String
    let title: String
    var kind: Kind = .thumb
    var selected = false
    /// 点一下以后怎么改这张脸的妆。
    var apply: (inout FaceMakeup) -> Void = { _ in }
    /// 缩略图上画什么（画在一张没上妆的脸上）。
    var preview: (inout FaceMakeup) -> Void = { _ in }
    /// 整套预设选中后记到哪个槽位：高亮用，浓淡滑块也靠它知道在调哪一套。
    var slot: String?
    /// 修容里的高光 / 阴影分区：点了以后滑块调的就是这一区。
    var zone: String?
    /// 点了以后进入或退出"在脸上点痣"。
    var togglesMolePlacing = false
}

/// 美妆工具打开期间的全部状态。
struct MakeupState {
    var faces: [FaceInfo] = []
    var detecting = false
    /// 找到了脸，但都太小或太侧，五官定位不可信。
    var unreliable = false
    var faceIndex = 0
    /// 每张脸上的妆，和 faces 一一对应。
    var params = MakeupParams()
    var category: MakeupCategory = .look
    var tabIndex: [MakeupCategory: Int] = [:]
    /// 每张脸在每个槽位选了哪套预设。
    var picks: [Int: [String: String]] = [:]
    /// 整套预设（妆容、眼妆、立体）的浓淡滑块位置。
    var strengths: [Int: [String: CGFloat]] = [:]
    /// 修容里正在调的高光 / 阴影分区。
    var zone: String?
    var placingMole = false
    var thumbs: [String: UIImage] = [:]
    var requested: Set<String> = []
    var session = 0

    /// true 时画布把单指拖动当成画笔；美妆只用点选。
    var wantsStrokes: Bool { false }

    var tab: Int { tabIndex[category] ?? 0 }
    var current: FaceMakeup? { params.faces.indices.contains(faceIndex) ? params.faces[faceIndex] : nil }
    func pick(_ slot: String) -> String? { picks[faceIndex]?[slot] }
    func strength(_ slot: String) -> CGFloat { strengths[faceIndex]?[slot] ?? 0.8 }
}

/// EditorModel 在这些时机调用下面的函数（工具是 .makeup 时）。
extension EditorModel {
    func beginMakeup() {
        let session = makeupState.session + 1
        makeupState = MakeupState()
        makeupState.session = session
        MKMaskCache.shared.removeAll()
        guard let cg = baseUIImage?.cgImage else { return }
        makeupState.detecting = true
        Task { [weak self] in
            guard let self else { return }
            let list = await self.findFaces()
            let found = await Task.detached(priority: .userInitiated) { () -> [(FaceInfo, MKTone)] in
                list.map { ($0, MKTone.measure(face: $0, in: cg)) }
            }.value
            guard self.tool == .makeup, self.makeupState.session == session else { return }
            let usable = found.filter { $0.0.hasReliableLandmarks && $0.0.outerLips.count >= 6 }
            self.makeupState.detecting = false
            self.makeupState.unreliable = usable.isEmpty && !found.isEmpty
            self.makeupState.faces = usable.map(\.0)
            self.makeupState.params.faces = usable.map { FaceMakeup(face: $0.0, tone: $0.1) }
            self.makeupState.faceIndex = 0
            self.focusMakeupFace()
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没改返回 nil。
    func makeupOp() -> EditOp? {
        makeupState.params.isIdentity ? nil : .makeup(makeupState.params)
    }

    /// 还没确认的修改（放大后渲染高清贴片用）。
    func makeupPendingOps() -> [EditOp]? {
        makeupState.params.isIdentity ? [] : [.makeup(makeupState.params)]
    }

    /// 单击了画面：正在点痣就落一颗痣，否则点到哪张脸就切到哪张。
    func makeupTapped(at point: CGPoint) {
        if rescueFace(at: point) { return }
        let state = makeupState
        if state.placingMole, let face = state.current {
            let area = face.face.box.insetBy(dx: -face.face.box.width * 0.25, dy: -face.face.box.height * 0.3)
            guard area.contains(point) else { return }
            changeMakeup { m in
                if m.contour.moles.count < 16 {
                    m.contour.moles.append(.custom(Int((point.x * 10_000).rounded()), Int((point.y * 10_000).rounded())))
                }
            }
            return
        }
        guard state.faces.count > 1 else { return }
        var best: (index: Int, distance: CGFloat)?
        for (i, face) in state.faces.enumerated() {
            let area = face.box.insetBy(dx: -face.box.width * 0.35, dy: -face.box.height * 0.45)
            guard area.contains(point) else { continue }
            let d = hypot(point.x - face.box.midX, point.y - face.box.midY)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        if let best { selectMakeupFace(best.index) }
    }

    func makeupStrokeBegan(at point: CGPoint, displayScale: CGFloat) {}

    func makeupStrokeMoved(to point: CGPoint) {}

    func makeupStrokeEnded() {}

    func makeupStrokeCancelled() {}

    // MARK: 选脸

    func selectMakeupFace(_ index: Int) {
        guard makeupState.faces.indices.contains(index) else { return }
        makeupState.faceIndex = index
        makeupState.zone = nil
        focusMakeupFace()
    }

    /// 把画布放大到正在化妆的这张脸。
    private func focusMakeupFace() {
        guard makeupState.faces.indices.contains(makeupState.faceIndex), let size = baseUIImage?.size else {
            focusRect = nil
            return
        }
        let face = makeupState.faces[makeupState.faceIndex]
        let bw = face.box.width * size.width, bh = face.box.height * size.height
        let side = max(bw, bh) * 1.9
        let cx = face.box.midX * size.width, cy = face.box.midY * size.height - bh * 0.1
        let rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            .intersection(CGRect(origin: .zero, size: size))
        focusRect = CGRect(x: rect.minX / size.width, y: rect.minY / size.height,
                           width: rect.width / size.width, height: rect.height / size.height)
    }

    // MARK: 改妆

    /// 改当前这张脸的妆并刷新画面。
    func changeMakeup(_ body: (inout FaceMakeup) -> Void) {
        let i = makeupState.faceIndex
        guard makeupState.params.faces.indices.contains(i) else { return }
        body(&makeupState.params.faces[i])
        renderMakeup()
    }

    private func renderMakeup() {
        guard let base = basePreview else { return }
        showLive(makeupState.params.apply(to: base))
    }

    func setMakeupCategory(_ category: MakeupCategory) {
        makeupState.category = category
        makeupState.zone = nil
        makeupState.placingMole = false
    }

    func setMakeupTab(_ index: Int) {
        makeupState.tabIndex[makeupState.category] = index
        makeupState.zone = nil
        makeupState.placingMole = false
    }

    private func setPick(_ slot: String, _ name: String?) {
        makeupState.picks[makeupState.faceIndex, default: [:]][slot] = name
    }

    /// 点了面板上的一个选项。
    func chooseMakeup(_ option: MakeupOption) {
        if case .ai(let preset) = option.kind {
            startAIPreset(preset, group: .fix)
            return
        }
        if option.togglesMolePlacing {
            makeupState.placingMole.toggle()
            return
        }
        let category = makeupState.category
        // 单独改了某一样，就不再是"一整套"了。
        if category != .look { setPick("look", nil) }
        if category == .eye, makeupState.tab != 0 { setPick("eye", nil) }
        if category == .contour, makeupState.tab == 1 || makeupState.tab == 2 { setPick("sculpt", nil) }
        if category == .lip, makeupState.tab != 0 { setPick("lip", nil) }
        if category == .blush, makeupState.tab != 0 { setPick("blush", nil) }
        if let slot = option.slot {
            setPick(slot, option.id == "none" ? nil : option.id)
            makeupState.strengths[makeupState.faceIndex, default: [:]][slot] = 0.8
            if slot == "look" {
                // 换了整套妆，各部分原来单独选的预设都不算数了。
                for part in ["lip", "eye", "sculpt", "blush"] { setPick(part, nil) }
            }
        }
        if let zone = option.zone { makeupState.zone = zone } else if option.id == "none" { makeupState.zone = nil }
        changeMakeup(option.apply)
    }

    // MARK: 浓淡滑块

    /// 当前这一页的浓淡；nil = 这一页现在没有可调的。
    var makeupAmount: CGFloat? {
        let state = makeupState
        guard let m = state.current else { return nil }
        switch state.category {
        case .look:
            return state.pick("look") == nil ? nil : state.strength("look")
        case .lip:
            guard let lip = m.lip else { return nil }
            return state.tab == 4 ? lip.liner : lip.amount
        case .brow:
            return m.brow?.amount
        case .eye:
            switch state.tab {
            case 0: return state.pick("eye") == nil ? nil : state.strength("eye")
            case 1: return m.eye.shadow?.amount
            case 2: return m.eye.liner?.amount
            case 3: return m.eye.lashes?.amount
            case 4: return m.eye.aegyo
            case 5: return m.eye.lens?.amount
            case 6: return m.eye.foldAmount
            default: return m.eye.catchlightAmount
            }
        case .contour:
            switch state.tab {
            case 0: return state.pick("sculpt") == nil ? nil : state.strength("sculpt")
            case 1, 2: return state.zone.map { Self.zoneValue($0, m.contour) }
            case 3: return m.contour.freckleAmount
            default: return nil
            }
        case .blush:
            return m.blush?.amount
        case .nail, .decor:
            return nil
        }
    }

    func setMakeupAmount(_ value: CGFloat) {
        let v = min(max(value, 0), 1)
        let state = makeupState
        func remember(_ slot: String) { makeupState.strengths[state.faceIndex, default: [:]][slot] = v }
        switch state.category {
        case .look:
            guard let name = state.pick("look"), let look = (MakeupCatalog.currentLooks + MakeupCatalog.looks + MakeupCatalog.maleLooks).first(where: { $0.name == name }) else { return }
            remember("look")
            changeMakeup { $0.apply(look, strength: v / 0.8) }
        case .lip:
            changeMakeup { if state.tab == 4 { $0.lip?.liner = v } else { $0.lip?.amount = v } }
        case .brow:
            changeMakeup { $0.brow?.amount = v }
        case .eye:
            switch state.tab {
            case 0:
                guard let name = state.pick("eye") else { return }
                remember("eye")
                changeMakeup { m in
                    m.eye = MakeupCatalog.eyePreset(name)
                    m.eye.scale(by: v / 0.8)
                }
            case 1: changeMakeup { $0.eye.shadow?.amount = v }
            case 2: changeMakeup { $0.eye.liner?.amount = v }
            case 3: changeMakeup { $0.eye.lashes?.amount = v }
            case 4: changeMakeup { $0.eye.aegyo = v }
            case 5: changeMakeup { $0.eye.lens?.amount = v }
            case 6: changeMakeup { $0.eye.foldAmount = v }
            default: changeMakeup { $0.eye.catchlightAmount = v }
            }
        case .contour:
            switch state.tab {
            case 0:
                guard let name = state.pick("sculpt") else { return }
                remember("sculpt")
                changeMakeup { m in
                    var sculpt = MakeupCatalog.contourPreset(name)
                    sculpt.scaleSculpt(by: v / 0.8)
                    m.contour.setSculpt(sculpt)
                }
            case 1, 2:
                guard let zone = state.zone else { return }
                changeMakeup { Self.setZone(zone, v, &$0.contour) }
            case 3: changeMakeup { $0.contour.freckleAmount = v }
            default: break
            }
        case .blush:
            changeMakeup { $0.blush?.amount = v }
        case .nail, .decor:
            break
        }
    }

    static func zoneValue(_ zone: String, _ c: ContourMakeup) -> CGFloat {
        switch zone {
        case "forehead": return c.forehead
        case "noseLight": return c.noseLight
        case "cheekLight": return c.cheekLight
        case "chinLight": return c.chinLight
        case "cupid": return c.cupid
        case "underEye": return c.underEye
        case "noseShade": return c.noseShade
        case "jaw": return c.jaw
        case "cheekShade": return c.cheekShade
        default: return c.temple
        }
    }

    static func setZone(_ zone: String, _ v: CGFloat, _ c: inout ContourMakeup) {
        switch zone {
        case "forehead": c.forehead = v
        case "noseLight": c.noseLight = v
        case "cheekLight": c.cheekLight = v
        case "chinLight": c.chinLight = v
        case "cupid": c.cupid = v
        case "underEye": c.underEye = v
        case "noseShade": c.noseShade = v
        case "jaw": c.jaw = v
        case "cheekShade": c.cheekShade = v
        default: c.temple = v
        }
    }

    // MARK: 自选颜色

    /// 这一页能不能自己选颜色，以及现在是什么颜色。
    var makeupCustomColor: MakeupColor? {
        let state = makeupState
        guard let m = state.current else { return nil }
        switch (state.category, state.tab) {
        case (.lip, 1): return m.lip?.color ?? MakeupCatalog.lipColors[0].color
        case (.brow, 1): return m.brow?.color ?? MakeupCatalog.browColors[1].color
        case (.blush, 1): return m.blush?.color ?? MakeupCatalog.blushColors[0].color
        default: return nil
        }
    }

    func setMakeupCustomColor(_ color: MakeupColor) {
        let state = makeupState
        setPick("look", nil)
        switch (state.category, state.tab) {
        case (.lip, 1):
            setPick("lip", nil)
            changeMakeup { if $0.lip == nil { $0.lip = LipMakeup(color: color) } else { $0.lip?.color = color } }
        case (.brow, 1):
            changeMakeup { m in
                if m.brow == nil { m.brow = MakeupCatalog.browPreset(.natural) }
                m.brow?.color = color
            }
        case (.blush, 1):
            setPick("blush", nil)
            changeMakeup { if $0.blush == nil { $0.blush = BlushMakeup(color: color) } else { $0.blush?.color = color } }
        default:
            break
        }
    }

    // MARK: 缩略图

    func makeupThumbKey(_ option: MakeupOption) -> String {
        "\(makeupState.faceIndex)|\(makeupState.category.rawValue)|\(makeupState.tab)|\(option.id)"
    }

    /// 这一页的选项里还没有缩略图的，在后台用这张脸渲染出来。
    func prepareMakeupThumbs(_ options: [MakeupOption], crop: MakeupOption.Crop) {
        guard let base = basePreview, let face = makeupState.current else { return }
        var blank = FaceMakeup(face: face.face, tone: face.tone)
        var jobs: [(String, FaceMakeup)] = []
        for option in options {
            guard case .thumb = option.kind else { continue }
            let key = makeupThumbKey(option)
            guard !makeupState.requested.contains(key) else { continue }
            makeupState.requested.insert(key)
            blank = FaceMakeup(face: face.face, tone: face.tone)
            option.preview(&blank)
            jobs.append((key, blank))
        }
        guard !jobs.isEmpty else { return }
        let session = makeupState.session
        let info = face.face
        Task.detached(priority: .userInitiated) { [weak self] in
            // 缩略图只有指甲盖大：先把图缩到"脸宽 400 像素"左右再上妆，又快又省内存。
            var base = base
            let boxWidth = info.box.width * base.extent.width
            if boxWidth > 400, let small = Renderer.shared.rasterize(base, maxDimension: max(base.extent.width, base.extent.height) * 400 / boxWidth) {
                base = small.ci
            }
            let extent = base.extent
            guard let g = MKFace(face: info, extent: extent.size) else { return }
            let r = MakeupThumb.rect(crop, g)
            let area = CGRect(x: extent.minX + r.minX, y: extent.minY + extent.height - r.maxY, width: r.width, height: r.height)
                .intersection(extent).integral
            guard area.width >= 8, area.height >= 8 else { return }
            var batch: [String: UIImage] = [:]
            for (index, job) in jobs.enumerated() {
                let out = MakeupParams(faces: [job.1]).apply(to: base)
                let piece = out.cropped(to: area).transformed(by: CGAffineTransform(translationX: -area.minX, y: -area.minY))
                if let raster = Renderer.shared.rasterize(piece, maxDimension: 200) {
                    batch[job.0] = UIImage(cgImage: raster.cg)
                }
                // 每几张交一次，缩略图一批批出来，不用等全部画完。
                if batch.count >= 6 || index == jobs.count - 1 {
                    let ready = batch
                    batch = [:]
                    await self?.addMakeupThumbs(ready, session: session)
                }
            }
        }
    }

    private func addMakeupThumbs(_ thumbs: [String: UIImage], session: Int) {
        guard tool == .makeup, makeupState.session == session else { return }
        makeupState.thumbs.merge(thumbs) { _, new in new }
    }
}

/// 缩略图取脸上的哪一块（像素，原点左上角）。
enum MakeupThumb {
    static func rect(_ crop: MakeupOption.Crop, _ g: MKFace) -> CGRect {
        func px(_ v: MKVec) -> CGPoint { CGPoint(x: g.roi.minX + v.x * g.roi.width, y: g.roi.minY + v.y * g.roi.height) }
        func square(around points: [MKVec], grow: CGFloat) -> CGRect {
            let p = points.map(px)
            let xs = p.map(\.x), ys = p.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return g.roi }
            let side = max(maxX - minX, maxY - minY) * grow
            return CGRect(x: (minX + maxX) / 2 - side / 2, y: (minY + maxY) / 2 - side / 2, width: side, height: side)
        }
        switch crop {
        case .face:
            let c = px(g.eyeMid + g.down * (g.mouthDist * 0.45))
            let side = g.faceWidth * g.roi.width * 1.4
            return CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side)
        case .eye:
            // 取露得多的那只眼睛，连眉毛一起。
            let i = g.eyes[0].side >= g.eyes[1].side ? 0 : 1
            var points = g.eyes[i].outline
            if let brow = g.brows[i] { points += [brow.center.at(0), brow.center.at(0.5), brow.center.at(1)] }
            return square(around: points, grow: 1.35)
        case .lips:
            return square(around: g.lipsOuter, grow: 1.6)
        }
    }
}
