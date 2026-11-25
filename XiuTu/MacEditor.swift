import SwiftUI
import UniformTypeIdentifiers

/// 跑在哪儿：Mac 版（Mac Catalyst）界面另做一套，像专业修图软件那样左工具栏、中间画布、右边属性面板。
enum Platform {
    static let isMac = ProcessInfo.processInfo.isMacCatalystApp
}

/// Mac 版画布的缩放状态：放大镜开没开、现在放大了多少（1 = 整张图正好放进窗口），以及菜单里的缩放命令。
@Observable
final class MacCanvasState {
    static let shared = MacCanvasState()
    var magnifier = false
    var zoom: CGFloat = 1
    /// 每次加一 = 缩回整张图。
    var fitRequest = 0
    /// 菜单里的放大 / 缩小：id 每次加一，factor 是倍数。
    var zoomStep: (id: Int, factor: CGFloat) = (0, 1)

    func zoomIn() { zoomStep = (zoomStep.id + 1, 1.5) }
    func zoomOut() { zoomStep = (zoomStep.id + 1, 1 / 1.5) }
    func fit() { fitRequest += 1 }

    private init() {}
}

/// Mac 版的配色：比手机版的纯黑浅一点，分出工具栏、面板和画布底。
enum MacTheme {
    static let chrome = Color(white: 0.14)
    static let panel = Color(white: 0.12)
    static let header = Color(white: 0.17)
    static let canvas = Color(white: 0.07)
    static let line = Color(white: 0.23)
    static let hover = Color(white: 0.22)
}

/// 导出时交给存储面板的图片文件。
struct ImageFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.jpeg, .png, .heic] }
    var data: Data
    var type: UTType

    init(data: Data, type: UTType) {
        self.data = data
        self.type = type
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// 菜单栏要用的：当前窗口里正在编辑的那张图。
@MainActor
struct MacEditorCommands {
    let model: EditorModel
    let save: () -> Void

    /// 开着工具也能撤销：先把这个工具收起来（相当于应用后再撤掉，重做还能找回来）。
    var canUndo: Bool { model.canUndo || (model.tool != nil && idle) }
    var canRedo: Bool { model.canRedo || (model.tool != nil && idle && model.redoAvailable) }

    private var idle: Bool { !model.isBusy && !model.aiRunning && !model.isLoading }

    func undo() {
        if model.tool != nil {
            guard idle else { return }
            model.commitTool { model.undo() }
        } else {
            model.undo()
        }
    }

    func redo() {
        if model.tool != nil {
            guard idle else { return }
            model.commitTool { model.redo() }
        } else {
            model.redo()
        }
    }
}

private struct MacEditorKey: FocusedValueKey {
    typealias Value = MacEditorCommands
}

extension FocusedValues {
    var macEditor: MacEditorCommands? {
        get { self[MacEditorKey.self] }
        set { self[MacEditorKey.self] = newValue }
    }
}

// MARK: - 编辑器的 Mac 布局

extension EditorView {
    /// 导出时默认的文件名：原文件名后面加"-穷图"。
    var exportName: String {
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? ""
        let usable = !base.isEmpty && !base.allSatisfy(\.isNumber)
        let ext = exportOptions.format == .jpeg ? "jpg" : exportOptions.format.rawValue
        return (usable ? "\(base)-穷图" : "穷图") + "." + ext
    }

    var macCommands: MacEditorCommands {
        MacEditorCommands(model: model, save: { if !model.isLoading { showSave = true } })
    }

    /// 顶栏 + （左工具栏 | 画布 | 右面板）+ 状态栏。
    var macLayout: some View {
        VStack(spacing: 0) {
            macTopBar
            Rectangle().fill(MacTheme.line).frame(height: 1)
            HStack(spacing: 0) {
                MacToolStrip(model: model, embedded: embedded, onEntry: handle)
                    .disabled(model.recipeStatus != nil || model.isLoading)
                Rectangle().fill(MacTheme.line).frame(width: 1)
                canvasArea
                    .background(MacTheme.canvas)
                Rectangle().fill(MacTheme.line).frame(width: 1)
                macInspector
                    .frame(width: 372)
                    .frame(maxHeight: .infinity)
                    .background(MacTheme.panel)
                    .disabled(model.recipeStatus != nil)
            }
            // 中间这一层永远只占窗口剩下的高度，顶栏、状态栏不会被挤出去。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .layoutPriority(-1)
            Rectangle().fill(MacTheme.line).frame(height: 1)
            macStatusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MacTheme.canvas)
        .background {
            // Ctrl+Z / Ctrl+Shift+Z 也能撤销、重做（⌘Z 在菜单栏里）。
            Group {
                Button("") { macCommands.undo() }.keyboardShortcut("z", modifiers: .control)
                Button("") { macCommands.redo() }.keyboardShortcut("z", modifiers: [.control, .shift])
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }

    private var imagePixels: CGSize? {
        guard let e = model.source?.extent, !e.isInfinite, e.width > 0 else { return nil }
        return e.size
    }

    // MARK: 顶栏

    private var macTopBar: some View {
        HStack(spacing: 6) {
            // 左边让出窗口的红绿灯按钮。
            Color.clear.frame(width: 70, height: 1)
            if layerEdit == nil {
                MacIconButton(symbol: "chevron.left", help: "返回开始页") {
                    if model.hasEdits, !isSaved { confirmDiscard = true } else { leave() }
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(layerEdit.map { "图层：\($0.title)" } ?? fileTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let size = imagePixels {
                    Text("\(Int(size.width)) × \(Int(size.height))")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 16)
            MacIconButton(symbol: "arrow.uturn.backward", help: "撤销 ⌘Z / Ctrl+Z") { macCommands.undo() }
                .disabled(!macCommands.canUndo)
            MacIconButton(symbol: "arrow.uturn.forward", help: "重做 ⇧⌘Z / Ctrl+Shift+Z") { macCommands.redo() }
                .disabled(!macCommands.canRedo)
            Spacer(minLength: 16)
            MacIconButton(symbol: canvasState.magnifier ? "minus.magnifyingglass" : "plus.magnifyingglass",
                          help: "放大镜：单击放大、⌥ 单击缩小、左右拖动缩放（⇧⌘M）") { canvasState.magnifier.toggle() }
                .foregroundStyle(canvasState.magnifier ? Theme.accent : Color.white)
                .background(canvasState.magnifier ? Theme.accent.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            MacIconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "适合窗口（⌘0）") { canvasState.fit() }
                .disabled(canvasState.zoom < 1.01)
            MacHoldButton(symbol: "square.split.2x1", help: "按住看原图") { model.comparing = $0 }
                .opacity(model.isLoading ? 0.3 : 1)
            if let layerEdit {
                Button {
                    layerEdit.onDone(model.ops)
                    onClose()
                } label: {
                    Text("完成").macProminent()
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading || model.isBusy)
            } else {
                if isSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                        .help("已导出")
                }
                Button { showSave = true } label: {
                    Text("导出").macProminent()
                }
                .buttonStyle(.plain)
                .disabled(model.isLoading || saving || model.tool != nil)
                .help("导出 ⌘S")
            }
        }
        .padding(.trailing, 12)
        .frame(height: 44)
        .background(MacTheme.chrome)
    }

    private var canvasState: MacCanvasState { MacCanvasState.shared }

    private var fileTitle: String {
        let name = fileURL?.lastPathComponent ?? ""
        return name.isEmpty || name.allSatisfy(\.isNumber) ? "未命名" : name
    }

    // MARK: 右边的面板

    private var macInspector: some View {
        VStack(spacing: 0) {
            if let tool = model.tool {
                toolSection(tool)
            } else {
                Spacer(minLength: 0)
            }
            MacLayersPanel(model: model)
            MacHistoryPanel(model: model, fill: model.tool == nil)
        }
    }

    private func toolSection(_ tool: Tool) -> some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(macTitle(tool))
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                    Spacer()
                    Button("取消") { model.cancelTool() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(MacPanelButtonStyle(prominent: false))
                    Button("应用") { model.commitTool() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(MacPanelButtonStyle(prominent: true))
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .background(MacTheme.header)
                if let sub = subTitle(for: tool) {
                    sub
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(minHeight: 40)
                        .background(MacTheme.header.opacity(0.6))
                }
                Rectangle().fill(MacTheme.line).frame(height: 1)
                // 面板再高也只在这一块里上下滚，不会把整个窗口往上顶。
                ScrollView(.vertical) {
                    panel(for: tool)
                        .padding(.top, 6)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxHeight: .infinity)
            }
    }

    /// 面板标题：左边工具栏里选的是哪一项也写上（分组按钮在 Mac 上不重复放）。
    private func macTitle(_ tool: Tool) -> String {
        switch tool {
        case .ai:
            let group = model.aiGroup
            if group == .body || group.isHair { return "\(title(for: tool)) · \(group.title)" }
            return "AI 修图 · \(group.title)"
        case .beauty:
            return model.beautyMode == .manual ? "手动美颜" : "一键美颜"
        case .shape:
            return model.shapeState.mode.title
        default:
            return title(for: tool)
        }
    }

    /// 有些工具在手机版底部确认栏中间放了分组切换，Mac 版放在面板标题下面。
    private func subTitle(for tool: Tool) -> AnyView? {
        switch tool {
        case .adjust: return AnyView(AdjustTitle(model: model))
        case .reshape: return AnyView(ReshapeTitle(model: model))
        case .makeup: return AnyView(MakeupTitle(model: model))
        case .skin: return AnyView(SkinTitle(model: model))
        default: return nil
        }
    }

    // MARK: 状态栏

    private var macStatusBar: some View {
        HStack(spacing: 14) {
            if let size = imagePixels {
                Text("\(Int(size.width)) × \(Int(size.height)) 像素")
            }
            Text("\(Int((canvasState.zoom * 100).rounded()))%")
                .help("100% = 整张图放进窗口")
            if canvasState.magnifier {
                Label("放大镜", systemImage: "plus.magnifyingglass").foregroundStyle(Theme.accent)
            }
            if let tool = model.tool {
                Text(title(for: tool))
            }
            Spacer()
            if let status = model.recipeStatus {
                ProgressView().controlSize(.mini)
                Text(status).lineLimit(1)
                Button("停止") { model.stopRecipe() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            MacAIStatus(running: model.aiRunning) { showSettings = true }
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(MacTheme.chrome)
    }
}

// MARK: - 状态栏里的 AI 状态

/// 状态栏右边：现在用哪家 AI、Key 填没填、正在生成，以及这家累计花了多少。点一下打开设置。
struct MacAIStatus: View {
    var running = false
    var open: () -> Void
    private let settings = AISettings.shared

    var body: some View {
        let provider = settings.active
        let ready = settings.isConfigured(provider)
        let stats = settings.stats(provider)
        Button(action: open) {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Theme.accent : (ready ? Color.green : Color.red))
                    .frame(width: 7, height: 7)
                Text("AI：\(provider.shortTitle)")
                if ready {
                    Text(settings.config(provider).model).lineLimit(1)
                } else {
                    Text("未设置 API Key").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                }
                if running {
                    Text("生成中…").foregroundStyle(Theme.accent)
                }
                if stats.requests > 0 {
                    Text("·")
                    Text("累计 \(stats.requests) 次 \(stats.images) 张")
                    Text(costText(stats, currency: provider.currency))
                        .foregroundStyle(Color.white.opacity(0.85))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("AI 设置和用量")
    }

    private func costText(_ stats: AIProviderStats, currency: AICurrency) -> String {
        if stats.unpriced == stats.requests { return "费用 —" }
        let value = stats.cost < 0.01 && stats.cost > 0 ? String(format: "%.4f", stats.cost) : String(format: "%.2f", stats.cost)
        return "约 \(currency.symbol)\(value)"
    }
}

// MARK: - 左边的工具栏

/// 左边的工具栏，像抽屉一样：点一类，这一类的工具就在它下面展开；点另一类，原来展开的自动合上。
/// 调色、滤镜、特效没有下一级，点了直接打开。
struct MacToolStrip: View {
    let model: EditorModel
    var embedded = false
    var onEntry: (MenuAction) -> Void

    @State private var expanded: MainTab? = .tools

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) {
                ForEach(MainTab.allCases) { tab in
                    header(tab)
                    if expanded == tab, tab.directTool == nil {
                        VStack(spacing: 1) {
                            ForEach(entries(tab)) { entry in row(entry) }
                        }
                        .padding(.bottom, 6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .frame(width: 136)
        .background(MacTheme.chrome)
        .onChange(of: active) { if let a = active, a.directTool == nil { withAnimation(.easeOut(duration: 0.18)) { expanded = a } } }
    }

    private func header(_ tab: MainTab) -> some View {
        let on = active == tab
        let open = expanded == tab && tab.directTool == nil
        return Button {
            withAnimation(.easeOut(duration: 0.18)) {
                if let tool = tab.directTool {
                    expanded = nil
                    onEntry(.tool(tool))
                } else {
                    expanded = open ? nil : tab
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(tab))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 20)
                Text(tab.title)
                    .font(.system(size: 13, weight: on || open ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if tab.directTool == nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.dim)
                }
            }
            .foregroundStyle(on ? Theme.accent : Color.white)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(open ? MacTheme.header : (on ? Theme.accent.opacity(0.14) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func row(_ entry: MenuEntry) -> some View {
        let on = isActive(entry)
        return Button { onEntry(entry.action) } label: {
            HStack(spacing: 7) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 12))
                    .frame(width: 18)
                Text(entry.title)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                if let badge = entry.badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .foregroundStyle(on ? Theme.accent : Color.white.opacity(0.85))
            .padding(.leading, 18)
            .padding(.trailing, 6)
            .frame(height: 28)
            .background(on ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(MacHoverStyle())
    }

    private func entries(_ tab: MainTab) -> [MenuEntry] {
        tab.entries.filter { !(embedded && $0.id == Tool.layers.title) }
    }

    /// 这一项是不是正在用的工具。
    private func isActive(_ entry: MenuEntry) -> Bool {
        guard let tool = model.tool else { return false }
        switch entry.action {
        case .tool(let t): return t == tool
        case .ai(let group): return tool == .ai && model.aiGroup == group
        case .erase: return tool == .ai && model.aiGroup == .remove
        case .beauty(let manual): return tool == .beauty && (model.beautyMode == .manual) == manual
        case .favoriteFace: return false
        case .shape(let mode): return tool == .shape && model.shapeState.mode == mode
        }
    }

    static func symbol(_ tab: MainTab) -> String {
        switch tab {
        case .tools: return "crop"
        case .beauty: return "face.smiling"
        case .body: return "figure.stand"
        case .hair: return "comb"
        case .filter: return "camera.filters"
        case .effect: return "sparkles.rectangle.stack"
        case .adjust: return "slider.horizontal.3"
        case .deco: return "square.on.circle"
        case .ai: return "sparkles"
        }
    }

    /// 正在用的工具属于哪一类。
    private var active: MainTab? {
        guard let tool = model.tool else { return nil }
        if tool == .ai {
            if model.aiGroup.isHair { return .hair }
            if model.aiGroup == .body { return .body }
            if model.aiGroup == .remove { return .tools }
            return .ai
        }
        switch tool {
        case .filter: return .filter
        case .effect: return .effect
        case .adjust: return .adjust
        case .beauty, .reshape, .makeup, .skin: return .beauty
        case .shape, .liquify, .bodyTone: return .body
        case .smartCrop: return .ai
        case .crop, .collage, .layers: return .tools
        default: return .deco
        }
    }
}

// MARK: - 历史记录

/// 右边最下面的"历史记录"：点标题折叠 / 展开，记住上次的状态。没开工具时占满右边，开着工具时放在工具下面。
struct MacHistoryPanel: View {
    let model: EditorModel
    var fill: Bool
    @AppStorage("mac.historyOpen") private var open = true

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.dim)
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                    Text("历史记录").font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text("\(model.historyIndex + 1) / \(model.historyStates.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(MacTheme.header)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(MacTheme.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(MacTheme.line).frame(height: open ? 1 : 0) }
            if open {
                MacHistoryList(model: model)
                    .frame(maxHeight: fill ? .infinity : 170)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: fill && open ? .infinity : nil, alignment: .top)
    }
}

/// 打开之后每一步的状态，点一下回到那一步（之后的步骤变灰，还能点回来）。
struct MacHistoryList: View {
    let model: EditorModel

    var body: some View {
        let states = model.historyStates
        let current = model.historyIndex
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(states.indices, id: \.self) { i in
                        row(i, states: states, current: current)
                            .id(i)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: current) { proxy.scrollTo(current, anchor: .center) }
        }
        .disabled(model.isBusy || model.aiRunning)
    }

    private func row(_ i: Int, states: [[EditOp]], current: Int) -> some View {
        let step = i == 0 ? nil : states[i].last.map { EditRecipe.step($0, inputSize: { .zero }) }
        let on = i == current
        return Button {
            // 开着工具时先应用它（Mac 上切到别处都是自动应用），再跳过去。
            if model.tool != nil { model.commitTool { model.jumpHistory(to: i) } } else { model.jumpHistory(to: i) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: step?.symbol ?? "photo")
                    .font(.system(size: 13))
                    .frame(width: 20)
                Text(step?.title ?? "打开")
                    .font(.system(size: 13, weight: on ? .semibold : .regular))
                if let detail = step?.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(i > current ? Color.white.opacity(0.35) : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(on ? Theme.accent.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 小部件

/// 一行滑条：名字、数值（改过的显示成橙色）、复位，下面是滑条。
struct MacSliderRow: View {
    let title: String
    let value: String
    var changed: Bool
    let binding: Binding<Double>
    let range: ClosedRange<Double>
    var reset: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(changed ? Theme.accent : Theme.dim)
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(changed ? 1 : 0.25)
                .disabled(!changed)
                .help("复位")
            }
            Slider(value: binding, in: range)
                .controlSize(.small)
        }
    }
}

struct MacSectionHeader: View {
    let title: String

    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(MacTheme.header)
        .overlay(alignment: .bottom) { Rectangle().fill(MacTheme.line).frame(height: 1) }
    }
}

struct MacIconButton: View {
    let symbol: String
    var help: String = ""
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(MacHoverStyle())
        .opacity(enabled ? 1 : 0.3)
        .help(help)
    }
}

/// 按住时 pressed = true，松开 false（对比原图用）。
struct MacHoldButton: View {
    let symbol: String
    var help: String = ""
    var onChange: (Bool) -> Void
    @State private var down = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(down ? Theme.accent : Color.white)
            .frame(width: 32, height: 30)
            .background(down ? MacTheme.hover : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !down { down = true; onChange(true) } }
                .onEnded { _ in down = false; onChange(false) })
            .help(help)
    }
}

struct MacHoverStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MacHoverBody(configuration: configuration)
    }

    private struct MacHoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? MacTheme.line : (hovering ? MacTheme.hover : Color.clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovering = $0 }
        }
    }
}

struct MacPanelButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(prominent ? Theme.accent : MacTheme.line, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension Text {
    /// 顶栏上主要的那个按钮（导出、完成）。
    func macProminent() -> some View {
        self.font(.system(size: 13, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 7))
    }
}
