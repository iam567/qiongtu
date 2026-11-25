import SwiftUI
import UIKit

/// 漫画人生：把生活照片画成一页漫画。风格和指令来自 LifeManga，界面和修图编辑器一致。
@MainActor
@Observable
final class MangaModel {
    struct BubbleMode: Identifiable, Hashable {
        let id: String
        let title: String
    }
    static let bubbleModes = [
        BubbleMode(id: "chinese", title: "中文台词"), BubbleMode(id: "japanese", title: "日文台词"),
        BubbleMode(id: "english", title: "英文台词"), BubbleMode(id: "empty", title: "气泡留空"),
        BubbleMode(id: "none", title: "不画气泡"),
    ]

    var photos: [UIImage] = []
    var style: MangaStyle = .shonenJump
    var isColor = false
    var bubbleMode = "chinese"
    var note = ""
    /// 续接：把上一页一起发给 AI，画风、人物和剧情接着往下画。
    var continueFromLast = false
    /// 这一页要出场的角色（来自角色库），最多 4 个。
    var cast: [MangaCharacter] = []

    var pages: [UIImage] = []
    var pageIndex = 0
    var running = false
    var started = Date()
    var aiError: String?
    var usageText: String?

    @ObservationIgnored private var task: Task<Void, Never>?

    var currentPage: UIImage? { pages.indices.contains(pageIndex) ? pages[pageIndex] : nil }

    func add(_ images: [UIImage]) {
        let room = max(0, 8 - photos.count)
        photos.append(contentsOf: images.prefix(room).map { AIOneShot.prepared($0, maxSide: 2048) })
    }

    func generate() {
        guard !running else { return }
        guard !photos.isEmpty else {
            aiError = "先在\u{201C}素材\u{201D}里添加至少一张照片。"
            return
        }
        guard AISettings.shared.endpoint() != nil else {
            aiError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        let previous = continueFromLast ? pages.last : nil
        // 指令的拼法和 LifeManga 一致：风格 → 气泡 → 续接 → 补充说明。
        var parts = [style.effectivePrompt(isColor: isColor), BubbleDirective.simpleMode(bubbleMode)]
        if previous != nil { parts.append(BubbleDirective.continuityDirective) }
        // 角色库里已经删掉的角色不再带上。
        cast = cast.filter { c in CharacterStore.shared.characters.contains { $0.id == c.id } }
        var castImages = cast.compactMap { CharacterStore.shared.image(for: $0) }
        let castReady = castImages.count == cast.count
        if castReady, let directive = CharacterPrompts.directive(for: cast) {
            parts.append(directive)
            // 有三视图的角色把三视图也带上，AI 才知道侧面和背面长什么样。接口一次最多 16 张图，超了就不带。
            let sheets = cast.compactMap { CharacterStore.shared.sheet(for: $0) }
            let used = (previous == nil ? 0 : 1) + photos.count + castImages.count
            if !sheets.isEmpty, used + sheets.count <= 16 {
                castImages += sheets
                parts.append("Some characters also have a three-view TURNAROUND SHEET attached after the character portraits (front, side and back of the same character). Use it only to keep the character's side and back views consistent; never copy the sheet layout itself into the manga page.")
            }
        }
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { parts.append("Additional user note: " + extra) }
        let prompt = parts.joined(separator: "\n\n")
        // 图片顺序和 LifeManga 一致：上一页 → 照片 → 角色设定图。
        let images = (previous.map { [$0] } ?? []) + photos + (castReady ? castImages : [])

        aiError = nil
        usageText = nil
        running = true
        started = Date()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await AIOneShot.run(prompt: prompt, images: images)
                guard !Task.isCancelled else { return }
                self.pages.append(result.image)
                self.pageIndex = self.pages.count - 1
                self.usageText = result.usage?.summary
                self.running = false
            } catch is CancellationError {
                self.running = false
            } catch {
                guard !Task.isCancelled else { return }
                self.running = false
                self.aiError = error.localizedDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }

    func toggleCast(_ character: MangaCharacter) {
        if let index = cast.firstIndex(where: { $0.id == character.id }) {
            cast.remove(at: index)
        } else if cast.count < 4 {
            cast.append(character)
        }
    }
}

struct MangaView: View {
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case material, cast, style, bubble, draw
        var id: String { rawValue }
        var title: String {
            switch self {
            case .material: return "素材"
            case .cast: return "角色"
            case .style: return "风格"
            case .bubble: return "台词"
            case .draw: return "生成"
            }
        }
    }

    @State private var model = MangaModel()
    @State private var tab: Tab = .material
    /// 走到过的最远一步：之前的步骤随时能点回去改，后面的要一步步走过去。
    @State private var reached: Tab = .material
    @State private var picking = false
    @State private var exports: [MacExport] = []
    @State private var viewing: UIImage?
    @State private var showSettings = false
    @State private var creatingCharacter = false
    @State private var detail: MangaCharacter?
    @State private var toast: String?
    private let settings = AISettings.shared
    private let library = CharacterStore.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if Platform.isMac {
                macLayout
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    stepBar
                    panel
                    stepFooter
                }
                .ignoresSafeArea(.keyboard)
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
            if let viewing {
                ResultViewer(image: viewing) { self.viewing = nil }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        #if DEBUG
        .onAppear { if let t = Tab(rawValue: ProcessInfo.processInfo.environment["XIUTU_TAB"] ?? "") { tab = t; reached = t } }
        #endif
        .navigationBarBackButtonHidden(true)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .fullScreenCover(isPresented: $creatingCharacter) {
            CharacterCreateView { creatingCharacter = false }
        }
        .fullScreenCover(item: $detail) { character in
            CharacterDetailView(characterID: character.id,
                                isInCast: { id in model.cast.contains { $0.id == id } },
                                toggleCast: { c in model.toggleCast(c) },
                                onClose: { detail = nil })
        }
        .imageSource(isPresented: $picking, limit: max(1, 8 - model.photos.count)) { loaders in
            Task {
                var images: [UIImage] = []
                for load in loaders {
                    if let data = await load(), let image = UIImage(data: data) { images.append(image) }
                }
                model.add(images)
            }
        }
        .macExport($exports) { _ in
            MacSession.shared.editorDirty = false
            show("已导出")
        }
        // Mac：拖进窗口的图片当素材。
        .onChange(of: MacSession.shared.dropped, initial: true) {
            let files = MacSession.shared.dropped
            guard !files.isEmpty else { return }
            MacSession.shared.dropped = []
            Task {
                var images: [UIImage] = []
                for file in files {
                    if let image = await PhotoLibrary.image(assetID: "", fileURL: file) { images.append(image) }
                }
                model.add(images)
            }
        }
        .onChange(of: model.pages.count) { if Platform.isMac, !model.pages.isEmpty { MacSession.shared.editorDirty = true } }
    }

    private var macLayout: some View {
        MacWorkbench(title: "漫画人生", onClose: onClose) {
            if let page = model.currentPage {
                Button {
                    exports = [MacExport(page, name: "漫画人生-\(model.pageIndex + 1)", source: "漫画人生")].compactMap { $0 }
                } label: { Text("导出").macProminent() }
                .buttonStyle(.plain)
            }
        } canvas: {
            content
        } header: {
            stepBar.padding(.top, 4)
        } panel: {
            panel
        } footer: {
            stepFooter
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("漫画人生").font(.system(size: 16, weight: .bold))
            Spacer()
            Button {
                guard let page = model.currentPage else { return }
                Task {
                    let ok = await AIOneShot.saveToPhotos(page, source: "漫画人生")
                    toast = ok ? "已保存到相册" : "保存失败，请检查相册权限"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    toast = nil
                }
            } label: {
                Text("保存")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .opacity(model.currentPage == nil ? 0 : 1)
            .disabled(model.currentPage == nil)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 上半部分

    @ViewBuilder
    private var content: some View {
        if let page = model.currentPage {
            VStack(spacing: 8) {
                Image(uiImage: page)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .onTapGesture { viewing = page }
                if model.pages.count > 1 {
                    HScroll {
                        HRow(spacing: 8) {
                            ForEach(model.pages.indices, id: \.self) { index in
                                Chip(title: "第 \(index + 1) 页", selected: model.pageIndex == index) { model.pageIndex = index }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .padding(.bottom, 8)
        } else if model.photos.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "book.pages")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.dim)
                Text("添加 1–8 张照片")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
        } else {
            let columns = Platform.isMac ? [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 6)]
                : Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.photos.indices, id: \.self) { index in
                        Color(white: 0.12)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(Image(uiImage: model.photos[index]).resizable().scaledToFill())
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: 步骤

    private var steps: [Tab] { Tab.allCases }
    private func index(_ t: Tab) -> Int { steps.firstIndex(of: t) ?? 0 }

    /// 这一步能不能往下走。
    private var canAdvance: Bool {
        switch tab {
        case .material: return !model.photos.isEmpty
        default: return true
        }
    }

    private func go(_ t: Tab) {
        withAnimation(.easeOut(duration: 0.15)) {
            tab = t
            if index(t) > index(reached) { reached = t }
        }
    }

    /// 顶部的步骤条：走过的步骤可以点回去，没走到的点不了。
    private var stepBar: some View {
        HStack(spacing: 0) {
            ForEach(steps) { step in
                let i = index(step)
                let current = step == tab
                let done = i < index(reached) || (i <= index(reached) && !current)
                let open = i <= index(reached)
                Button { if open { go(step) } } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(current ? Theme.accent : (open ? Color.white.opacity(0.16) : Color.clear))
                                .overlay(Circle().stroke(open ? Color.clear : Color.white.opacity(0.25), lineWidth: 1))
                            if done && !current {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                            } else {
                                Text("\(i + 1)").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(current ? Color.black : (open ? Color.white : Theme.dim))
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(step.title)
                            .font(.system(size: 13, weight: current ? .bold : .regular))
                            .foregroundStyle(current ? Color.white : (open ? Color.white.opacity(0.8) : Theme.dim))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!open || model.running)
                if step != steps.last {
                    Rectangle()
                        .fill(i < index(reached) ? Theme.accent.opacity(0.6) : Color.white.opacity(0.15))
                        .frame(width: 10, height: 1.5)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.sheet)
    }

    /// 底部：上一步 / 下一步。最后一步换成生成按钮（在面板里）。
    private var stepFooter: some View {
        HStack(spacing: 10) {
            if tab != steps.first {
                Button { go(steps[index(tab) - 1]) } label: {
                    Label("上一步", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                .disabled(model.running)
            }
            if tab != steps.last {
                Button { go(steps[index(tab) + 1]) } label: {
                    HStack(spacing: 6) {
                        Text(tab == .cast && model.cast.isEmpty ? "跳过" : "下一步")
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(canAdvance ? Theme.accent : Theme.accent.opacity(0.35), in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                .disabled(!canAdvance)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Theme.sheet)
    }

    // MARK: 二、三级选项

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 10) {
            switch tab {
            case .material: materialPanel
            case .cast: castPanel
            case .style: stylePanel
            case .bubble: bubblePanel
            case .draw: drawPanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sheet)
    }

    private var materialPanel: some View {
        VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    Button { picking = true } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                            Text("添加").font(.system(size: 11))
                        }
                        .foregroundStyle(.black)
                        .frame(width: 62, height: 62)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.photos.count >= 8)
                    ForEach(model.photos.indices, id: \.self) { index in
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: model.photos[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Button { model.photos.remove(at: index) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Color.black.opacity(0.7), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .padding(3)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                Chip(title: "续接上一页", selected: model.continueFromLast) { model.continueFromLast.toggle() }
                    .opacity(model.pages.isEmpty ? 0.35 : 1)
                    .disabled(model.pages.isEmpty)
                    .fixedSize(horizontal: Platform.isMac, vertical: false)
                Spacer()
            }
        }
    }

    /// 角色库：点一下让角色出场（再点取消），长按可以看大图或删除。
    private var castPanel: some View {
        VStack(spacing: 10) {
            HScroll {
                HRow(alignment: .top, spacing: 10) {
                    Button { creatingCharacter = true } label: {
                        VStack(spacing: 6) {
                            VStack(spacing: 4) {
                                Image(systemName: "plus").font(.system(size: 18, weight: .semibold))
                                Text("新建").font(.system(size: 11))
                            }
                            .foregroundStyle(.black)
                            .frame(width: 66, height: 88)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .buttonStyle(.plain)
                    ForEach(library.characters) { character in
                        let selected = model.cast.contains { $0.id == character.id }
                        Button { model.toggleCast(character) } label: {
                            VStack(spacing: 6) {
                                ZStack(alignment: .topTrailing) {
                                    Color(white: 0.14)
                                    if let image = library.image(for: character) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 66, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                                )
                                .overlay(alignment: .bottomLeading) {
                                    if character.sheetFile != nil {
                                        Text("三视图")
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(.black)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 2)
                                            .background(Color.white.opacity(0.9), in: Capsule())
                                            .padding(4)
                                    }
                                }
                                .overlay(alignment: .topTrailing) {
                                    if selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Theme.accent)
                                            .background(Color.black, in: Circle())
                                            .padding(4)
                                    }
                                }
                                Text(character.name)
                                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Theme.accent : Color.white)
                                    .lineLimit(1)
                                    .frame(width: 70)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("角色详情 / 三视图") { detail = character }
                            Button("删除角色", role: .destructive) {
                                model.cast.removeAll { $0.id == character.id }
                                library.remove(character)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            if !model.cast.isEmpty {
                Text("出场：\(model.cast.map(\.name).joined(separator: "、"))")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stylePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip(title: "黑白", selected: !model.isColor) { model.isColor = false }
                Chip(title: "彩色", selected: model.isColor) { model.isColor = true }
                Spacer()
            }
            HScroll {
                HRow(spacing: 10) {
                    ForEach(MangaStyle.allCases) { style in
                        let selected = model.style == style
                        Button { model.style = style } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(style.displayName)
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(selected ? Theme.accent : Color.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                Text(style.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Theme.dim)
                                    .lineLimit(Platform.isMac ? nil : 3)
                            }
                            .optionCard(width: 118)
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
                .padding(.vertical, 2)
            }
        }
    }

    private var bubblePanel: some View {
        VStack(spacing: 10) {
            ChipRow(items: MangaModel.bubbleModes, title: { $0.title }, isSelected: { model.bubbleMode == $0.id }) { model.bubbleMode = $0.id }
        }
    }

    @ViewBuilder
    private var drawPanel: some View {
        if !settings.isConfigured(settings.active) {
            NeedsKeyView { showSettings = true }
        } else if model.running {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(model.started)))
                    Text("\(settings.active.shortTitle) 正在画… \(seconds) 秒")
                        .font(.system(size: 14))
                        .monospacedDigit()
                }
                Spacer()
                Button("取消") { model.cancel() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 22)
        } else {
            HStack(spacing: 8) {
                Text("\(model.style.displayName) · \(model.isColor ? "彩色" : "黑白") · \(model.photos.count) 张照片" + (model.cast.isEmpty ? "" : " · \(model.cast.count) 个角色"))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer()
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
            Button { model.generate() } label: {
                Label(model.pages.isEmpty ? "画一页漫画" : (model.continueFromLast ? "接着画下一页" : "再画一页"), systemImage: "pencil.and.outline")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent, in: Theme.buttonShape)
                    .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
            }
            .buttonStyle(.plain)
            if let usage = model.usageText {
                Text(usage)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            AIFailureView(message: model.aiError) { model.generate() }
        }
    }
}
