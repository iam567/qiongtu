import SwiftUI

/// 美体面板顶上的两种做法：AI 美体（发给服务商）和手动美体（本机推拉）。
/// 换过去之前，这边已经做出来的修改会先保留成一步。
struct BodyModeChips: View {
    let model: EditorModel

    var body: some View {
        let manual = model.tool == .liquify
        HStack(spacing: 8) {
            Chip(title: "AI 美体", symbol: "sparkles", selected: !manual) { model.switchBody(manual: false) }
            Chip(title: "手动美体", symbol: "hand.draw", selected: manual) { model.switchBody(manual: true) }
        }
        .disabled(model.aiRunning)
        .opacity(model.aiRunning ? 0.4 : 1)
    }
}

/// 色块按钮：一个圆角色块，名字在下面（染发的颜色用）。
struct ColorTile: View {
    let hex: UInt32
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: [color(1.18), color(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 1))
                    .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: 5, y: -4) }
                Text(title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64)
        }
        .buttonStyle(PressStyle())
    }

    /// k > 1 提亮，k < 1 压暗：色块做成一点渐变，看起来像头发的光泽。
    private func color(_ k: Double) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255, g = Double((hex >> 8) & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        return Color(red: min(r * k, 1), green: min(g * k, 1), blue: min(b * k, 1))
    }
}

/// AI 修图面板：点一个功能就开始；想只改局部，先在图上涂抹。
/// "AI 美体"也用这个面板，只是顶上换成美体的两种做法。
struct AIPanel: View {
    @Bindable var model: EditorModel
    var editPrompt: () -> Void
    var openSettings: () -> Void

    private let settings = AISettings.shared
    @State private var creativeKind: CreativeKind = .comic

    var body: some View {
        VStack(spacing: 10) {
            header
            // 出错放在最上面：下面的格子多，放底下会被挤到看不见。
            AIErrorView(model: model)
            if !settings.isConfigured(settings.active) {
                needsKey
            } else if model.aiRunning {
                running
            } else if model.aiHasResult {
                result
            } else {
                compose
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.aiGroup == .body {
                BodyModeChips(model: model)
                Spacer(minLength: 0)
                ProviderMenu(openSettings: openSettings, compact: true)
            } else if Platform.isMac {
                // Mac：分组都在左边的工具栏里，这里不再重复，只留选服务商。
                Spacer(minLength: 0)
                ProviderMenu(openSettings: openSettings, compact: true)
            } else if model.aiGroup.isHair {
                SegmentBar(items: AIPresetGroup.hairGroups, selected: model.aiGroup,
                           title: { $0.title }, symbol: { $0.symbol }) { model.aiGroup = $0 }
                ProviderMenu(openSettings: openSettings, compact: true)
            } else {
                SegmentBar(items: AIPresetGroup.editGroups, selected: model.aiGroup,
                           title: { $0.title }, symbol: { $0.symbol }, scrolls: true) { model.aiGroup = $0 }
                ProviderMenu(openSettings: openSettings, iconOnly: true)
            }
        }
    }

    private var needsKey: some View {
        VStack(spacing: 10) {
            Text("还没有设置 \(settings.active.shortTitle) 的 API Key")
                .font(.system(size: 14))
            Button(action: openSettings) {
                Text("去设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    /// 点一个功能就直接开始。需要补充内容的（比如"换背景"）先弹出输入框，写完自动开始。
    @ViewBuilder
    private var compose: some View {
        if model.aiGroup == .outfit {
            if model.outfitPatch {
                patch
            } else {
                OutfitPanel(model: model, custom: custom)
            }
        } else {
            tiles
        }
    }

    /// 换衣服没换干净：涂抹，再点"补换"。
    private var patch: some View {
        VStack(spacing: 12) {
            brushRow
            HStack(spacing: 10) {
                Button { model.outfitPatch = false } label: {
                    Label("返回", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 42)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                Button { model.runOutfitPatch() } label: {
                    Text("补换涂抹的地方")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(model.aiStrokes.isEmpty ? Theme.accent.opacity(0.35) : Theme.accent, in: Theme.buttonShape)
                        .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tiles: some View {
        let master = model.aiGroup.usesTonePreview
        let pictures = master || model.aiGroup == .hairStyle
        return VStack(spacing: 10) {
            if model.aiGroup == .creative {
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(CreativeKind.allCases) { kind in
                            Chip(title: kind.title, symbol: kind.symbol, selected: creativeKind == kind) { creativeKind = kind }
                        }
                    }
                }
            }
            if [.body, .hairStyle, .hairColor, .hairCare].contains(model.aiGroup) {
                HStack(spacing: 8) {
                    GenderToggle()
                    Spacer(minLength: 0)
                }
            }
            if model.aiGroup == .master {
                HStack(spacing: 8) {
                    Chip(title: "大师构图", symbol: "viewfinder", selected: model.aiMasterCompose) { model.aiMasterCompose = true }
                    Chip(title: "原构图", symbol: "rectangle", selected: !model.aiMasterCompose) { model.aiMasterCompose = false }
                    Spacer(minLength: 0)
                }
            }
            if model.aiGroup == .compose {
                // 构图可以换画幅：横图改竖图、竖图改横图。
                HStack(spacing: 8) {
                    ForEach(AIReframe.allCases) { item in
                        Chip(title: item.title, symbol: item.symbol, selected: model.aiReframe == item) { model.aiReframe = item }
                    }
                    Spacer(minLength: 0)
                }
            }
            HScroll {
                HRow(alignment: .top, spacing: pictures ? 10 : 4) {
                    if model.aiGroup == .compose {
                        FeatureTile(symbol: Tool.smartCrop.symbol, title: Tool.smartCrop.title, badge: "AI") {
                            model.commitTool { model.begin(.smartCrop) }
                        }
                    }
                    ForEach(presets) { preset in
                        if model.aiGroup == .creative, model.masterThumbs[preset.title] == nil {
                            CreativeArtTile(title: preset.title, symbol: preset.symbol, kind: creativeKind) { start(preset) }
                        } else if master {
                            ImageTile(title: preset.title, image: model.masterThumbs[preset.title],
                                      symbol: model.aiGroup.symbol, badge: "AI") { start(preset) }
                        } else if let tint = preset.tint {
                            ColorTile(hex: tint, title: preset.title) { start(preset) }
                        } else if model.aiGroup == .hairStyle {
                            ImageTile(title: preset.title, image: Self.hairThumb(preset.title),
                                      symbol: preset.symbol, badge: "AI") { start(preset) }
                        } else {
                            FeatureTile(symbol: preset.symbol, title: preset.title, badge: "AI") { start(preset) }
                        }
                    }
                    if pictures {
                        ImageTile(title: "自己写", image: nil, symbol: "square.and.pencil", badge: "AI", action: custom)
                    } else {
                        FeatureTile(symbol: "square.and.pencil", title: "自己写", badge: "AI", action: custom)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, -16)
            .id(model.aiGroup == .creative ? "creative-" + creativeKind.rawValue : model.aiGroup.rawValue)
            brushRow
        }
        .task(id: model.aiGroup) {
            if model.aiGroup.usesTonePreview { model.prepareMasterThumbs() }
        }
    }

    private var brushRow: some View {
            HStack(spacing: 10) {
                Text("涂抹")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { Double(model.aiBrush) }, set: { model.aiBrush = CGFloat($0) }), in: 14...100)
                smallButton("eraser", active: model.aiErasing) { model.aiErasing.toggle() }
                smallButton("arrow.uturn.backward", active: false) { model.undoStroke() }
                    .opacity(model.aiStrokes.isEmpty ? 0.35 : 1)
                smallButton("trash", active: false) { model.clearAIRegion() }
                    .opacity(model.aiStrokes.isEmpty ? 0.35 : 1)
            }
    }

    private var presets: [AIPreset] {
        switch model.aiGroup {
        case .creative: return creativeKind.presets
        default: return model.aiGroup.presets
        }
    }

    /// 发型小图画一次就记住。
    private static var hairThumbs: [String: UIImage] = [:]

    private static func hairThumb(_ title: String) -> UIImage? {
        if let hit = hairThumbs[title] { return hit }
        guard let cg = HairArt.image(for: title) else { return nil }
        let image = UIImage(cgImage: cg, scale: 2, orientation: .up)
        hairThumbs[title] = image
        return image
    }

    private func start(_ preset: AIPreset) {
        model.aiError = nil
        model.aiPrompt = preset.prompt
        model.aiPresetTitle = preset.title
        model.aiFaceCrop = preset.faceCrop
        model.aiHairCrop = preset.hairCrop
        model.aiToneOnly = preset.toneOnly
        model.aiPart = preset.part
        if preset.prompt.hasSuffix("：") { editPrompt() } else { model.runAI() }
    }

    private func custom() {
        model.aiError = nil
        model.aiPrompt = ""
        model.aiPresetTitle = ""
        model.aiFaceCrop = false
        model.aiHairCrop = model.aiGroup.isHair
        model.aiToneOnly = false
        model.aiPart = nil
        editPrompt()
    }

    private var running: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.white)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(model.aiStarted)))
                Text("\(settings.active.shortTitle) 正在处理… \(seconds) 秒")
                    .font(.system(size: 14))
                    .monospacedDigit()
            }
            Spacer()
            Button("取消") { model.cancelAI() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 22)
    }

    private var result: some View {
        VStack(spacing: 10) {
            if let usage = model.aiUsageText {
                Text(usage)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 改形状的（美体、美发）没有"只取光影"这回事。
            if !model.aiGroup.isHair, model.aiGroup != .body, model.aiGroup != .creative, !model.aiCanKeepRest, !model.aiResultReframed, !model.aiResultFused {
                HStack(spacing: 8) {
                    Chip(title: "只取光影色彩", selected: model.aiToneOnly) { model.setAIToneOnly(true) }
                    Chip(title: "完整采用 AI 图", selected: !model.aiToneOnly) { model.setAIToneOnly(false) }
                    Spacer()
                }
            }
            if model.aiCanKeepRest, !model.aiToneOnly {
                HStack(spacing: 8) {
                    Chip(title: model.aiResultOutfit ? "只换衣服" : "只换变了的地方", selected: model.aiChangedOnly) { model.setAIChangedOnly(true) }
                    Chip(title: "完整采用 AI 图", selected: !model.aiChangedOnly) { model.setAIChangedOnly(false) }
                    Spacer()
                }
            }
            if !model.aiFaces.isEmpty, model.aiResultReframed || !model.aiToneOnly {
                HStack(spacing: 8) {
                    Chip(title: "用原图的脸", selected: model.aiKeepFace) { model.setAIKeepFace(true) }
                    Chip(title: "用 AI 的脸", selected: !model.aiKeepFace) { model.setAIKeepFace(false) }
                    Spacer()
                }
            }
            if !model.aiResultReframed {
            HStack(spacing: 12) {
                Text("强度")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { Double(model.aiStrength) }, set: { model.setAIStrength(CGFloat($0)) }), in: 0...1)
                Text("\(Int((model.aiStrength * 100).rounded()))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            }
            HStack(spacing: 12) {
                Text("柔化")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                Slider(value: Binding(get: { Double(model.aiSoften) }, set: { model.setAISoften(CGFloat($0)) }), in: 0...1)
                Text("\(Int((model.aiSoften * 100).rounded()))")
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            }
            if model.aiResultOutfit {
                Button { model.saveToWardrobe() } label: {
                    Label(model.wardrobeSaving ? "正在存…" : (model.wardrobeSaved.map { "已存进衣橱：" + $0 } ?? "存进我的衣橱"), systemImage: "hanger")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                .disabled(model.wardrobeSaving || model.wardrobeSaved != nil)
            }
            if model.aiResultOutfit || (model.aiGroup == .outfit && model.outfitPatch) {
                Button { model.startOutfitPatch() } label: {
                    Label("有地方没换干净，涂抹补换", systemImage: "paintbrush")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            HStack(spacing: 10) {
                if !model.aiResultFused {
                Button { model.runAI() } label: {
                    Label("再生成一次", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
                }
                Button { model.discardAIResult() } label: {
                    Label("不要了，换一个", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Theme.chip, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private func smallButton(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Color.black : Color.white)
                .frame(width: 36, height: 36)
                .background(active ? Theme.accent : Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// 创意玩法里本机模拟不了的那些（加分身、加东西、换场景）：色块渐变 + 图标。
struct CreativeArtTile: View {
    let title: String
    let symbol: String
    let kind: CreativeKind
    var action: () -> Void

    private var colors: [Color] {
        switch kind {
        case .comic: return [Color(red: 0.98, green: 0.55, blue: 0.62), Color(red: 0.5, green: 0.36, blue: 0.85)]
        case .cartoon: return [Color(red: 1, green: 0.78, blue: 0.35), Color(red: 0.98, green: 0.45, blue: 0.5)]
        case .art: return [Color(red: 0.45, green: 0.7, blue: 0.85), Color(red: 0.25, green: 0.3, blue: 0.55)]
        case .twin: return [Color(red: 0.55, green: 0.85, blue: 0.8), Color(red: 0.3, green: 0.45, blue: 0.8)]
        case .fun: return [Color(red: 1, green: 0.6, blue: 0.3), Color(red: 0.85, green: 0.25, blue: 0.45)]
        case .mood: return [Color(red: 0.95, green: 0.7, blue: 0.45), Color(red: 0.35, green: 0.25, blue: 0.5)]
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                }
                .frame(width: 68, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").padding(4) }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 68)
            }
        }
        .buttonStyle(PressStyle())
    }
}
