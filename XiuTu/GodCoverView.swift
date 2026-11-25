import SwiftUI
import WebKit

/// "封神"：AI 杂志封面 / 海报。布局和修图编辑器一致：上面是画面，底部是一级菜单，菜单上方是二、三级选项。
struct GodCoverView: View {
    var assetID = ""
    /// Mac：从文件打开的照片。
    var fileURL: URL?
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case style, ai, text, adjust
        var id: String { rawValue }
        var title: String {
            switch self {
            case .style: return "风格"
            case .ai: return "AI 改造"
            case .text: return "文字"
            case .adjust: return "调整"
            }
        }
    }
    enum TextField: Identifiable {
        case main, sub, extra1, extra2
        var id: Int { hashValue }
        var title: String {
            switch self {
            case .main: return "主标题"
            case .sub: return "副标题"
            case .extra1: return "附加文字 1"
            case .extra2: return "附加文字 2"
            }
        }
    }

    @State private var model = GodCoverModel()
    @State private var tab: Tab = .style
    @State private var editing: TextField?
    @State private var showSettings = false
    @State private var saving = false
    @State private var toast: String?
    @State private var toastID = 0
    @State private var exports: [MacExport] = []
    private let settings = AISettings.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            // 引擎：必须留在界面层级里才能稳定工作，但不显示出来。
            EngineHost(webView: model.engine.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            if Platform.isMac {
                macLayout
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    canvas
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    panel
                    tabBar
                }
                .ignoresSafeArea(.keyboard)
            }
            if model.isLoading || saving {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(24)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
            if let error = model.errorText {
                Text(error).foregroundStyle(Theme.dim)
            }
            if let toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(Color(white: 0.2).opacity(0.95), in: Capsule())
                        .padding(.bottom, Platform.isMac ? 48 : 250)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
            if let field = editing {
                TextInputOverlay(initial: text(field), placeholder: field.title) { value in
                    setText(field, value.trimmingCharacters(in: .whitespacesAndNewlines))
                    editing = nil
                    model.refresh()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        #if DEBUG
        .onAppear { if let t = Tab(rawValue: ProcessInfo.processInfo.environment["XIUTU_TAB"] ?? "") { tab = t } }
        #endif
        .navigationBarBackButtonHidden(true)
        .task { await model.load(assetID: assetID, fileURL: fileURL) }
        .macExport($exports) { _ in
            MacSession.shared.editorDirty = false
            show("已导出")
        }
        .onChange(of: model.hasAI) { if Platform.isMac, model.hasAI { MacSession.shared.editorDirty = true } }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    // MARK: Mac 布局

    private var macLayout: some View {
        MacWorkbench(title: "封神", onClose: onClose) {
            Button(action: export) { Text("导出").macProminent() }
                .buttonStyle(.plain)
                .disabled(model.isLoading || saving)
        } canvas: {
            canvas
        } header: {
            SegmentBar(items: Tab.allCases, selected: tab, title: { $0.title }) { tab = $0 }
                .padding(.horizontal, 16)
                .padding(.top, 14)
        } panel: {
            panel
        } footer: {
            EmptyView()
        }
    }

    private func export() {
        saving = true
        Task {
            let data = await model.exportData()
            saving = false
            guard let data else {
                show("导出失败")
                return
            }
            exports = [MacExport(data: data, name: model.mainTitle.isEmpty ? "封神" : model.mainTitle, source: "封神")]
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("封神").font(.system(size: 16, weight: .bold))
            Spacer()
            Button(action: save) {
                Text("保存")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .disabled(model.isLoading || saving)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 画面

    private var canvas: some View {
        ZStack(alignment: .bottom) {
            if let image = model.preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            if model.hasAI {
                HStack(spacing: 0) {
                    segment("原图", selected: !model.showingAI) { model.showAI(false) }
                    segment("AI 图", selected: model.showingAI) { model.showAI(true) }
                }
                .background(Color.black.opacity(0.6), in: Capsule())
                .padding(.bottom, 18)
            }
        }
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(selected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 一级菜单

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases) { item in
                Button { tab = item } label: {
                    VStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 16, weight: tab == item ? .bold : .regular))
                            .foregroundStyle(tab == item ? Theme.accent : Color.white)
                        Capsule()
                            .fill(tab == item ? Theme.accent : Color.clear)
                            .frame(width: 18, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 50)
        .background(Theme.panel)
    }

    // MARK: 二、三级内容

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 10) {
            SubjectModeBar(selected: model.subject, disabled: model.running) { model.subject = $0 }
                .opacity(model.isLoading ? 0 : 1)
            switch tab {
            case .style: stylePanel
            case .ai: aiPanel
            case .text: textPanel
            case .adjust: adjustPanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sheet)
    }

    private var stylePanel: some View {
        let categories = model.catalog.categories
        return VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    ForEach(categories.indices, id: \.self) { index in
                        Chip(title: "\(categories[index].icon) \(shortTitle(categories[index].title))",
                             selected: model.categoryIndex == index) { model.categoryIndex = index }
                    }
                }
            }
            HScroll {
                HRow(spacing: 10) {
                    if categories.indices.contains(model.categoryIndex) {
                        ForEach(categories[model.categoryIndex].styles) { style in
                            let selected = model.styleID == style.id
                            Button { model.selectStyle(style.id) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(style.name)
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(selected ? Theme.accent : Color.white)
                                        .lineLimit(Platform.isMac ? nil : 2)
                                        .minimumScaleFactor(0.8)
                                    Text(style.desc)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.dim)
                                        .lineLimit(Platform.isMac ? nil : 2)
                                }
                                .optionCard(width: 104)
                                .padding(10)
                                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    /// 分类名里"·"后面的补充说明在标签上省掉，保持一行。
    private func shortTitle(_ title: String) -> String {
        title.replacingOccurrences(of: " · 14 种类型", with: "")
            .replacingOccurrences(of: "日本 · ", with: "")
            .replacingOccurrences(of: " / ", with: "/")
    }

    @ViewBuilder
    private var aiPanel: some View {
        if !settings.isConfigured(settings.active) {
            VStack(spacing: 10) {
                Text("还没有设置 \(settings.active.shortTitle) 的 API Key").font(.system(size: 14))
                Button { showSettings = true } label: {
                    Text("去设置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 18)
        } else if model.running {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(model.started)))
                    Text("\(settings.active.shortTitle) 正在生成… \(seconds) 秒")
                        .font(.system(size: 14))
                        .monospacedDigit()
                }
                Spacer()
                Button("取消") { model.cancelAI() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 26)
        } else {
            if model.subject == .scene {
                sceneOptions
            } else {
                OptionLine(openSettings: { showSettings = true }) {
                    ForEach(GodCoverModel.OptionGroup.allCases) { group in
                        Chip(title: group.title, selected: model.optionGroup == group) { model.optionGroup = group }
                    }
                }
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(model.options(model.optionGroup)) { option in
                            Chip(title: option.title, selected: model.value(model.optionGroup) == option.id) {
                                model.setValue(option.id, for: model.optionGroup)
                            }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button { model.generate(noText: false) } label: {
                    Label(model.hasAI ? "再生成一张" : "生成封面", systemImage: "sparkles")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                Button { model.generate(noText: true) } label: {
                    Text("无字版")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 44)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            if let usage = model.usageText {
                Text(usage)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.aiError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        .fixedSize(horizontal: false, vertical: true)
                    let others = AIProvider.allCases.filter { $0 != settings.active && settings.isConfigured($0) }
                    HStack(spacing: 8) {
                        ForEach(others) { provider in
                            Button {
                                settings.setActive(provider)
                                model.retry()
                            } label: {
                                Text("换 \(provider.shortTitle) 重试")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent, in: Theme.buttonShape)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 场景模式的 AI 改造：封面的主角是场景本身，选项换成大片感、光线、天气、季节、时间、清理。
    @ViewBuilder
    private var sceneOptions: some View {
        if Platform.isMac {
            HStack {
                Spacer()
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
        }
        HStack(spacing: 8) {
            ChipRow(items: GodCoverScene.Group.allCases, title: { $0.title },
                    isSelected: { model.sceneGroup == $0 }) { model.sceneGroup = $0 }
            if !Platform.isMac {
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
        }
        ChipRow(items: model.sceneGroup.options, title: { $0.title },
                isSelected: { model.sceneValue(model.sceneGroup) == $0.id }) {
            model.sceneValues[model.sceneGroup] = $0.id
        }
    }

    private var textPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                textCell(.main)
                textCell(.sub)
            }
            HStack(spacing: 8) {
                textCell(.extra1)
                textCell(.extra2)
            }
            HScroll {
                HRow(spacing: 8) {
                    Chip(title: "🎲 随机文案", selected: false) {
                        Task { await model.randomizeText(render: true) }
                    }
                    Chip(title: "叠加杂志模板", selected: model.showTemplate) {
                        model.showTemplate.toggle()
                        model.refresh()
                    }
                    Chip(title: "让 AI 用我的文字", selected: model.forceText) {
                        model.forceText.toggle()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func textCell(_ field: TextField) -> some View {
        if Platform.isMac {
            MacFieldCell(title: field.title, text: Binding(get: { text(field) }, set: {
                setText(field, $0)
                model.refresh()
            }))
        } else {
            phoneTextCell(field)
        }
    }

    private func phoneTextCell(_ field: TextField) -> some View {
        let value = text(field)
        return Button { editing = field } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(field.title)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                Text(value.isEmpty ? "点这里填写" : value)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(value.isEmpty ? Theme.dim : Color.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var adjustPanel: some View {
        VStack(spacing: 8) {
            sliderRow("缩放", value: $model.scale, range: 50...200, unit: "%")
            sliderRow("水平", value: $model.offsetX, range: -100...100, unit: "")
            sliderRow("垂直", value: $model.offsetY, range: -100...100, unit: "")
            HScroll {
                HRow(spacing: 8) {
                    ForEach(model.catalog.filter) { option in
                        Chip(title: option.title, selected: model.filter == option.id) {
                            model.filter = option.id
                            model.refresh()
                        }
                    }
                }
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
                .frame(width: 36, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = $0
                model.refresh()
            }), in: range)
            Text("\(Int(value.wrappedValue.rounded()))\(unit)")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    // MARK: 文字读写

    private func text(_ field: TextField) -> String {
        switch field {
        case .main: return model.mainTitle
        case .sub: return model.subtitle
        case .extra1: return model.extra1
        case .extra2: return model.extra2
        }
    }

    private func setText(_ field: TextField, _ value: String) {
        switch field {
        case .main: model.mainTitle = value
        case .sub: model.subtitle = value
        case .extra1: model.extra1 = value
        case .extra2: model.extra2 = value
        }
    }

    // MARK: 动作

    private func save() {
        saving = true
        Task {
            let ok = await model.save()
            saving = false
            show(ok ? "已保存到相册" : "保存失败，请检查相册权限")
        }
    }

    private func show(_ message: String) {
        toastID += 1
        let id = toastID
        withAnimation(.easeOut(duration: 0.15)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if id == toastID { withAnimation(.easeIn(duration: 0.2)) { toast = nil } }
        }
    }
}

private struct EngineHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
