import CoreImage
import SwiftUI
import UIKit
import simd

/// 美体塑形里的几种做法。主菜单"美体"下面的入口直接对应这几种（名字和个数不要改）。
enum ShapeMode: String, CaseIterable, Identifiable {
    /// 一键美体：几套整体预设。
    case preset
    /// 塑形：按部位（瘦身、手臂、腿部、体态、肩颈、小头、胸部、臀胯）用滑块调。
    case shape
    /// 增高：两条辅助线框出拉伸区域，滑块把这一段拉长或压短。
    case tall
    /// 瘦身：一个带弧线的框放在要瘦的地方，滑块沿弧线往里收或往外放。
    case slim
    /// 缩放：一个圆圈放在要改的地方，滑块把圈里的内容放大或缩小。
    case zoom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preset: return "一键美体"
        case .shape: return "塑形"
        case .tall: return "增高"
        case .slim: return "瘦身"
        case .zoom: return "缩放"
        }
    }

    /// 面板顶上那排切换用的短名字。
    var short: String { self == .preset ? "一键" : title }
}

/// 一键美体和塑形里交给 AI 做的那几项。
enum ShapeAI {
    private static let keep = "人物长相、发型、姿势、服装的款式和颜色、背景都不变，画面不要移动、裁切或缩放；皮肤保留毛孔和真实质感，不磨皮、不涂抹。结果仍然是一张真实的照片。"

    /// 只动一个部位时的限制：AI 常顺手把别处也改了（衣服变短、多出肚脐、换了手的样子）。
    private static let only = "只改上面说的部位，其余部位和原照片完全一样：不要让衣服变短、变紧或多露出皮肤，" +
        "不要凭空画出肚脐、腹肌线、锁骨线、纹身、首饰或新的褶皱，手、头发、腰腹和背景都不动。"

    static func preset(_ item: ShapeItem) -> AIPreset? {
        let prompt: String
        switch item {
        case .aiWaist: prompt = "让腰部明显变细一些，腰线收紧，左右对称，上身和胯部的比例自然。"
        case .aiSlimAll: prompt = "让全身整体瘦一圈：脸以外的躯干、腰、手臂、腿都按比例变细，自然协调，不要夸张。"
        case .aiArm: prompt = "让两只手臂（大臂和小臂）变细一些，去掉松弛的赘肉，线条紧致，手的大小和位置不变。"
        case .aiUpperArm: prompt = "让大臂（肩膀到手肘）变细一些，去掉松弛的赘肉，小臂和手不变。"
        case .aiForeArm: prompt = "让小臂（手肘到手腕）变细一些，线条流畅，大臂和手不变。"
        case .aiLeg: prompt = "让双腿（大腿和小腿）变细一些，线条流畅修长，腿的长度和位置、脚不变。"
        case .aiThigh: prompt = "让大腿变细一些，去掉内侧和外侧的赘肉，小腿和腿的长度不变。"
        case .aiCalf: prompt = "让小腿变细一些，小腿肚的肌肉块更柔和，大腿和脚不变。"
        case .aiShoulderLevel: prompt = "改善高低肩：让左右两边肩膀一样高，肩线水平，头和手臂的姿势基本不变。"
        case .aiSwanNeck: prompt = "让脖子更修长纤细，肩颈线条舒展优美，头的大小不变，保持自然。"
        case .aiWideShoulder: prompt = "让肩膀稍微宽一些，左右对称，头和手臂的大小不变，保持自然。"
        case .aiNarrowShoulder: prompt = "让肩膀稍微窄一些，左右对称，头和手臂的大小不变，保持自然。"
        case .aiSquareShoulder: prompt = "把溜肩改成平直利落的直角肩，肩头轮廓清楚，保持自然。"
        case .aiThinNeck: prompt = "让脖子变细一些，颈部线条干净，头和肩膀的大小不变。"
        case .aiLongNeck: prompt = "让脖子稍微长一些，头的大小不变，比例自然。"
        case .aiSmallHead: prompt = "让头部（包括头发）整体按比例缩小一点，头身比更好，五官和脸型不变，脖子和肩膀衔接自然，头周围露出来的背景补自然。"
        case .aiChest: prompt = "让胸部比现在明显丰满一些，左右对称，衣服被自然撑起、褶皱合理，领口的位置和露出的范围不变，不要夸张。"
        case .aiHips: prompt = "让胯部两侧的线条更圆润流畅，填平胯部凹陷，腰到大腿过渡自然。"
        case .aiWaistHip: prompt = "改善腰臀比：腰细一些、臀胯稍宽一些，曲线自然，不要夸张。"
        case .aiBelly: prompt = "把腹部收平一些，腰腹线条紧致自然，衣服的褶皱保持合理。"
        case .aiTummy: prompt = "让肚子小一圈，去掉小肚腩，腰线更明显，保持自然。"
        case .aiStraightLeg: prompt = "把腿型调直，改善 O 型腿或 X 型腿，让双腿线条笔直修长，腿的长度和位置不变。"
        case .aiStraightBack: prompt = "改善驼背：让背部挺直、肩膀自然打开、体态挺拔。"
        case .aiNeckForward: prompt = "改善脖子前倾（探颈）：让头部回到肩膀正上方，颈部线条舒展。"
        case .aiTrapezius: prompt = "让斜方肌（脖子到肩膀之间）变薄一些，肩颈线条更平直修长。"
        case .aiChestNatural: prompt = "让胸型更自然饱满、左右对称，尺寸不要夸张。"
        case .aiChestLift: prompt = "把胸部的位置稍微提高一些，胸型更挺拔，保持自然。"
        case .aiFullHip: prompt = "让臀部更圆润饱满一些，曲线自然，衣服的褶皱保持合理。"
        case .aiLiftHip: prompt = "把臀线提高一些，臀部更上翘紧致，保持自然。"
        default: return nil
        }
        // 体态类本来就要改姿势，不能再说"姿势不变"。
        let tail = item.group == .posture
            ? "人物长相、发型、服装的款式和颜色、背景都不变；除了上面说的体态，其余姿势不变。结果仍然是一张真实的照片。"
            : keep
        return AIPreset(title: item.title, symbol: item.symbol, prompt: prompt + (item.part == nil ? "" : item.part == .waist ? only.replacingOccurrences(of: "手、头发、腰腹和背景都不动", with: "手、头发和背景都不动") : only) + tail, part: item.part)
    }

    /// 一键美体里的 AI 预设。
    static let looks: [AIPreset] = [
        AIPreset(title: "自然", symbol: "figure.stand",
                 prompt: "让身材比例稍微更好一些：腰、手臂、腿略微变细，脖子略修长，改动很轻、看不出修过。" + keep),
        AIPreset(title: "超模", symbol: "figure.walk",
                 prompt: "让身材接近超模比例：头身比更好，腰和四肢更细，双腿和脖子更修长，肩线平直，仍然真实自然。" + keep),
        AIPreset(title: "纤细", symbol: "figure.stand",
                 prompt: "让全身更纤细苗条一些：腰、手臂、腿都适度变细，比例自然协调，不要夸张。" + keep),
        AIPreset(title: "紧致", symbol: "figure.cooldown",
                 prompt: "让身体线条更紧致：收紧腰腹、手臂和大腿的松弛感，体型大小基本不变。" + keep),
        AIPreset(title: "曲线", symbol: "figure.dance",
                 prompt: "让身材曲线更明显：腰更细、胸和臀更饱满，呈现自然的沙漏型比例，不要夸张。" + keep),
        AIPreset(title: "增肌", symbol: "figure.strengthtraining.traditional",
                 prompt: "让肌肉线条更明显一些：手臂、肩膀、腹部有健康的肌肉轮廓，不要夸张。" + keep),
    ]
}

/// 美体塑形工具打开期间的全部状态。
struct ShapeState {
    var mode: ShapeMode = .preset

    // 人体识别
    var body: ShapeBody?
    var detecting = false
    var detected = false

    // 塑形
    var values: [ShapeItem: ShapeAmount] = [:]
    var group: ShapeGroup = .slim
    var item: ShapeItem = .waist
    var side: ShapeSide = .both
    // 一键美体
    var preset: String?
    var presetStrength: CGFloat = 0.7

    // 增高：一条一条做，最后一条是正在调的。
    var talls: [ShapeTall] = []
    var headProtect = false
    var headBusy = false
    var headSearched = false
    /// 头的位置（原图上的单位坐标）。
    var headBox: CGRect?
    // 瘦身 / 缩放：最后一个是正在调的。
    var boxes: [ShapeBox] = []
    var spots: [ShapeSpot] = []
    /// 正在拖辅助线（增高时把拉伸区域以外的地方压暗）。
    var guideDragging = false

    // 背景保护
    var protect = false
    var protectBusy = false
    var lockMask: CGImage?
    var plate: CGImage?
    /// AI 补背景：开关、正在生成、补好的背景。
    var aiFill = false
    var aiFillBusy = false
    var aiPlate: CGImage?
    // 变形还原
    var restoring = false
    var restoreBrush: CGFloat = 0.06
    var restore: [ShapeRestoreStroke] = []

    var error: String?
}

/// EditorModel 在这些时机调用下面的函数（工具是 .shape 时）。
extension EditorModel {
    func beginShape() {
        shapeState = ShapeState()
        prepareShapeMode()
    }

    /// 从主菜单进来时指定做法（紧跟在 beginShape 之后调用）。
    func setShapeMode(_ mode: ShapeMode) {
        shapeState.mode = mode
        shapeState.restoring = false
        shapeState.error = nil
        prepareShapeMode()
        renderShape()
    }

    /// 面板里换一种做法：这边已经做出来的修改先保留成一步，再换过去。
    func switchShapeMode(_ mode: ShapeMode) {
        guard tool == .shape, mode != shapeState.mode, !isBusy else { return }
        if shapeParams().isIdentity {
            setShapeMode(mode)
        } else {
            commitTool { [self] in
                begin(.shape)
                if tool == .shape { setShapeMode(mode) }
            }
        }
    }

    /// 点 ✓ 时要写进历史的那一步；没改返回 nil。
    func shapeOp() -> EditOp? {
        let params = shapeParams()
        return params.isIdentity ? nil : .shape(params)
    }

    // MARK: 画面尺寸

    /// 当前这张图的大小（单位坐标：长边为 1）。
    var shapeUnitSize: CGSize {
        guard let e = basePreview?.extent, e.width > 0, e.height > 0 else { return CGSize(width: 1, height: 1) }
        let long = max(e.width, e.height)
        return CGSize(width: e.width / long, height: e.height / long)
    }

    /// 增高的各条带子（头部保护已经换算到各自的画面上），以及最后一条带子所在画面的大小。
    private func shapeResolvedTalls() -> (bands: [ShapeTall], lastInput: SIMD2<Float>) {
        let unit = shapeUnitSize
        var size = SIMD2(Float(unit.width), Float(unit.height))
        var maps: [ShapeTallMap] = []
        var bands: [ShapeTall] = []
        var lastInput = size
        for var band in shapeState.talls {
            band.head = nil
            if shapeState.headProtect, let head = shapeState.headBox {
                // 头的位置跟着前面几条带子的拉伸一起挪。
                var box: CGRect?
                for corner in [CGPoint(x: head.minX, y: head.minY), CGPoint(x: head.maxX, y: head.minY),
                               CGPoint(x: head.minX, y: head.maxY), CGPoint(x: head.maxX, y: head.maxY)] {
                    var p = SIMD2(Float(corner.x), Float(corner.y))
                    for map in maps { p = map.output(p) }
                    let r = CGRect(x: CGFloat(p.x), y: CGFloat(p.y), width: 0, height: 0)
                    box = box?.union(r) ?? r
                }
                band.head = box
            }
            lastInput = size
            bands.append(band)
            if band.amount != 0 {
                let map = ShapeTallMap(band, size: size)
                maps.append(map)
                size = map.outSize
            }
        }
        return (bands, lastInput)
    }

    /// 变形之后画面的大小（单位坐标）。只有增高会改它。
    var shapeOutputSize: CGSize {
        guard shapeState.mode == .tall else { return shapeUnitSize }
        return ShapeEngine.tallMaps(shapeResolvedTalls().bands, size: shapeUnitSize).outSize
    }

    // MARK: 参数和预览

    func shapeParams() -> ShapeParams {
        var params = ShapeParams()
        switch shapeState.mode {
        case .tall:
            params.talls = shapeResolvedTalls().bands
            return params
        case .slim:
            params.boxes = shapeState.boxes
        case .zoom:
            params.spots = shapeState.spots
        case .shape:
            params.body = shapeState.body
            params.values = shapeState.values
        case .preset:
            params.body = shapeState.body
            if let preset = ShapePreset.all.first(where: { $0.id == shapeState.preset }) {
                for (item, value) in preset.values {
                    params.values[item] = ShapeAmount(both: value * shapeState.presetStrength)
                }
            }
        }
        params.restore = shapeState.restore
        if shapeState.protect {
            params.lockMask = shapeState.lockMask
            if shapeState.aiFill { params.aiPlate = shapeState.aiPlate }
        }
        return params
    }

    func renderShape() {
        guard tool == .shape, let base = basePreview else { return }
        let params = shapeParams()
        showLive(params.isIdentity ? base : params.apply(to: base))
    }

    /// 进到某一种做法时的准备：需要识别人体的先识别，需要辅助线的先摆一个默认位置。
    private func prepareShapeMode() {
        let unit = shapeUnitSize
        switch shapeState.mode {
        case .preset, .shape:
            detectShapeBody()
        case .tall:
            if shapeState.talls.isEmpty {
                shapeState.talls = [ShapeTall(center: CGPoint(x: unit.width / 2, y: unit.height * 0.66),
                                              halfGap: unit.height * 0.13)]
            }
        case .slim:
            if shapeState.boxes.isEmpty {
                let w = min(unit.width, unit.height) * 0.46
                shapeState.boxes = [ShapeBox(center: CGPoint(x: unit.width / 2, y: unit.height / 2),
                                             width: w, height: w * 1.15)]
            }
        case .zoom:
            if shapeState.spots.isEmpty {
                shapeState.spots = [ShapeSpot(center: CGPoint(x: unit.width / 2, y: unit.height * 0.35),
                                              radius: min(unit.width, unit.height) * 0.17)]
            }
        }
    }

    private func detectShapeBody() {
        guard !shapeState.detected, !shapeState.detecting, let cg = baseUIImage?.cgImage else { return }
        shapeState.detecting = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { ShapeBodyDetector.detect(in: cg) }.value
            guard let self, self.tool == .shape else { return }
            self.shapeState.detecting = false
            self.shapeState.detected = true
            self.shapeState.body = found.first
            if let body = found.first {
                if !self.shapeState.item.available(in: body),
                   let first = ShapeItem.allCases.first(where: { !$0.isAI && $0.available(in: body) }) {
                    self.shapeState.item = first
                    self.shapeState.group = first.group
                }
            } else if self.shapeState.mode == .preset || self.shapeState.mode == .shape {
                self.shapeState.error = "没有识别到人体。可以用带 AI 的，或者改用增高、瘦身、缩放。"
            }
            self.renderShape()
        }
    }

    // MARK: 滑块

    /// 当前滑块对应的数值。
    var shapeAmount: CGFloat {
        switch shapeState.mode {
        case .tall: return shapeState.talls.last?.amount ?? 0
        case .slim: return shapeState.boxes.last?.amount ?? 0
        case .zoom: return shapeState.spots.last?.amount ?? 0
        case .shape: return shapeState.values[shapeState.item]?[shapeState.side] ?? 0
        case .preset: return shapeState.presetStrength
        }
    }

    func setShapeAmount(_ raw: CGFloat) {
        let value = abs(raw) < 0.02 ? 0 : min(max(raw, -1), 1)
        switch shapeState.mode {
        case .tall:
            guard let i = shapeState.talls.indices.last else { return }
            shapeState.talls[i].amount = value
        case .slim:
            guard let i = shapeState.boxes.indices.last else { return }
            shapeState.boxes[i].amount = value
        case .zoom:
            guard let i = shapeState.spots.indices.last else { return }
            shapeState.spots[i].amount = value
        case .shape:
            var amount = shapeState.values[shapeState.item] ?? ShapeAmount()
            amount[shapeState.side] = value
            shapeState.values[shapeState.item] = amount.isZero ? nil : amount
        case .preset:
            shapeState.presetStrength = max(value, 0)
        }
        renderShape()
    }

    func selectShapeItem(_ item: ShapeItem) {
        if let preset = ShapeAI.preset(item) {
            startAIPreset(preset, group: .body)
            return
        }
        shapeState.item = item
        if !item.hasSides { shapeState.side = .both }
    }

    func selectShapePreset(_ id: String?) {
        shapeState.preset = id
        renderShape()
    }

    /// 撤掉最近的一步：还原笔的一笔、最后摆的那条带子 / 框 / 圈，或者当前这一项的数值。
    func shapeUndo() {
        if shapeState.restoring {
            if !shapeState.restore.isEmpty { shapeState.restore.removeLast() }
            renderShape()
            return
        }
        switch shapeState.mode {
        case .tall:
            if shapeState.talls.count > 1 { shapeState.talls.removeLast() }
            else if !shapeState.talls.isEmpty { shapeState.talls[0].amount = 0 }
        case .slim:
            if shapeState.boxes.count > 1 { shapeState.boxes.removeLast() }
            else if !shapeState.boxes.isEmpty { shapeState.boxes[0].amount = 0 }
        case .zoom:
            if shapeState.spots.count > 1 { shapeState.spots.removeLast() }
            else if !shapeState.spots.isEmpty { shapeState.spots[0].amount = 0 }
        case .shape:
            shapeState.values[shapeState.item] = nil
        case .preset:
            shapeState.preset = nil
        }
        renderShape()
    }

    /// 这一种做法里的修改全部还原。
    func shapeReset() {
        shapeState.restore = []
        switch shapeState.mode {
        case .tall: shapeState.talls = []
        case .slim: shapeState.boxes = []
        case .zoom: shapeState.spots = []
        case .shape: shapeState.values = [:]
        case .preset: shapeState.preset = nil
        }
        prepareShapeMode()
        renderShape()
    }

    // MARK: 辅助线

    /// 增高那两条线现在显示在哪里（变形之后的画面上的单位坐标）。
    var shapeTallGuide: (center: CGPoint, angle: CGFloat, halfGap: CGFloat)? {
        let resolved = shapeResolvedTalls()
        guard let band = resolved.bands.last else { return nil }
        guard band.amount != 0 else { return (band.center, band.angle, band.halfGap) }
        let map = ShapeTallMap(band, size: resolved.lastInput)
        let c = SIMD2(Float(band.center.x), Float(band.center.y))
        let a = map.output(c - map.n * Float(band.halfGap)), b = map.output(c + map.n * Float(band.halfGap))
        let mid = (a + b) / 2
        return (CGPoint(x: CGFloat(mid.x), y: CGFloat(mid.y)), band.angle, CGFloat(simd_length(b - a) / 2))
    }

    /// 开始拖辅助线。上一处已经调过数值的话，先把它定下来，在现在的画面上另起一处。
    func shapeGuideBegan() {
        shapeState.guideDragging = true
        switch shapeState.mode {
        case .tall:
            if let last = shapeState.talls.last, last.amount != 0, let guide = shapeTallGuide {
                shapeState.talls.append(ShapeTall(center: guide.center, angle: guide.angle, halfGap: guide.halfGap))
            }
        case .slim:
            if var last = shapeState.boxes.last, last.amount != 0 {
                last.amount = 0
                shapeState.boxes.append(last)
            }
        case .zoom:
            if var last = shapeState.spots.last, last.amount != 0 {
                last.amount = 0
                shapeState.spots.append(last)
            }
        default:
            break
        }
    }

    func shapeGuideEnded() {
        shapeState.guideDragging = false
    }

    func setShapeTall(center: CGPoint, angle: CGFloat, halfGap: CGFloat) {
        guard let i = shapeState.talls.indices.last else { return }
        let size = shapeOutputSize
        shapeState.talls[i].center = CGPoint(x: min(max(center.x, 0), size.width), y: min(max(center.y, 0), size.height))
        shapeState.talls[i].angle = angle
        shapeState.talls[i].halfGap = min(max(halfGap, 0.02), 1)
    }

    func setShapeBox(center: CGPoint, width: CGFloat, height: CGFloat, angle: CGFloat) {
        guard let i = shapeState.boxes.indices.last else { return }
        let size = shapeUnitSize
        shapeState.boxes[i].center = CGPoint(x: min(max(center.x, 0), size.width), y: min(max(center.y, 0), size.height))
        shapeState.boxes[i].width = min(max(width, 0.06), 1.5)
        shapeState.boxes[i].height = min(max(height, 0.06), 1.5)
        shapeState.boxes[i].angle = angle
    }

    func setShapeSpot(center: CGPoint, radius: CGFloat) {
        guard let i = shapeState.spots.indices.last else { return }
        let size = shapeUnitSize
        shapeState.spots[i].center = CGPoint(x: min(max(center.x, 0), size.width), y: min(max(center.y, 0), size.height))
        shapeState.spots[i].radius = min(max(radius, 0.03), 0.8)
    }

    // MARK: 背景保护 / 头部保护 / 变形还原

    /// 开关背景保护。第一次打开时在本机识别一次人像，并补一张"没有人的背景"。
    func setShapeProtect(_ on: Bool) {
        guard tool == .shape, !shapeState.protectBusy else { return }
        shapeState.error = nil
        guard on else {
            shapeState.protect = false
            renderShape()
            return
        }
        if shapeState.lockMask != nil {
            shapeState.protect = true
            renderShape()
            return
        }
        guard let cg = baseUIImage?.cgImage else { return }
        shapeState.protectBusy = true
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                // 让出来的缝现在直接用旁边的背景填，不再提前补一张"没有人的背景"。
                guard let mask = PersonSegmenter.mask(for: cg) else { return (nil, nil) }
                return (mask, nil)
            }.value
            guard let self, self.tool == .shape else { return }
            self.shapeState.protectBusy = false
            self.shapeState.lockMask = found.0
            self.shapeState.plate = found.1
            self.shapeState.protect = found.0 != nil
            if found.0 == nil { self.shapeState.error = "这张图里没有识别到人物，没法保护背景。" }
            self.renderShape()
        }
    }

    /// AI 补背景：让 AI 把人从照片里去掉、补出后面的背景（计一次费），之后人让出来的地方都用它。
    /// 关掉就回到本机的做法（拉旁边的背景）。补好的背景留着，再打开不用重新花钱。
    func setShapeAIFill(_ on: Bool) {
        guard tool == .shape, !shapeState.aiFillBusy else { return }
        shapeState.error = nil
        guard on else {
            shapeState.aiFill = false
            renderShape()
            return
        }
        // 先确保背景保护开着（要用到人像蒙版）。
        if !shapeState.protect || shapeState.lockMask == nil {
            if shapeState.lockMask == nil {
                setShapeProtect(true)
                Task { [weak self] in
                    while let self, self.shapeState.protectBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
                    guard let self, self.tool == .shape, self.shapeState.lockMask != nil else { return }
                    self.setShapeAIFill(true)
                }
                return
            }
            shapeState.protect = true
        }
        if shapeState.aiPlate != nil {
            shapeState.aiFill = true
            renderShape()
            return
        }
        guard let base = basePreview else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            shapeState.error = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        shapeState.aiFillBusy = true
        Task { [weak self] in
            var plate: CGImage?
            var failure: String?
            do {
                _ = AIClient.takeLastUsage()
                plate = try await AIRunner.run(endpoint: endpoint, prompt: Self.shapeFillPrompt, proxy: base, ops: [],
                                               strokes: [], appendGuidance: false)
                if let cost = AIClient.takeLastUsage()?.cost { AISettings.shared.addSpend(cost) }
            } catch {
                failure = error.localizedDescription
            }
            guard let self, self.tool == .shape else { return }
            self.shapeState.aiFillBusy = false
            if let plate {
                self.shapeState.aiPlate = plate
                self.shapeState.aiFill = true
            } else {
                self.shapeState.error = failure ?? "AI 没有补出背景，可以再试一次。"
            }
            self.renderShape()
        }
    }

    static let shapeFillPrompt = """
    Remove every person from this photo completely, including their hair, clothes, shadows and anything they are holding. \
    Fill the area where they were with the background that would naturally be behind them: continue the walls, floor, \
    railings, buildings, lights and textures with the same perspective, lighting, color and sharpness as the rest of the photo. \
    Do not add any new people or objects. Keep every other part of the photo exactly the same, same framing and size.
    """

    /// 增高时的头部保护：拉伸区域盖到头的时候，头这一段不跟着拉长。
    func setShapeHeadProtect(_ on: Bool) {
        guard tool == .shape, !shapeState.headBusy else { return }
        shapeState.error = nil
        guard on else {
            shapeState.headProtect = false
            renderShape()
            return
        }
        if shapeState.headSearched {
            shapeState.headProtect = shapeState.headBox != nil
            if shapeState.headBox == nil { shapeState.error = "没有识别到头部。" }
            renderShape()
            return
        }
        guard let cg = baseUIImage?.cgImage else { return }
        let unit = shapeUnitSize
        shapeState.headBusy = true
        Task { [weak self] in
            let box = await Task.detached(priority: .userInitiated) { () -> CGRect? in
                if let face = FaceDetector.detect(in: cg).first {
                    // 人脸框只到眉毛上面一点，往上、往两边放大到包住整个头和头发。
                    let b = face.box
                    let r = CGRect(x: b.minX - b.width * 0.35, y: b.minY - b.height * 0.65,
                                   width: b.width * 1.7, height: b.height * 1.85)
                    return CGRect(x: r.minX * unit.width, y: r.minY * unit.height,
                                  width: r.width * unit.width, height: r.height * unit.height)
                }
                if let body = ShapeBodyDetector.detect(in: cg).first, let head = body.head {
                    let r = body.headRadius * 1.3
                    return CGRect(x: head.x - r, y: head.y - r, width: r * 2, height: r * 2)
                }
                return nil
            }.value
            guard let self, self.tool == .shape else { return }
            self.shapeState.headBusy = false
            self.shapeState.headSearched = true
            self.shapeState.headBox = box
            self.shapeState.headProtect = box != nil
            if box == nil { self.shapeState.error = "没有识别到头部。" }
            self.renderShape()
        }
    }

    func setShapeRestoring(_ on: Bool) {
        shapeState.restoring = on && shapeState.mode != .tall
    }

    /// 变形还原：手指落下。point 是画面上的单位坐标。
    func shapeRestoreBegan(at point: CGPoint) {
        guard shapeState.restoring else { return }
        shapeState.restore.append(ShapeRestoreStroke(points: [point], radius: shapeState.restoreBrush))
        renderShape()
    }

    func shapeRestoreMoved(to point: CGPoint) {
        guard shapeState.restoring, let i = shapeState.restore.indices.last,
              let last = shapeState.restore[i].points.last else { return }
        // 挪得太近的点不记，免得一笔里攒下几千个点。
        guard hypot(point.x - last.x, point.y - last.y) > shapeState.restoreBrush * 0.15 else { return }
        shapeState.restore[i].points.append(point)
        renderShape()
    }
}
