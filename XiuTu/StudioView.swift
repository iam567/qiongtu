import SwiftUI
import WebKit

/// 摄影棚。布局和修图编辑器一致：上面是照片或套图，底部一级菜单，菜单上方是二、三级选项。
struct StudioView: View {
    var assetID = ""
    /// Mac：从文件打开的照片。
    var fileURL: URL?
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case scene, person, camera, mood, shoot
        var id: String { rawValue }
        var title: String {
            switch self {
            case .scene: return "场景"
            case .person: return "人物"
            case .camera: return "摄影"
            case .mood: return "氛围"
            case .shoot: return "拍摄"
            }
        }

        /// 拍人物：选场景、人物、摄影；拍场景：照片里的场景就是拍摄对象，只剩摄影、氛围。
        static func list(_ subject: SubjectMode) -> [Tab] {
            subject == .scene ? [.camera, .mood, .shoot] : [.scene, .person, .camera, .shoot]
        }
    }
    enum PersonGroup: String, CaseIterable, Identifiable {
        case gender, persona, age, beauty, retouch, hair
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gender: return "性别"
            case .persona: return "人设"
            case .age: return "年龄"
            case .beauty: return "美颜"
            case .retouch: return "精修部位"
            case .hair: return "发色"
            }
        }
    }
    enum CameraGroup: String, CaseIterable, Identifiable {
        case photographer, equipment, time, brands
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photographer: return "摄影师"
            case .equipment: return "器材"
            case .time: return "时段"
            case .brands: return "品牌单品"
            }
        }

        /// 拍场景时没有时段（在"氛围"里）和品牌单品。
        static func list(_ subject: SubjectMode) -> [CameraGroup] {
            subject == .scene ? [.photographer, .equipment] : allCases
        }
    }

    @State private var model = StudioModel()
    @State private var tab: Tab = .scene
    /// 走到过的最远一步。
    @State private var reached: Tab = .scene
    @State private var personGroup: PersonGroup = .gender
    @State private var cameraGroup: CameraGroup = .photographer
    @State private var moodGroup: SceneLook.Group = .time
    @State private var viewing: UIImage?
    @State private var showSettings = false
    @State private var toast: String?
    @State private var exports: [MacExport] = []
    private let settings = AISettings.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            StudioEngineHost(webView: model.engine.webView)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
            if Platform.isMac {
                macLayout
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 还没判断出拍人物还是拍场景时，先不把菜单亮出来，免得闪一下又换掉。
                    Group {
                        stepBar
                        panel
                        stepFooter
                    }
                    .opacity(model.isLoading ? 0 : 1)
                }
                .ignoresSafeArea(.keyboard)
            }
            if model.isLoading {
                ProgressView().controlSize(.large).tint(.white)
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
                .allowsHitTesting(false)
            }
            if let viewing {
                ResultViewer(image: viewing) { self.viewing = nil }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .task {
            await model.load(assetID: assetID, fileURL: fileURL)
            #if DEBUG
            if ProcessInfo.processInfo.environment["XIUTU_SUBJECT"] == "person" { model.subject = .person }
            #endif
            fitMenus()
            #if DEBUG
            if let t = Tab(rawValue: ProcessInfo.processInfo.environment["XIUTU_TAB"] ?? "") { go(t) }
            #endif
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .macExport($exports) { count in
            MacSession.shared.editorDirty = false
            show("已导出 \(count) 张")
        }
        .onChange(of: model.doneCount) { if Platform.isMac, model.doneCount > 0 { MacSession.shared.editorDirty = true } }
    }

    private var stepBar: some View {
        StepBar(steps: Tab.list(model.subject), current: tab, reached: reached,
                title: { $0.title }, disabled: model.running) { go($0) }
    }

    private var stepFooter: some View {
        StepFooter(isFirst: tab == Tab.list(model.subject).first, isLast: tab == Tab.list(model.subject).last,
                   disabled: model.running,
                   back: { step(-1) }, next: { step(1) })
    }

    private var macLayout: some View {
        MacWorkbench(title: "摄影棚", onClose: onClose) {
            if model.doneCount > 0 {
                Button {
                    exports = model.shots.compactMap { shot in
                        MacExport(shot.image, name: "摄影棚-\(shot.id + 1)", source: "摄影棚")
                    }
                } label: { Text("全部导出").macProminent() }
                .buttonStyle(.plain)
            }
        } canvas: {
            content
        } header: {
            stepBar.padding(.top, 4).opacity(model.isLoading ? 0 : 1)
        } panel: {
            panel.opacity(model.isLoading ? 0 : 1)
        } footer: {
            stepFooter.opacity(model.isLoading ? 0 : 1)
        }
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }

    private func go(_ t: Tab) {
        let list = Tab.list(model.subject)
        withAnimation(.easeOut(duration: 0.15)) {
            tab = t
            if (list.firstIndex(of: t) ?? 0) > (list.firstIndex(of: reached) ?? 0) { reached = t }
        }
    }

    private func step(_ delta: Int) {
        let list = Tab.list(model.subject)
        guard let i = list.firstIndex(of: tab), list.indices.contains(i + delta) else { return }
        go(list[i + delta])
    }

    /// 换了主体以后，步骤换了一套，从第一步重新走。
    private func fitMenus() {
        tab = Tab.list(model.subject)[0]
        reached = tab
        if !CameraGroup.list(model.subject).contains(cameraGroup) { cameraGroup = .photographer }
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("摄影棚").font(.system(size: 16, weight: .bold))
            Spacer()
            Button {
                Task {
                    let n = await model.saveAll()
                    toast = n > 0 ? "已保存 \(n) 张到相册" : "保存失败，请检查相册权限"
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    toast = nil
                }
            } label: {
                Text("全部保存")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .opacity(model.doneCount > 0 ? 1 : 0)
            .disabled(model.doneCount == 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 上半部分：原图或套图

    @ViewBuilder
    private var content: some View {
        if model.shots.isEmpty {
            if let image = model.original {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
        } else {
            ScrollView {
                // 横幅的照片一行放一张，其余一行两张。
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(model.shots) { shot in
                        shotCard(shot)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
    }

    private var columns: [GridItem] {
        if Platform.isMac { return [GridItem(.adaptive(minimum: model.shotAspect > 1.2 ? 380 : 260, maximum: 560), spacing: 8)] }
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: model.shotAspect > 1.2 ? 1 : 2)
    }

    private func shotCard(_ shot: StudioModel.Shot) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel)
            if let image = shot.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    switch shot.status {
                    case .running:
                        ProgressView().tint(.white)
                        Text("正在拍…").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        Text(shot.error ?? "失败").font(.system(size: 11)).foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 8)
                    default:
                        Image(systemName: "clock").foregroundStyle(Theme.dim)
                        Text("排队中").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(([String(shot.id + 1), shot.framingTitle, shot.photographer]).filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .aspectRatio(model.shotAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let image = shot.image { viewing = image } }
    }

    // MARK: 二、三级选项

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 10) {
            SubjectModeBar(selected: model.subject, prefix: "拍", disabled: model.running) { mode in
                model.subject = mode
                fitMenus()
            }
            switch tab {
            case .scene: scenePanel
            case .person: personPanel
            case .camera: cameraPanel
            case .mood: moodPanel
            case .shoot:
                if model.subject == .scene { sceneShootPanel } else { shootPanel }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sheet)
    }

    private var scenePanel: some View {
        VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    ForEach(model.catalog.categories.indices, id: \.self) { index in
                        let title = model.catalog.categories[index].title
                        Chip(title: StudioIcons.plain(title), symbol: StudioIcons.categorySymbol(title),
                             selected: model.categoryIndex == index) {
                            model.selectCategory(index)
                        }
                    }
                }
            }
            // 原背景在最前面，用自己这张照片做缩略图；后面是这一类的场景。
            HScroll {
                HRow(alignment: .top, spacing: 8) {
                    PickTile(title: "原背景", image: model.thumbs["original"], symbol: "photo",
                             selected: model.sceneID == "keep") { model.sceneID = "keep" }
                    if !Platform.isMac {
                        Rectangle().fill(Theme.chip).frame(width: 1, height: StudioLooks.tileHeight - 16).padding(.top, 8)
                    }
                    ForEach(model.scenes) { scene in
                        let look = StudioIcons.sceneSymbol(scene.title, category: model.catalog.categories[model.categoryIndex].title)
                        PickTile(title: StudioIcons.sceneName(scene.title), symbol: look.0, tint: look.1,
                                 selected: model.sceneID == scene.id) { model.sceneID = scene.id }
                    }
                }
                .padding(.vertical, 2)
            }
            .id(model.categoryIndex)
        }
    }

    private var personPanel: some View {
        VStack(spacing: 10) {
            SymbolChipRow(items: PersonGroup.allCases, title: { groupTitle($0) },
                          symbol: { StudioIcons.personGroupSymbol($0.rawValue) }, isSelected: { personGroup == $0 }) { personGroup = $0 }
            switch personGroup {
            case .gender:
                SymbolChipRow(items: model.catalog.gender, title: { $0.title }, symbol: { StudioIcons.genderSymbols[$0.id] },
                              isSelected: { model.gender == $0.id }) { model.gender = $0.id }
            case .persona:
                SymbolChipRow(items: model.catalog.persona, title: { $0.title }, symbol: { StudioIcons.personaSymbols[$0.id] },
                              isSelected: { model.persona == $0.id }) { model.persona = $0.id }
            case .age:
                SymbolChipRow(items: model.catalog.age, title: { $0.title }, symbol: { StudioIcons.ageSymbols[$0.id] },
                              isSelected: { model.age == $0.id }) { model.age = $0.id }
            case .beauty:
                SymbolChipRow(items: model.catalog.beauty, title: { $0.title }, symbol: { StudioIcons.beautySymbols[$0.id] },
                              isSelected: { model.beauty == $0.id }) { model.beauty = $0.id }
            case .retouch:
                SymbolChipRow(items: model.catalog.retouchParts, title: { $0.title }, symbol: { StudioIcons.retouchSymbols[$0.id] },
                              isSelected: { model.retouchParts.contains($0.id) }) { toggle(&model.retouchParts, $0.id) }
            case .hair:
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(model.catalog.hairColors) { hair in
                            SwatchChip(title: hair.title, swatch: StudioIcons.swatch(hair.swatch),
                                       selected: model.hairColors.contains(hair.id)) { toggle(&model.hairColors, hair.id) }
                        }
                    }
                }
            }
        }
    }

    private func groupTitle(_ group: PersonGroup) -> String {
        switch group {
        case .retouch: return model.retouchParts.isEmpty ? group.title : "\(group.title) \(model.retouchParts.count)"
        case .hair: return model.hairColors.isEmpty ? group.title : "\(group.title) \(model.hairColors.count)"
        default: return group.title
        }
    }

    /// 摄影师格子上的小图："不指定"是原图，"随机大师"是骰子。
    private func photographerTile(_ p: StudioModel.Option) -> some View {
        let image: UIImage? = p.id == "random" ? nil : model.thumbs[p.id == "none" ? "original" : "p.\(p.id)"]
        return PickTile(title: StudioIcons.photographerName(p), image: image,
                        symbol: p.id == "random" ? "dice.fill" : "camera.aperture", tint: .purple,
                        selected: model.photographer == p.id) { model.photographer = p.id }
    }

    /// 器材格子：胶片和相机是套了色调的小图；"自动""随机"是图标。
    private func equipmentTile(_ e: StudioModel.Option) -> some View {
        let symbol = e.id == "random" ? "dice.fill" : (e.id == "auto" ? "wand.and.stars" : "film.fill")
        return PickTile(title: StudioIcons.equipmentName(e), image: model.thumbs["e.\(e.id)"], symbol: symbol, tint: .purple,
                        selected: model.equipment == e.id) { model.equipment = e.id }
    }

    private var cameraPanel: some View {
        VStack(spacing: 10) {
            SymbolChipRow(items: CameraGroup.list(model.subject),
                          title: { $0 == .brands && !model.brands.isEmpty ? "\($0.title) \(model.brands.count)" : $0.title },
                          symbol: { StudioIcons.cameraGroupSymbol($0.rawValue) },
                          isSelected: { cameraGroup == $0 }) { cameraGroup = $0 }
            switch cameraGroup {
            case .photographer:
                TileRow(items: model.catalog.photographers) { photographerTile($0) }
            case .equipment:
                TileRow(items: model.catalog.equipment) { equipmentTile($0) }
            case .time:
                TileRow(items: model.catalog.timeOfDay) { t in
                    let look = StudioIcons.lightSymbol(t.id)
                    PickTile(title: StudioIcons.plain(t.title), symbol: look.0, tint: look.1,
                             selected: model.timeOfDay == t.id) { model.timeOfDay = t.id }
                }
            case .brands:
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(model.catalog.brands.indices, id: \.self) { index in
                            let title = model.catalog.brands[index].title
                            Chip(title: StudioIcons.plain(title), symbol: StudioIcons.brandCategorySymbol(title),
                                 selected: model.brandCategoryIndex == index) {
                                model.brandCategoryIndex = index
                            }
                        }
                    }
                }
                if model.catalog.brands.indices.contains(model.brandCategoryIndex) {
                    SymbolChipRow(items: model.catalog.brands[model.brandCategoryIndex].items, title: { $0.title },
                                  symbol: { StudioIcons.brandItemSymbol($0, category: model.catalog.brands[model.brandCategoryIndex].title) },
                                  isSelected: { model.brands.contains($0.id) }) { toggle(&model.brands, $0.id) }
                        .id(model.brandCategoryIndex)
                }
            }
        }
    }

    /// 拍场景：时间、天气、季节、光线，每组第一项都是"保持原样"（用原图做缩略图）。
    private var moodPanel: some View {
        VStack(spacing: 10) {
            SymbolChipRow(items: SceneLook.Group.allCases, title: { group in
                let picked = group.option(model.scenePicks[group])
                return picked.id == SceneLook.keep ? group.title : "\(group.title) · \(picked.title)"
            }, symbol: { StudioIcons.moodGroupSymbol($0) }, isSelected: { moodGroup == $0 }) { moodGroup = $0 }
            TileRow(items: moodGroup.options) { option in
                let look = StudioIcons.lightSymbol(option.id)
                PickTile(title: option.title, image: option.id == SceneLook.keep ? model.thumbs["original"] : nil,
                         symbol: look.0, tint: look.1,
                         selected: moodGroup.option(model.scenePicks[moodGroup]).id == option.id) {
                    model.scenePicks[moodGroup] = option.id
                }
            }
            .id(moodGroup)
        }
    }

    /// 拍场景：张数、拍法（可多选）。
    @ViewBuilder
    private var sceneShootPanel: some View {
        if !settings.isConfigured(settings.active) {
            NeedsKeyView { showSettings = true }
        } else if model.running {
            runningRow
        } else {
            OptionLine(openSettings: { showSettings = true }) {
                Text("张数").font(.system(size: 13)).foregroundStyle(Theme.dim)
                ForEach(StudioScene.counts, id: \.self) { n in
                    Chip(title: "\(n)", selected: model.sceneCount == n) { model.sceneCount = n }
                }
            }
            SymbolChipRow(items: StudioScene.variations, title: { $0.title }, symbol: { StudioIcons.variationSymbols[$0.id] },
                          isSelected: { model.sceneVariations.contains($0.id) }) { model.toggleSceneVariation($0.id) }
            HStack(spacing: 10) {
                Button { model.start(explore: false) } label: {
                    Label("开始拍 \(model.sceneCount) 张", systemImage: "camera.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                Button { model.start(explore: true) } label: {
                    Text("试拍 6 张")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 44)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            AIFailureView(message: model.aiError) { model.retry() }
        }
    }

    private var runningRow: some View {
        HStack(spacing: 12) {
            ProgressView().tint(.white)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(model.started)))
                Text("正在拍第 \((model.currentIndex ?? 0) + 1) / \(model.shots.count) 张 · \(seconds) 秒")
                    .font(.system(size: 14))
                    .monospacedDigit()
            }
            Spacer()
            Button("停止") { model.cancel() }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 22)
    }

    @ViewBuilder
    private var shootPanel: some View {
        if !settings.isConfigured(settings.active) {
            NeedsKeyView { showSettings = true }
        } else if model.running {
            runningRow
        } else {
            OptionLine(openSettings: { showSettings = true }) {
                Text("张数").font(.system(size: 13)).foregroundStyle(Theme.dim)
                ForEach(model.catalog.counts, id: \.self) { n in
                    Chip(title: "\(n)", selected: model.count == n) { model.count = n }
                }
            }
            HStack(spacing: 10) {
                Button { model.start(explore: false) } label: {
                    Label("开始拍 \(model.count) 张", systemImage: "camera.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Theme.accent, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                Button { model.start(explore: true) } label: {
                    Text("试拍 6 张")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 44)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            if model.spent > 0 {
                Text("已花费约 $\(String(format: "%.2f", model.spent))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            AIFailureView(message: model.aiError) { model.retry() }
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }
}

extension StudioView.PersonGroup: Hashable {}
extension StudioView.CameraGroup: Hashable {}

private struct StudioEngineHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.clipsToBounds = true
        container.addSubview(webView)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
