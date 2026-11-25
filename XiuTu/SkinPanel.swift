import SwiftUI

/// 皮肤面板：上面一行是当前项目的滑块（或画笔的大小、力度），下面一行是这一类里的各个项目。
struct SkinPanel: View {
    @Bindable var model: EditorModel

    private static let warning = Color(red: 1, green: 0.45, blue: 0.4)

    var body: some View {
        let state = model.skinState
        VStack(spacing: 10) {
            if state.detecting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在找人脸…").font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else {
                if state.params.faces.isEmpty, errorText(state) != nil {
                    FaceRescue(model: model, message: "这张图里没有找到人脸")
                } else if let message = errorText(state) {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Self.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if state.params.faces.count > 1 { facePicker(state) }
                controls(state)
                tiles(state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// 只在真的用不了的时候说明原因。
    private func errorText(_ state: SkinState) -> String? {
        switch state.item {
        case .heal, .conceal, .highlight, .shadow, .erase:
            return nil
        case .unify:
            return state.params.faces.isEmpty ? "这张图里没有找到人脸，没法统一肤色。" : nil
        case .key(let key):
            if state.params.faces.isEmpty { return "这张图里没有找到人脸，只有遮瑕笔、点痘和修容笔能用。" }
            return state.usable(key) ? nil : "这张脸的五官识别不清，这一项用不了。"
        }
    }

    private func facePicker(_ state: SkinState) -> some View {
        HScroll {
            HRow(spacing: 8) {
                ForEach(state.params.faces.indices, id: \.self) { index in
                    Chip(title: state.params.faces[index].isIdentity ? "第 \(index + 1) 张" : "第 \(index + 1) 张 ✓",
                         selected: state.faceIndex == index) { model.selectSkinFace(index) }
                }
                Chip(title: "看全图", selected: false) { model.focusRect = nil }
            }
        }
    }

    // MARK: 滑块 / 画笔

    @ViewBuilder
    private func controls(_ state: SkinState) -> some View {
        switch state.item {
        case .key(let key):
            VStack(spacing: 8) {
                if key == .white || key == .warmth || key == .rosy {
                    HScroll {
                        HRow(spacing: 8) {
                            ForEach(SkinTonePreset.all) { preset in
                                Chip(title: preset.title, selected: matches(preset, state)) { model.applySkinTone(preset) }
                            }
                        }
                    }
                    .disabled(state.face == nil)
                    .opacity(state.face == nil ? 0.35 : 1)
                }
                slider(value: state.value(key), range: key.bipolar ? -1...1 : 0...1, enabled: state.usable(key)) {
                    model.setSkin(key, $0)
                }
            }
        case .unify:
            HStack(spacing: 10) {
                slider(value: state.params.unify, range: 0...1, enabled: !state.params.faces.isEmpty) {
                    model.setSkinUnify($0)
                }
                if state.unifyBusy { ProgressView().tint(.white) }
            }
        case .heal:
            HStack(spacing: 10) {
                label("大小")
                Slider(value: Binding(get: { Double(state.healSize) }, set: { model.skinState.healSize = CGFloat($0) }), in: 0.03...0.14)
                strokeButtons(state)
            }
        case .conceal, .erase:
            HStack(spacing: 10) {
                label("大小")
                Slider(value: Binding(get: { Double(state.brush) }, set: { model.skinState.brush = CGFloat($0) }), in: 12...100)
                strokeButtons(state)
            }
        case .highlight, .shadow:
            HStack(spacing: 10) {
                label("大小")
                Slider(value: Binding(get: { Double(state.brush) }, set: { model.skinState.brush = CGFloat($0) }), in: 12...100)
                label("力度")
                Slider(value: Binding(get: { Double(state.strength) }, set: { model.skinState.strength = CGFloat($0) }), in: 0.2...1)
                strokeButtons(state)
            }
        }
    }

    private func matches(_ preset: SkinTonePreset, _ state: SkinState) -> Bool {
        guard state.face != nil else { return false }
        return abs(state.value(.white) - preset.white) < 0.005 && abs(state.value(.warmth) - preset.warmth) < 0.005
            && abs(state.value(.rosy) - preset.rosy) < 0.005
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.dim)
    }

    private func slider(value: CGFloat, range: ClosedRange<Double>, enabled: Bool, set: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: 12) {
            Text("\(Int((value * 100).rounded()))")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)
            Slider(value: Binding(get: { Double(value) }, set: { set(CGFloat($0)) }), in: range)
            Button { set(0) } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(value == 0 ? Theme.dim : Color.white)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private func strokeButtons(_ state: SkinState) -> some View {
        HStack(spacing: 6) {
            roundButton("arrow.uturn.backward") { model.undoSkinStroke() }
            roundButton("trash") { model.clearSkinStrokes() }
        }
        .disabled(!state.hasStrokes)
        .opacity(state.hasStrokes ? 1 : 0.35)
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

    // MARK: 项目

    private func tiles(_ state: SkinState) -> some View {
        HScroll {
            HRow(alignment: .top, spacing: 4) {
                switch state.tab {
                case .skin:
                    preset(.skin, state)
                    ForEach(SkinKey.keys(in: .skin)) { key in keyTile(key, state) }
                    IconTile(symbol: "bandage", title: "遮瑕笔", selected: state.item == .conceal,
                             modified: state.params.strokes.contains { $0.kind == .conceal && $0.points.count > 1 }) {
                        model.skinState.item = .conceal
                    }
                    IconTile(symbol: "figure.stand", title: "肤色统一", selected: state.item == .unify,
                             modified: state.params.unify > 0) {
                        model.skinState.item = .unify
                    }
                case .repair:
                    ForEach(SkinKey.keys(in: .repair)) { key in keyTile(key, state) }
                    IconTile(symbol: "hand.tap", title: "点痘", selected: state.item == .heal,
                             modified: state.params.strokes.contains { $0.kind == .conceal && $0.points.count == 1 }) {
                        model.skinState.item = .heal
                    }
                    IconTile(symbol: SkinAI.wrinkles.symbol, title: SkinAI.wrinkles.title, badge: "AI") {
                        model.startAIPreset(SkinAI.wrinkles, group: .fix)
                    }
                    IconTile(symbol: SkinAI.acne.symbol, title: SkinAI.acne.title, badge: "AI") {
                        model.startAIPreset(SkinAI.acne, group: .fix)
                    }
                case .plump:
                    preset(.plump, state)
                    ForEach(SkinKey.keys(in: .plump)) { key in regionTile(key, state) }
                case .lift:
                    preset(.lift, state)
                    ForEach(SkinKey.keys(in: .lift)) { key in regionTile(key, state) }
                case .eyes:
                    ForEach(SkinKey.keys(in: .eyes)) { key in keyTile(key, state) }
                case .brush:
                    IconTile(symbol: "sun.max", title: "高光", selected: state.item == .highlight,
                             modified: state.params.strokes.contains { $0.kind == .highlight }) {
                        model.skinState.item = .highlight
                    }
                    IconTile(symbol: "moon", title: "阴影", selected: state.item == .shadow,
                             modified: state.params.strokes.contains { $0.kind == .shadow }) {
                        model.skinState.item = .shadow
                    }
                    IconTile(symbol: "eraser", title: "橡皮", selected: state.item == .erase) {
                        model.skinState.item = .erase
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private func preset(_ preset: SkinPreset, _ state: SkinState) -> some View {
        let on = state.isOn(preset)
        return IconTile(symbol: on ? "checkmark.circle.fill" : preset.symbol, title: preset.title, selected: on) {
            model.toggleSkinPreset(preset)
        }
        .disabled(state.face == nil)
        .opacity(state.face == nil ? 0.35 : 1)
    }

    private func keyTile(_ key: SkinKey, _ state: SkinState) -> some View {
        IconTile(symbol: key.symbol, title: key.title, selected: state.item == .key(key), modified: state.value(key) != 0) {
            model.skinState.item = .key(key)
        }
        .opacity(state.usable(key) ? 1 : 0.35)
    }

    private func regionTile(_ key: SkinKey, _ state: SkinState) -> some View {
        let selected = state.item == .key(key)
        return Button { model.skinState.item = .key(key) } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    SkinRegionIcon(key: key, tint: selected ? Theme.accent : Color.white)
                        .frame(width: 44, height: 36)
                    if state.value(key) != 0 {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    }
                }
                Text(key.title).font(.system(size: 12))
            }
            .foregroundStyle(selected ? Theme.accent : Color.white)
            .frame(minWidth: 58)
        }
        .buttonStyle(.plain)
        .opacity(state.usable(key) ? 1 : 0.35)
    }
}

/// 丰盈 / 提拉各项的小图：一张简笔的脸，用虚线圈出这一项作用的位置。
struct SkinRegionIcon: View {
    let key: SkinKey
    var tint: Color = .white

    /// 每个区域：中心 (u, v) 和半径 (ru, rv)，以脸的半宽、半高为 1；mirrored = 左右各一个。
    private var regions: [(u: CGFloat, v: CGFloat, ru: CGFloat, rv: CGFloat, mirrored: Bool)] {
        switch key {
        case .plumpForehead, .liftForehead: return [(0, -0.62, 0.6, 0.22, false)]
        case .plumpTear: return [(0.36, 0.0, 0.24, 0.09, true)]
        case .plumpApple: return [(0.5, 0.2, 0.25, 0.17, true)]
        case .plumpCheek: return [(0.56, 0.5, 0.2, 0.22, true)]
        case .plumpNoseBase: return [(0.25, 0.3, 0.13, 0.1, true)]
        case .plumpTemple: return [(0.78, -0.3, 0.13, 0.2, true)]
        case .liftEye: return [(0.42, -0.12, 0.32, 0.19, true)]
        case .liftMid: return [(0.42, 0.24, 0.32, 0.2, true)]
        case .liftMouth: return [(0, 0.56, 0.42, 0.2, false)]
        default: return []
        }
    }

    var body: some View {
        Canvas { context, size in
            let cx = size.width / 2, cy = size.height / 2
            let hw = size.height * 0.38, hh = size.height * 0.47
            func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: cx + u * hw, y: cy + v * hh) }
            let line = GraphicsContext.Shading.color(tint.opacity(0.85))
            // 脸
            let face = Path(ellipseIn: CGRect(x: cx - hw, y: cy - hh, width: hw * 2, height: hh * 2))
            context.stroke(face, with: line, lineWidth: 1.2)
            // 眼睛、鼻子、嘴
            var features = Path()
            for s in [-1.0, 1.0] as [CGFloat] {
                features.move(to: point(s * 0.26, -0.12))
                features.addQuadCurve(to: point(s * 0.58, -0.12), control: point(s * 0.42, -0.2))
            }
            features.move(to: point(0, 0.0))
            features.addLine(to: point(-0.06, 0.26))
            features.addLine(to: point(0.06, 0.26))
            features.move(to: point(-0.22, 0.54))
            features.addQuadCurve(to: point(0.22, 0.54), control: point(0, 0.64))
            context.stroke(features, with: .color(tint.opacity(0.55)), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))

            let dash = StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [2.4, 2])
            let mark = GraphicsContext.Shading.color(Theme.accent)
            if key == .liftContour {
                // 下颌线：沿着脸的下半圈。
                var jaw = Path()
                for step in 0...14 {
                    let a = (20 + CGFloat(step) * 10) * .pi / 180
                    let p = CGPoint(x: cx + cos(a) * hw * 1.14, y: cy + sin(a) * hh * 1.12)
                    if step == 0 { jaw.move(to: p) } else { jaw.addLine(to: p) }
                }
                context.stroke(jaw, with: mark, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2.6, 2.2]))
            }
            for r in regions {
                for s in (r.mirrored ? [-1.0, 1.0] : [1.0]) as [CGFloat] {
                    let c = point(r.u * s, r.v)
                    let oval = Path(ellipseIn: CGRect(x: c.x - r.ru * hw, y: c.y - r.rv * hh, width: r.ru * hw * 2, height: r.rv * hh * 2))
                    context.fill(oval, with: .color(Theme.accent.opacity(0.3)))
                    context.stroke(oval, with: mark, style: dash)
                }
            }
        }
    }
}

/// 皮肤时底部确认栏（✕ 和 ✓ 之间）显示的内容：一排分类标签，放不下可以左右滑。
struct SkinTitle: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            HScroll {
                HRow(spacing: 20) {
                    ForEach(SkinTab.allCases) { tab in
                        let on = model.skinState.tab == tab
                        Button {
                            model.selectSkinTab(tab)
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab.id, anchor: .center) }
                        } label: {
                            VStack(spacing: 5) {
                                Text(tab.title)
                                    .font(.system(size: 15, weight: on ? .bold : .regular))
                                    .foregroundStyle(on ? Color.white : Theme.dim)
                                Capsule()
                                    .fill(on ? Theme.accent : Color.clear)
                                    .frame(width: 18, height: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(tab.id)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(height: 44)
    }
}
