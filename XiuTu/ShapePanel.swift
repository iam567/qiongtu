import SwiftUI

// MARK: - 画布

/// 美体塑形时的画布：显示当前效果，并在上面画可以拖动的辅助线 / 框 / 圆。
struct ShapeCanvas: View {
    @Bindable var model: EditorModel

    @State private var drawing = false

    private static let space = "shapeCanvas"

    var body: some View {
        GeometryReader { geo in
            let image = model.shownImage
            let box = CGSize(width: max(geo.size.width - 24, 1), height: max(geo.size.height - 24, 1))
            let fitted = aspectFit(image?.size ?? CGSize(width: 1, height: 1), in: box)
            let out = model.shapeOutputSize
            // 一个单位坐标（原图长边）在屏幕上是多少点。
            let ppu = out.width > 0 ? fitted.width / out.width : 1
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                }
                if !model.comparing, !model.isBusy, !model.isLoading, ppu > 0 {
                    guides(ppu: ppu, fitted: fitted)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .coordinateSpace(name: Self.space)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .overlay(alignment: .bottomTrailing) { compareButton }
    }

    @ViewBuilder
    private func guides(ppu: CGFloat, fitted: CGSize) -> some View {
        let state = model.shapeState
        if state.restoring {
            // 变形还原：手指涂过的地方回到原样。
            Color.white.opacity(0.001)
                .frame(width: fitted.width, height: fitted.height)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                        .onChanged { value in
                            let p = CGPoint(x: value.location.x / ppu, y: value.location.y / ppu)
                            if drawing {
                                model.shapeRestoreMoved(to: p)
                            } else {
                                drawing = true
                                model.shapeRestoreBegan(at: p)
                            }
                        }
                        .onEnded { _ in drawing = false }
                )
        } else {
            switch state.mode {
            case .tall:
                if let guide = model.shapeTallGuide {
                    ShapeTallGuide(model: model, center: guide.center, angle: guide.angle, halfGap: guide.halfGap,
                                   ppu: ppu, fitted: fitted, space: Self.space)
                }
            case .slim:
                if let box = state.boxes.last {
                    ShapeBoxGuide(model: model, box: box, ppu: ppu, fitted: fitted, space: Self.space)
                }
            case .zoom:
                if let spot = state.spots.last {
                    ShapeSpotGuide(model: model, spot: spot, ppu: ppu, fitted: fitted, space: Self.space)
                }
            case .preset, .shape:
                EmptyView()
            }
        }
    }

    /// 按住看修改前的样子。
    private var compareButton: some View {
        Image(systemName: "square.split.2x1")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Color.black.opacity(0.55), in: Circle())
            .padding(12)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.comparing { model.comparing = true } }
                    .onEnded { _ in model.comparing = false }
            )
            .opacity(model.isLoading ? 0 : 1)
    }
}

/// 辅助线上的圆形手柄。
private struct ShapeKnob: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 30, height: 30)
            .background(Color.white, in: Circle())
            .shadow(color: .black.opacity(0.35), radius: 2)
            .contentShape(Circle().inset(by: -10))
    }
}

/// 辅助线几何用的小工具：点加上"某个方向走多远"、点乘一个倍数、两点之差。
private extension CGPoint {
    func moved(_ direction: CGPoint, _ distance: CGFloat) -> CGPoint {
        CGPoint(x: x + direction.x * distance, y: y + direction.y * distance)
    }

    func scaled(_ k: CGFloat) -> CGPoint { CGPoint(x: x * k, y: y * k) }

    func minus(_ other: CGPoint) -> CGPoint { CGPoint(x: x - other.x, y: y - other.y) }
}

/// 增高：两条平行线框出拉伸区域。拖线上的 ↕ 调两条线的位置，拖带子中间整体移动，拖旋转手柄转方向。
private struct ShapeTallGuide: View {
    let model: EditorModel
    /// 都是单位坐标。
    let center: CGPoint
    let angle: CGFloat
    let halfGap: CGFloat
    let ppu: CGFloat
    let fitted: CGSize
    let space: String

    private struct Start {
        var center: CGPoint
        var angle: CGFloat
        var halfGap: CGFloat
    }

    @State private var start: Start?

    var body: some View {
        let c = center.scaled(ppu)
        let along = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: -sin(angle), y: cos(angle))
        let gap = halfGap * ppu
        let reach: CGFloat = 3000
        let a = c.moved(normal, -gap)
        let b = c.moved(normal, gap)
        let arm = min(max(fitted.width * 0.27, 60), 110)
        ZStack {
            if model.shapeState.guideDragging {
                // 拖的时候把拉伸区域以外压暗，一眼看清楚选的是哪一段。
                Path { p in
                    for (edge, side) in [(a, CGFloat(-1)), (b, CGFloat(1))] {
                        p.move(to: edge.moved(along, -reach))
                        p.addLine(to: edge.moved(along, reach))
                        p.addLine(to: edge.moved(along, reach).moved(normal, reach * side))
                        p.addLine(to: edge.moved(along, -reach).moved(normal, reach * side))
                        p.closeSubpath()
                    }
                }
                .fill(Color.black.opacity(0.45))
                .allowsHitTesting(false)
                Text("拉伸区域")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .rotationEffect(.radians(angle))
                    .position(c)
                    .allowsHitTesting(false)
            }
            // 带子中间：整体移动。
            Color.white.opacity(0.001)
                .frame(width: reach, height: max(gap * 2 - 28, 12))
                .rotationEffect(.radians(angle))
                .gesture(drag { s, value in
                    let moved = CGPoint(x: s.center.x + value.translation.width / ppu,
                                        y: s.center.y + value.translation.height / ppu)
                    model.setShapeTall(center: moved, angle: s.angle, halfGap: s.halfGap)
                })
                .position(c)
            Path { p in
                p.move(to: a.moved(along, -reach))
                p.addLine(to: a.moved(along, reach))
                p.move(to: b.moved(along, -reach))
                p.addLine(to: b.moved(along, reach))
            }
            .stroke(Color.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .allowsHitTesting(false)
            ShapeKnob(symbol: "arrow.up.and.down")
                .rotationEffect(.radians(angle))
                .gesture(drag { s, value in moveLine(s, value, first: true) })
                .position(a)
            ShapeKnob(symbol: "arrow.up.and.down")
                .rotationEffect(.radians(angle))
                .gesture(drag { s, value in moveLine(s, value, first: false) })
                .position(b)
            ShapeKnob(symbol: "arrow.triangle.2.circlepath")
                .gesture(drag { s, value in
                    // 手柄在第二条线上、离中心 arm 远的地方：按手指相对中心的方向反推线的角度。
                    let v = value.location.minus(s.center.scaled(ppu))
                    let turned = atan2(v.y, v.x) - atan2(s.halfGap * ppu, arm)
                    model.setShapeTall(center: s.center, angle: turned, halfGap: s.halfGap)
                })
                .position(b.moved(along, arm))
        }
        .frame(width: fitted.width, height: fitted.height)
    }

    /// 拖其中一条线：另一条不动。
    private func moveLine(_ s: Start, _ value: DragGesture.Value, first: Bool) {
        let normal = CGPoint(x: -sin(s.angle), y: cos(s.angle))
        let d = (value.translation.width * normal.x + value.translation.height * normal.y) / ppu
        let gap = s.halfGap + (first ? -d : d) / 2
        guard gap >= 0.02 else { return }
        model.setShapeTall(center: s.center.moved(normal, d / 2), angle: s.angle, halfGap: gap)
    }

    private func drag(_ update: @escaping (Start, DragGesture.Value) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if start == nil {
                    model.shapeGuideBegan()
                    if let g = model.shapeTallGuide {
                        start = Start(center: g.center, angle: g.angle, halfGap: g.halfGap)
                    }
                }
                guard let start else { return }
                update(start, value)
            }
            .onEnded { _ in
                start = nil
                model.shapeGuideEnded()
            }
    }
}

/// 瘦身：带两条弧线的框。拖框里面移动；右边、下边的小条改宽和高；右下角的手柄旋转并整体缩放。
private struct ShapeBoxGuide: View {
    let model: EditorModel
    let box: ShapeBox
    let ppu: CGFloat
    let fitted: CGSize
    let space: String

    @State private var start: ShapeBox?

    var body: some View {
        let w = box.width * ppu, h = box.height * ppu
        ZStack {
            ZStack {
                Rectangle().stroke(Color.white, lineWidth: 1.5)
                // 两条往里弯的弧线：中段离中线大约三分之一个框宽，瘦身就是沿这个形状往里收。
                Path { p in
                    for side in [CGFloat(-1), 1] {
                        p.move(to: CGPoint(x: w / 2 + side * w * 0.42, y: h * 0.05))
                        p.addQuadCurve(to: CGPoint(x: w / 2 + side * w * 0.42, y: h * 0.95),
                                       control: CGPoint(x: w / 2 + side * w * 0.24, y: h * 0.5))
                    }
                }
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            .shadow(color: .black.opacity(0.5), radius: 1)
            .frame(width: w, height: h)
            .contentShape(Rectangle())
            .gesture(drag { s, value in
                let moved = CGPoint(x: s.center.x + value.translation.width / ppu,
                                    y: s.center.y + value.translation.height / ppu)
                model.setShapeBox(center: moved, width: s.width, height: s.height, angle: s.angle)
            })
            .overlay(alignment: .trailing) {
                pill(vertical: true)
                    .offset(x: 15)
                    .gesture(drag { s, value in
                        let v = value.location.minus(s.center.scaled(ppu))
                        let half = abs(v.x * cos(s.angle) + v.y * sin(s.angle))
                        model.setShapeBox(center: s.center, width: half * 2 / ppu, height: s.height, angle: s.angle)
                    })
            }
            .overlay(alignment: .bottom) {
                pill(vertical: false)
                    .offset(y: 15)
                    .gesture(drag { s, value in
                        let v = value.location.minus(s.center.scaled(ppu))
                        let half = abs(-v.x * sin(s.angle) + v.y * cos(s.angle))
                        model.setShapeBox(center: s.center, width: s.width, height: half * 2 / ppu, angle: s.angle)
                    })
            }
            .overlay(alignment: .bottomTrailing) {
                ShapeKnob(symbol: "arrow.triangle.2.circlepath")
                    .offset(x: 15, y: 15)
                    .gesture(drag { s, value in
                        let c = s.center.scaled(ppu)
                        let from = value.startLocation.minus(c)
                        let to = value.location.minus(c)
                        let k = max(hypot(to.x, to.y), 1) / max(hypot(from.x, from.y), 1)
                        model.setShapeBox(center: s.center, width: s.width * k, height: s.height * k,
                                          angle: s.angle + atan2(to.y, to.x) - atan2(from.y, from.x))
                    })
            }
            .rotationEffect(.radians(box.angle))
            .position(box.center.scaled(ppu))
        }
        .frame(width: fitted.width, height: fitted.height)
    }

    private func pill(vertical: Bool) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: vertical ? 6 : 30, height: vertical ? 30 : 6)
            .shadow(color: .black.opacity(0.35), radius: 2)
            .padding(12)
            .contentShape(Rectangle())
    }

    private func drag(_ update: @escaping (ShapeBox, DragGesture.Value) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if start == nil {
                    model.shapeGuideBegan()
                    start = model.shapeState.boxes.last
                }
                guard let start else { return }
                update(start, value)
            }
            .onEnded { _ in
                start = nil
                model.shapeGuideEnded()
            }
    }
}

/// 缩放：一个圆圈。拖圈里面移动，拖圈上的手柄改大小。
private struct ShapeSpotGuide: View {
    let model: EditorModel
    let spot: ShapeSpot
    let ppu: CGFloat
    let fitted: CGSize
    let space: String

    @State private var start: ShapeSpot?

    var body: some View {
        let c = spot.center.scaled(ppu)
        let r = spot.radius * ppu
        ZStack {
            Circle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .shadow(color: .black.opacity(0.5), radius: 1)
                .frame(width: r * 2, height: r * 2)
                .contentShape(Circle())
                .gesture(drag { s, value in
                    let moved = CGPoint(x: s.center.x + value.translation.width / ppu,
                                        y: s.center.y + value.translation.height / ppu)
                    model.setShapeSpot(center: moved, radius: s.radius)
                })
                .position(c)
            ShapeKnob(symbol: "arrow.up.left.and.arrow.down.right")
                .gesture(drag { s, value in
                    let v = value.location.minus(s.center.scaled(ppu))
                    model.setShapeSpot(center: s.center, radius: hypot(v.x, v.y) / ppu)
                })
                .position(x: c.x + r * 0.7071, y: c.y + r * 0.7071)
        }
        .frame(width: fitted.width, height: fitted.height)
    }

    private func drag(_ update: @escaping (ShapeSpot, DragGesture.Value) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
            .onChanged { value in
                if start == nil {
                    model.shapeGuideBegan()
                    start = model.shapeState.spots.last
                }
                guard let start else { return }
                update(start, value)
            }
            .onEnded { _ in
                start = nil
                model.shapeGuideEnded()
            }
    }
}

// MARK: - 面板

/// 美体塑形面板：顶上切换做法，中间是保护开关和滑块，下面是预设或各部位。
struct ShapePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.shapeState
        VStack(spacing: 10) {
            // Mac：五种做法都在左边的工具栏里选。
            if !Platform.isMac {
                SegmentBar(items: ShapeMode.allCases, selected: state.mode, title: { $0.short }) {
                    model.switchShapeMode($0)
                }
            }
            options
            slider
            switch state.mode {
            case .preset: presets
            case .shape: items
            case .tall, .slim, .zoom: EmptyView()
            }
            if state.detecting, state.mode == .preset || state.mode == .shape {
                HStack(spacing: 8) {
                    ProgressView().tint(.white)
                    Text("正在识别人体…").font(.system(size: 13))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = state.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 塑形和一键美体要先认出人来。
    private var needsBody: Bool {
        (model.shapeState.mode == .preset || model.shapeState.mode == .shape) && model.shapeState.body == nil
    }

    @ViewBuilder
    private var options: some View {
        let state = model.shapeState
        if Platform.isMac, state.mode != .tall {
            // Mac：面板窄，分两行。
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    protectChip(state, symbols: true)
                    fillChip(state, symbols: true)
                }
                HStack(spacing: 8) {
                    restoreChip(state, symbols: true)
                    Spacer(minLength: 0)
                    roundButton("arrow.uturn.backward") { model.shapeUndo() }
                    roundButton("arrow.counterclockwise") { model.shapeReset() }
                }
            }
        } else {
            HStack(spacing: 8) {
                if state.mode == .tall {
                    Chip(title: "头部保护", symbol: state.headBusy ? "hourglass" : "person.crop.circle",
                         selected: state.headProtect) { model.setShapeHeadProtect(!state.headProtect) }
                } else {
                    // 手机上一排放三个开关，不带小图标才放得下。
                    protectChip(state, symbols: false)
                    fillChip(state, symbols: false)
                    restoreChip(state, symbols: false)
                }
                Spacer(minLength: 0)
                roundButton("arrow.uturn.backward") { model.shapeUndo() }
                roundButton("arrow.counterclockwise") { model.shapeReset() }
            }
        }
    }

    private func protectChip(_ state: ShapeState, symbols: Bool) -> some View {
        Chip(title: "背景保护", symbol: state.protectBusy ? "hourglass" : (symbols ? "person.and.background.dotted" : nil),
             selected: state.protect) {
            if state.protect { model.setShapeAIFill(false) }
            model.setShapeProtect(!state.protect)
        }
    }

    /// AI 补背景：打开时让 AI 补一张没有人的背景（计一次费），人让出来的地方用它。
    private func fillChip(_ state: ShapeState, symbols: Bool) -> some View {
        Chip(title: "补背景", symbol: state.aiFillBusy ? "hourglass" : (symbols ? "sparkles" : nil),
             selected: state.aiFill && state.protect, badge: "AI") {
            model.setShapeAIFill(!(state.aiFill && state.protect))
        }
    }

    private func restoreChip(_ state: ShapeState, symbols: Bool) -> some View {
        Chip(title: "变形还原", symbol: symbols ? "bandage" : nil, selected: state.restoring) {
            model.setShapeRestoring(!state.restoring)
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var slider: some View {
        let state = model.shapeState
        if state.restoring {
            HStack(spacing: 12) {
                Text("笔刷")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { Double(state.restoreBrush) },
                                      set: { model.shapeState.restoreBrush = CGFloat($0) }), in: 0.02...0.15)
            }
        } else {
            let value = model.shapeAmount
            let single = state.mode == .preset
            HStack(spacing: 12) {
                Text("\(Int((value * 100).rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .leading)
                Slider(value: Binding(get: { Double(value) }, set: { model.setShapeAmount(CGFloat($0)) }),
                       in: single ? 0...1 : -1...1)
                if state.mode == .shape, state.item.hasSides {
                    Menu {
                        ForEach(ShapeSide.allCases) { side in
                            Button {
                                model.shapeState.side = side
                            } label: {
                                if state.side == side {
                                    Label(side.title, systemImage: "checkmark")
                                } else {
                                    Text(side.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(state.side.title)
                            Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(Capsule().stroke(Color.white.opacity(0.7), lineWidth: 1))
                    }
                }
            }
            .disabled(needsBody || (single && state.preset == nil))
            .opacity(needsBody || (single && state.preset == nil) ? 0.35 : 1)
        }
    }

    /// 一键美体：本机的两套 + 交给 AI 的几套。
    private var presets: some View {
        let state = model.shapeState
        return HScroll {
            HRow(alignment: .top, spacing: 4) {
                FeatureTile(symbol: "photo", title: "原图", selected: state.preset == nil) {
                    model.selectShapePreset(nil)
                }
                ForEach(ShapePreset.all) { preset in
                    FeatureTile(symbol: preset.title == "超模" ? "figure.walk" : "figure.stand", title: preset.title,
                                selected: state.preset == preset.id) {
                        model.selectShapePreset(preset.id)
                    }
                    .disabled(state.body == nil)
                    .opacity(state.body == nil ? 0.35 : 1)
                }
                GenderToggle()
                    .padding(.top, 14)
                    .padding(.horizontal, 4)
                ForEach(GenderSetting.shared.isMale ? MalePresets.shapeLooks : ShapeAI.looks) { look in
                    FeatureTile(symbol: look.symbol, title: look.title, badge: "AI") {
                        model.startAIPreset(look, group: .body)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .padding(.horizontal, -16)
    }

    /// 塑形：上面一排部位，下面是这个部位能调的各项。
    private var items: some View {
        let state = model.shapeState
        return VStack(spacing: 8) {
            HScroll {
                HRow(spacing: 8) {
                    ForEach(ShapeGroup.allCases) { group in
                        Chip(title: group.title, selected: state.group == group) {
                            model.shapeState.group = group
                            if let body = state.body,
                               let first = group.items.first(where: { !$0.isAI && $0.available(in: body) }) {
                                model.selectShapeItem(first)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            HScroll {
                HRow(spacing: 6) {
                    ForEach(tiles(state)) { item in
                        let usable = item.isAI || (state.body.map { item.available(in: $0) } ?? false)
                        IconTile(symbol: item.symbol, title: item.title,
                                 selected: !item.isAI && state.item == item,
                                 badge: item.isAI ? "AI" : nil,
                                 modified: !(state.values[item]?.isZero ?? true)) {
                            model.selectShapeItem(item)
                        }
                        .disabled(!usable)
                        .opacity(usable ? 1 : 0.35)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            .id(state.group)
        }
    }

    /// 这个部位的各项。认不出人体、本机的项用不了时，AI 的排在前面。
    private func tiles(_ state: ShapeState) -> [ShapeItem] {
        let all = state.group.items
        guard state.detected, state.body == nil else { return all }
        return all.filter(\.isAI) + all.filter { !$0.isAI }
    }
}

/// 美体塑形时底部确认栏（✕ 和 ✓ 之间）显示的内容。
struct ShapeTitle: View {
    @Bindable var model: EditorModel

    var body: some View {
        Text(model.shapeState.mode.title).font(.system(size: 15, weight: .semibold))
    }
}
