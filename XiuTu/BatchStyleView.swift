import SwiftUI
import UniformTypeIdentifiers

/// 统一风格：选一个存好的风格，导入一批照片，AI 一张张处理，出一张看一张，随时能停。
struct BatchStyleView: View {
    /// 进来就选这个风格。
    var styleID: UUID?
    var onClose: () -> Void

    @State private var model = BatchStyleModel()
    @State private var picking = false
    @State private var pickingStyle = false
    @State private var pickingFolder = false
    @State private var comparing = false
    @State private var showSettings = false
    @State private var renaming: SavedStyle?
    @State private var newName = ""
    @State private var toast: String?
    private let store = StyleStore.shared
    private let settings = AISettings.shared

    var body: some View {
        ZStack {
            (Platform.isMac ? MacTheme.canvas : Theme.bg).ignoresSafeArea()
            if Platform.isMac {
                MacWorkbench(title: "统一风格", onClose: onClose) {
                    if model.doneCount > 0 {
                        Button { pickingFolder = true } label: { Text(exportTitle).macProminent() }
                            .buttonStyle(.plain)
                            .disabled(model.exporting || model.running)
                    }
                } canvas: {
                    preview
                } header: {
                    EmptyView()
                } panel: {
                    panel
                } footer: {
                    EmptyView()
                }
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    preview.frame(maxWidth: .infinity, maxHeight: .infinity)
                    panel.background(Theme.panel)
                }
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
                .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear { if let styleID, let style = store.styles.first(where: { $0.id == styleID }) { model.style = style } }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        // 几个选文件的面板各挂在一个视图上，互不覆盖。
        .background {
            Color.clear.imageSource(isPresented: $picking, limit: 60) { loaders in
                if Platform.isMac { return }
                model.add(loaders: loaders)
            }
            .disabled(Platform.isMac)
            Color.clear.imageSource(isPresented: $pickingStyle) { loaders in
                Task {
                    guard let data = await loaders.first?(), let style = await store.add(data: data) else { return }
                    model.style = style
                }
            }
            Color.clear.fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                guard case .success(let folder) = result else { return }
                Task {
                    let n = await model.exportAll(to: folder)
                    MacSession.shared.editorDirty = false
                    show("已导出 \(n) 张")
                }
            }
            if Platform.isMac {
                Color.clear.fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                    if case .success(let urls) = result { model.add(urls: urls) }
                }
            }
        }
        .alert("风格的名字", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $newName)
            Button("好") {
                if let renaming { store.rename(renaming, to: newName) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
        // Mac：照片拖进窗口就加进来。
        .onChange(of: MacSession.shared.dropped, initial: true) {
            let files = MacSession.shared.dropped
            guard !files.isEmpty else { return }
            MacSession.shared.dropped = []
            model.add(urls: files)
            #if DEBUG
            if ProcessInfo.processInfo.environment["XIUTU_AUTORUN"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.start() }
            }
            #endif
        }
        .onChange(of: model.doneCount) { if Platform.isMac, model.doneCount > 0 { MacSession.shared.editorDirty = true } }
    }

    @State private var pickingFiles = false

    private var exportTitle: String {
        if model.exporting { return "正在导出 \(model.exported + 1)/\(model.doneCount)" }
        return Platform.isMac ? "全部导出" : "全部保存"
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold)).frame(width: 44, height: 44)
            }
            Spacer()
            Text("统一风格").font(.system(size: 16, weight: .bold))
            Spacer()
            Button {
                Task {
                    let n = await model.saveAll()
                    show(n > 0 ? "已保存 \(n) 张到相册" : "保存失败，请检查相册权限")
                }
            } label: {
                Text(exportTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .opacity(model.doneCount > 0 ? 1 : 0)
            .disabled(model.doneCount == 0 || model.exporting || model.running)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 预览

    @ViewBuilder
    private var preview: some View {
        if let item = model.current {
            ZStack(alignment: .bottom) {
                if let image = comparing ? item.preview : (item.result ?? item.preview) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if item.status == .running {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("正在处理…").font(.system(size: 13))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.65), in: Capsule())
                    .padding(.bottom, 22)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.result != nil {
                    Image(systemName: "square.split.2x1")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.black.opacity(0.55), in: Circle())
                        .padding(14)
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { _ in if !comparing { comparing = true } }
                            .onEnded { _ in comparing = false })
                        .help("按住看原图")
                }
            }
        } else {
            Button { pickPhotos() } label: {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 50, weight: .light))
                    Text("添加照片").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 选项

    private var panel: some View {
        VStack(spacing: 12) {
            styles
            photos
            if !model.items.isEmpty, model.doneCount > 0 {
                HStack(spacing: 12) {
                    Text("强度").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Slider(value: Binding(get: { Double(model.strength) }, set: { model.setStrength(CGFloat($0), editing: true) }), in: 0...1) { editing in
                        if !editing { model.setStrength(model.strength, editing: false) }
                    }
                    Text("\(Int((model.strength * 100).rounded()))")
                        .font(.system(size: 14, weight: .semibold)).monospacedDigit().frame(width: 34, alignment: .trailing)
                }
            }
            if !settings.isConfigured(settings.active) {
                NeedsKeyView { showSettings = true }
            } else {
                actions
            }
            if model.spent > 0 {
                Text("已花费约 $\(String(format: "%.2f", model.spent))")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var styles: some View {
        HScroll {
            HRow(alignment: .top, spacing: 10) {
                tile(title: "添加风格", selected: false) {
                    ZStack {
                        Theme.chip
                        Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                    }
                } action: { pickingStyle = true }
                ForEach(store.styles) { style in
                    tile(title: style.name, selected: model.style?.id == style.id) {
                        if let image = store.image(style) { Image(uiImage: image).resizable().scaledToFill() } else { Theme.chip }
                    } action: { if !model.running { model.style = style } }
                    .contextMenu {
                        Button("改名") {
                            newName = style.name
                            renaming = style
                        }
                        Button("删除", role: .destructive) {
                            store.remove(style)
                            if model.style?.id == style.id { model.style = store.styles.first }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(model.running)
    }

    private var photos: some View {
        HScroll {
            HRow(alignment: .top, spacing: 10) {
                tile(title: "添加照片", selected: false) {
                    ZStack {
                        Theme.accent
                        if model.loading {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(.black)
                        }
                    }
                } action: { pickPhotos() }
                ForEach(model.items) { item in
                    tile(title: item.name, selected: model.selected == item.id) {
                        if let image = item.result ?? item.preview { Image(uiImage: image).resizable().scaledToFill() } else { Theme.chip }
                    } action: { model.selected = item.id }
                    .overlay(alignment: .topTrailing) { badge(item) }
                    .contextMenu {
                        if item.status == .done || item.status == .failed { Button("重做这一张") { model.redo(item.id) } }
                        Button("移除", role: .destructive) { model.remove(item.id) }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func badge(_ item: BatchStyleModel.Item) -> some View {
        Group {
            switch item.status {
            case .pending: EmptyView()
            case .running: ProgressView().controlSize(.mini).tint(.white).padding(5).background(Color.black.opacity(0.6), in: Circle())
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent).background(Color.black, in: Circle())
            case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4)).background(Color.black, in: Circle())
            }
        }
        .font(.system(size: 16))
        .padding(5)
    }

    private func tile(title: String, selected: Bool, @ViewBuilder content: () -> some View, action: @escaping () -> Void) -> some View {
        let side: CGFloat = Platform.isMac ? 76 : 66
        return Button(action: action) {
            VStack(spacing: 5) {
                content()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5))
                Text(title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(width: side)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var actions: some View {
        if model.running {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(model.started)))
                    Text("第 \((model.runningIndex ?? 0) + 1) / \(model.items.count) 张 · \(seconds) 秒")
                        .font(.system(size: 14))
                        .monospacedDigit()
                }
                Spacer()
                Button { model.stop() } label: {
                    Text("停止")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .frame(height: 38)
                        .background(Color(red: 0.85, green: 0.28, blue: 0.25), in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
        } else {
            HStack {
                Spacer(minLength: 0)
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
            HStack(spacing: 10) {
                if let item = model.current, item.status == .done || item.status == .failed {
                    Button { model.redo(item.id) } label: {
                        Text("重做这一张")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(Theme.chip, in: Theme.buttonShape)
                            .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.style == nil)
                }
                if model.remaining > 0 || model.items.isEmpty {
                    let ready = model.style != nil && model.remaining > 0
                    Button { model.start() } label: {
                        Text(model.doneCount > 0 ? "继续处理 \(model.remaining) 张" : "开始处理 \(model.remaining) 张")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 42)
                            .background(ready ? Theme.accent : Theme.accent.opacity(0.35), in: Theme.buttonShape)
                            .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
                    }
                    .buttonStyle(.plain)
                    .disabled(!ready)
                }
            }
        }
    }

    private func pickPhotos() {
        if Platform.isMac { pickingFiles = true } else { picking = true }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }
}
