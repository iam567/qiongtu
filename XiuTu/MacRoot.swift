import SwiftUI
import UniformTypeIdentifiers

/// Mac 版窗口里共享的状态：菜单栏的"打开…"和编辑器有没有没导出的修改。
@Observable
final class MacSession {
    static let shared = MacSession()

    /// 打开文件面板是为了什么。
    enum Purpose: Equatable {
        case open, raw, stitch, cover, studio, recipe(UUID)

        var types: [UTType] {
            switch self {
            case .raw: return [.rawImage]
            default: return [.image, .rawImage]
            }
        }

        var multiple: Bool { self == .open || self == .stitch }
    }

    /// 不为空 = 要弹出打开文件面板。
    var importing: Purpose?
    /// 编辑器里有没有没导出的修改（拖进新图时先问一声）。
    var editorDirty = false
    /// 从 Finder 打开、还没处理的文件。
    var incoming: [URL] = []
    /// 拖进漫画人生、满意脸型的图片，由那一页自己取走。
    var dropped: [URL] = []
    /// 菜单栏里点了漫画人生 / 满意脸型。
    var page: Page?

    enum Page: Equatable { case manga, faces, batch(UUID?) }

    private init() {}
}

/// Mac 版的根视图：开始页、编辑器、RAW 冲洗、历史图库之间切换。整个窗口都能拖图片进来。
struct MacRootView: View {
    private enum Screen {
        case start
        case editor(URL, recipe: UUID?, id: UUID)
        case stitch(AutoStitchJob, id: UUID)
        case raw(name: String, data: Data, id: UUID)
        case history
        case cover(URL, id: UUID)
        case studio(URL, id: UUID)
        case manga
        case faces
        case batch(UUID?, id: UUID)
        case draft

        var isEditing: Bool {
            switch self {
            case .editor, .stitch, .raw, .cover, .studio, .manga, .batch, .draft: return true
            default: return false
            }
        }
    }

    @State private var screen: Screen = .start
    @State private var dropping = false
    @State private var pending: [URL]?
    @State private var pendingPurpose: MacSession.Purpose = .open
    @State private var askDraft = false
    @State private var draftChecked = false
    @State private var busy = false
    @State private var note: String?
    @State private var showSettings = false
    /// 打开文件面板这一次是为了什么（面板关掉后 session.importing 会被清掉）。
    @State private var purpose: MacSession.Purpose = .open
    @State private var arriving: [URL] = []
    @State private var arrivalTask: Task<Void, Never>?
    private let session = MacSession.shared

    var body: some View {
        ZStack {
            MacTheme.canvas.ignoresSafeArea()
            content
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 3)
                    .padding(4)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            if busy {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .padding(24)
                    .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .ignoresSafeArea()
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            Task { open(await Self.urls(from: providers), purpose: .open) }
            return true
        }
        .fileImporter(isPresented: Binding(get: { session.importing != nil },
                                           set: { if !$0 { session.importing = nil } }),
                      allowedContentTypes: purpose.types,
                      allowsMultipleSelection: purpose.multiple) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { _ = url.startAccessingSecurityScopedResource() }
            open(urls, purpose: purpose)
        }
        .onChange(of: session.importing) { if let p = session.importing { purpose = p } }
        .confirmationDialog("放弃当前修改？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible) {
            Button("放弃修改，打开新图", role: .destructive) {
                let urls = pending ?? []
                pending = nil
                session.editorDirty = false
                perform(urls, purpose: pendingPurpose)
            }
            Button("继续编辑", role: .cancel) {}
        }
        .alert(note ?? "", isPresented: Binding(get: { note != nil }, set: { if !$0 { note = nil } })) {
            Button("好", role: .cancel) {}
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear {
            configureWindow()
            checkDraft()
        }
        .onChange(of: session.page) {
            guard let page = session.page else { return }
            session.page = nil
            show(page)
        }
        .alert("上次有一张图还没编辑完", isPresented: $askDraft) {
            Button("接着编辑", role: .cancel) { screen = .draft }
            Button("不要了", role: .destructive) { DraftStore.shared.clear() }
        }
        // Finder 里"打开方式"、拖到程序坞图标上。
        // Finder 里"打开方式"、拖到程序坞图标上：MacSceneDelegate 收到后放进 session.incoming。
        .onChange(of: session.incoming, initial: true) {
            guard !session.incoming.isEmpty else { return }
            arriving += session.incoming
            session.incoming = []
            // 好几个文件可能分几次送进来：攒一下，一起打开（好几张 = 拼接）。
            arrivalTask?.cancel()
            arrivalTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                let urls = arriving
                arriving = []
                open(urls, purpose: .open)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .start:
            MacStartView(onOpen: { session.importing = $0 },
                         onRecent: { url in screen = .editor(url, recipe: nil, id: UUID()) },
                         onHistory: { screen = .history },
                         onPage: { show($0) },
                         onSettings: { showSettings = true })
        case .editor(let url, let recipe, let id):
            EditorView(assetID: "", fileURL: url, recipeID: recipe, initialTool: nil) { close() }
                .id(id)
        case .stitch(let job, let id):
            EditorView(assetID: "", fileURL: job.files.first, stitchJob: job, initialTool: .collage) { close() }
                .id(id)
        case .raw(let name, let data, let id):
            RawView(name: name, data: data, onClose: close) { url in
                screen = .editor(url, recipe: nil, id: UUID())
            }
            .id(id)
        case .history:
            VStack(spacing: 0) {
                Color.clear.frame(height: 28)
                HistoryView(onEdit: { url in screen = .editor(url, recipe: nil, id: UUID()) },
                            onApply: { id in session.importing = .recipe(id) },
                            onBatch: { id in show(.batch(id)) },
                            onClose: close)
            }
            .background(Theme.bg)
        case .cover(let url, let id):
            GodCoverView(fileURL: url, onClose: close).id(id)
        case .studio(let url, let id):
            StudioView(fileURL: url, onClose: close).id(id)
        case .manga:
            MangaView(onClose: close)
        case .faces:
            FavoriteFaceView(onClose: close)
        case .batch(let style, let id):
            BatchStyleView(styleID: style, onClose: close).id(id)
        case .draft:
            EditorView(assetID: "", restoreDraft: true, initialTool: nil) { close() }
        }
    }

    /// 打开漫画人生、满意脸型。有没导出的修改时先不跳，免得丢掉。
    private func show(_ page: MacSession.Page) {
        if screen.isEditing, session.editorDirty {
            note = "先把现在这张导出，或者返回放弃修改"
            return
        }
        switch page {
        case .manga: screen = .manga
        case .faces: screen = .faces
        case .batch(let style): screen = .batch(style, id: UUID())
        }
    }

    /// 启动时看看草稿箱：上次编辑到一半退出了，就问要不要接着编辑。从 Finder 打开文件进来的不问。
    private func checkDraft() {
        guard !draftChecked else { return }
        draftChecked = true
        Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard case .start = screen, session.incoming.isEmpty, DraftStore.shared.exists else { return }
            askDraft = true
        }
    }

    private func close() {
        session.editorDirty = false
        screen = .start
    }

    // MARK: 打开文件

    /// 拖进来的东西变成文件。Mac Catalyst 里从 Finder 拖文件给的不是路径，而是"图片文件的内容"，
    /// 要用 loadInPlaceFileRepresentation 取；能原地读就用原文件，不能就先复制一份到临时目录（回调结束后系统会删掉它给的临时文件）。
    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await url(from: provider) { urls.append(url) }
        }
        return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        let types = provider.registeredTypeIdentifiers
        // 先找图片类型（RAW 也算图片），按 RAW 优先：同一个文件可能同时带着 RAW 和预览 JPEG 两种。
        let imageTypes = types.filter { UTType($0)?.conforms(to: .image) == true }
        let type = imageTypes.first { UTType($0)?.conforms(to: .rawImage) == true } ?? imageTypes.first
        if let type {
            return await withCheckedContinuation { continuation in
                provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    if inPlace {
                        _ = url.startAccessingSecurityScopedResource()
                        continuation.resume(returning: url)
                        return
                    }
                    continuation.resume(returning: copyToTemp(url, name: provider.suggestedName, type: type))
                }
            }
        }
        // 别的 App 只给了文件路径。
        if types.contains(UTType.fileURL.identifier),
           let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) {
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url }
            if let url = item as? URL { return url }
        }
        return nil
    }

    /// 复制到临时目录，文件名尽量用原来的，没有扩展名就按类型补上。
    private static func copyToTemp(_ url: URL, name: String?, type: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var file = url.lastPathComponent
        if let name, !name.isEmpty, (file.hasPrefix(".") || file.count > 60) { file = name }
        if (file as NSString).pathExtension.isEmpty, let ext = UTType(type)?.preferredFilenameExtension {
            file += "." + ext
        }
        let dest = dir.appendingPathComponent(file)
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private static func isRaw(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .rawImage) ?? false
    }

    private static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    private func open(_ urls: [URL], purpose: MacSession.Purpose) {
        let files = urls.filter(Self.isImage)
        guard !files.isEmpty else {
            if !urls.isEmpty { note = "打不开这个文件" }
            return
        }
        var purpose = purpose
        #if DEBUG
        // 调试用：XIUTU_SCREEN=cover / studio / manga / faces 打开的文件直接进那一页，方便截图检查。
        if case .start = screen, purpose == .open {
            switch ProcessInfo.processInfo.environment["XIUTU_SCREEN"] {
            case "cover": purpose = .cover
            case "studio": purpose = .studio
            case "manga": screen = .manga
            case "faces": screen = .faces
            case "batch": screen = .batch(nil, id: UUID())
            default: break
            }
        }
        #endif
        // 正开着封神、摄影棚、漫画人生、满意脸型时，拖进来的图就给这一页用。
        if purpose == .open {
            switch screen {
            case .cover: purpose = .cover
            case .studio: purpose = .studio
            case .manga, .faces, .batch:
                session.dropped = files
                return
            default: break
            }
        }
        if screen.isEditing, session.editorDirty {
            pendingPurpose = purpose
            pending = files
            return
        }
        perform(files, purpose: purpose)
    }

    /// 一张 RAW → RAW 冲洗；一张普通图片 → 编辑器；好几张 → 拼接（截图自动对好接缝）。
    private func perform(_ files: [URL], purpose: MacSession.Purpose) {
        if case .recipe(let id) = purpose, let url = files.first {
            screen = .editor(url, recipe: id, id: UUID())
            return
        }
        if purpose == .cover, let url = files.first {
            screen = .cover(url, id: UUID())
            return
        }
        if purpose == .studio, let url = files.first {
            screen = .studio(url, id: UUID())
            return
        }
        let raws = files.filter(Self.isRaw)
        if files.count == 1 || (purpose == .raw && !raws.isEmpty) {
            let url = purpose == .raw ? (raws.first ?? files[0]) : files[0]
            if Self.isRaw(url) {
                guard let data = try? Data(contentsOf: url) else {
                    note = "打不开这个文件"
                    return
                }
                screen = .raw(name: url.lastPathComponent, data: data, id: UUID())
            } else {
                screen = .editor(url, recipe: nil, id: UUID())
            }
            return
        }
        let images = files.filter { !Self.isRaw($0) }
        guard images.count >= 2 else {
            if let url = images.first { screen = .editor(url, recipe: nil, id: UUID()) }
            return
        }
        busy = true
        Task {
            let job = await AutoStitchLoader.job(files: images)
            busy = false
            if let job { screen = .stitch(job, id: UUID()) } else { note = "这几张图读不出来" }
        }
    }

    // MARK: 窗口

    private func configureWindow() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            #if targetEnvironment(macCatalyst)
            windowScene.titlebar?.titleVisibility = .hidden
            windowScene.titlebar?.toolbar = nil
            #endif
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1100, height: 720)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: 10000, height: 10000)
        }
    }
}

// MARK: - 开始页

/// 左边是打开文件的几个入口，右边是最近导出的作品。
struct MacStartView: View {
    var onOpen: (MacSession.Purpose) -> Void
    var onRecent: (URL) -> Void
    var onHistory: () -> Void
    var onPage: (MacSession.Page) -> Void
    var onSettings: () -> Void

    private let history = HistoryStore.shared
    private let settings = AISettings.shared
    @State private var saved: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
                .background(MacTheme.chrome)
            Rectangle().fill(MacTheme.line).frame(width: 1)
            recent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MacTheme.panel)
                .overlay(alignment: .bottom) {
                    if let saved {
                        Text(saved)
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color(white: 0.24), in: Capsule())
                            .padding(.bottom, 30)
                            .task(id: saved) {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                self.saved = nil
                            }
                    }
                }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("穷图")
                .font(.system(size: 30, weight: .heavy, design: .rounded))
                .padding(.top, 52)
                .padding(.bottom, 18)
            Button { onOpen(.open) } label: {
                Label("打开…", systemImage: "folder")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .help("打开 ⌘O")
            sideButton("RAW 冲洗…", symbol: "camera.aperture") { onOpen(.raw) }
            sideButton("拼接截图…", symbol: "rectangle.stack") { onOpen(.stitch) }
            Rectangle().fill(MacTheme.line).frame(height: 1).padding(.vertical, 8)
            sideButton("封神…", symbol: "crown") { onOpen(.cover) }
            sideButton("摄影棚…", symbol: "camera") { onOpen(.studio) }
            sideButton("漫画人生", symbol: "book.pages") { onPage(.manga) }
            sideButton("统一风格", symbol: "square.stack.3d.down.right") { onPage(.batch(nil)) }
            Rectangle().fill(MacTheme.line).frame(height: 1).padding(.vertical, 8)
            sideButton(history.hasPassword ? "历史图库（已加密）" : "历史图库", symbol: "photo.stack", action: onHistory)
            sideButton("满意脸型", symbol: "star") { onPage(.faces) }
            Spacer()
            Button(action: onSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI 修图：\(settings.active.shortTitle)")
                            .font(.system(size: 12, weight: .semibold))
                        Text(settings.isConfigured(settings.active) ? settings.config(settings.active).model : "未设置 API Key")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.dim)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape").foregroundStyle(Theme.dim)
                }
                .padding(10)
                .background(MacTheme.header, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            Link(destination: URL(string: "https://x.com/iam678")!) {
                Text("作者X:@iam678")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
    }

    private func sideButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(MacHoverStyle())
    }

    @ViewBuilder
    private var recent: some View {
        let items = history.hasPassword ? [] : Array(history.items.prefix(24))
        if items.isEmpty {
            Button { onOpen(.open) } label: {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 54, weight: .light))
                    Text("打开图片")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.dim)
                .frame(width: 360, height: 240)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(MacTheme.line, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("最近")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 28)
                    .padding(.top, 52)
                    .padding(.bottom, 14)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)], spacing: 22) {
                        ForEach(items) { item in
                            MacRecentTile(item: item) { onRecent(history.fileURL(item)) }
                                .contextMenu {
                                    Button("打开") { onRecent(history.fileURL(item)) }
                                    Button("保存此风格") {
                                        Task { saved = await StyleStore.shared.add(file: history.fileURL(item)) != nil ? "已保存此风格" : "保存失败" }
                                    }
                                    Button("用此风格批量处理…") {
                                        Task { if let style = await StyleStore.shared.add(file: history.fileURL(item)) { onPage(.batch(style.id)) } }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
    }
}

/// 最近作品的一格：缩略图 + 日期。
struct MacRecentTile: View {
    let item: HistoryItem
    var action: () -> Void
    @State private var image: UIImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color(white: 0.1)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                }
                .frame(height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(hovering ? Theme.accent : MacTheme.line, lineWidth: hovering ? 2 : 1))
                Text(item.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Text("\(item.width) × \(item.height) · \(item.source)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.dim.opacity(0.8))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task { image = await HistoryStore.shared.thumbnail(item) }
    }
}

// MARK: - 菜单栏

struct MacCommands: Commands {
    @FocusedValue(\.macEditor) private var editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { MacSession.shared.importing = .open }
                .keyboardShortcut("o")
            Button("RAW 冲洗…") { MacSession.shared.importing = .raw }
            Button("拼接截图…") { MacSession.shared.importing = .stitch }
            Divider()
            Button("封神…") { MacSession.shared.importing = .cover }
            Button("摄影棚…") { MacSession.shared.importing = .studio }
            Button("漫画人生") { MacSession.shared.page = .manga }
            Button("统一风格") { MacSession.shared.page = .batch(nil) }
            Button("满意脸型") { MacSession.shared.page = .faces }
        }
        CommandGroup(replacing: .saveItem) {
            Button("导出…") { editor?.save() }
                .keyboardShortcut("s")
                .disabled(editor == nil || editor?.model.tool != nil)
        }
        CommandMenu("视图") {
            Button("放大") { MacCanvasState.shared.zoomIn() }
                .keyboardShortcut("=")
            Button("缩小") { MacCanvasState.shared.zoomOut() }
                .keyboardShortcut("-")
            Button("适合窗口") { MacCanvasState.shared.fit() }
                .keyboardShortcut("0")
            Divider()
            Button(MacCanvasState.shared.magnifier ? "关闭放大镜" : "放大镜") { MacCanvasState.shared.magnifier.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("撤销") { editor?.undo() }
                .keyboardShortcut("z")
                .disabled(!(editor?.canUndo ?? false))
            Button("重做") { editor?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(editor?.canRedo ?? false))
        }
    }
}

// MARK: - 从 Finder 打开文件

/// SwiftUI 的 onOpenURL 一次只给第一个文件；自己接住窗口场景的回调，好几个文件一起收下。
final class MacAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: session.role)
        if Platform.isMac { config.delegateClass = MacSceneDelegate.self }
        return config
    }
}

final class MacSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        deliver(connectionOptions.urlContexts)
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        deliver(URLContexts)
    }

    private func deliver(_ contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url)
            .filter(\.isFileURL)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !urls.isEmpty else { return }
        for url in urls { _ = url.startAccessingSecurityScopedResource() }
        MacSession.shared.incoming += urls
    }
}
