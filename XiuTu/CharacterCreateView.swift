import SwiftUI
import UIKit

/// 新建角色：一张照片 → 选一种或多种画风 → 自动生成角色立绘，生成一张就存进角色库一张。
@MainActor
@Observable
final class CharacterCreateModel {
    struct Result: Identifiable {
        enum Status { case pending, running, done, failed }
        let style: CharacterArtStyle
        var status: Status = .pending
        var image: UIImage?
        var error: String?
        var note: String?
        var id: String { style.rawValue }
    }

    var photo: UIImage?
    var name = ""
    var bio = ""
    var ageGroup: CharacterAgeGroup = .youngAdult
    var gender: CharacterGender = .female
    var styles: Set<CharacterArtStyle> = [.jpAnime]
    /// 立绘画好后接着画三视图（每个角色多调用一次）。
    var withSheet = false

    var results: [Result] = []
    var running = false
    var started = Date()
    var aiError: String?
    var spent: Double = 0
    var savedCount = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    var currentIndex: Int? { results.firstIndex { $0.status == .running } }

    func toggle(_ style: CharacterArtStyle) {
        if styles.contains(style) { styles.remove(style) } else { styles.insert(style) }
    }

    func start() {
        guard !running else { return }
        guard let photo else {
            aiError = "先选一张照片。"
            return
        }
        guard !styles.isEmpty else {
            aiError = "至少选一种画风。"
            return
        }
        guard AISettings.shared.endpoint() != nil else {
            aiError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        let characterName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "角色 \(CharacterStore.shared.characters.count + 1)" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let characterBio = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let age = ageGroup
        let sex = gender
        let wantSheet = withSheet
        // 按画风列表的固定顺序排，方便对照。
        results = CharacterArtStyle.allCases.filter { styles.contains($0) }.map { Result(style: $0) }
        aiError = nil
        running = true
        started = Date()
        task = Task { [weak self] in
            guard let self else { return }
            var failuresInARow = 0
            for index in self.results.indices {
                if Task.isCancelled { break }
                let style = self.results[index].style
                self.results[index].status = .running
                self.started = Date()
                let prompt = CharacterPrompts.buildCharacterPortraitPrompt(
                    name: characterName, bio: characterBio.isEmpty ? nil : characterBio,
                    ageGroup: age, gender: sex, artStyle: style)
                do {
                    let result = try await AIOneShot.run(prompt: prompt, images: [photo])
                    if Task.isCancelled { break }
                    self.results[index].image = result.image
                    self.results[index].status = .done
                    self.spent += result.usage?.cost ?? 0
                    // 多种画风时在名字后面带上画风，角色库里好分辨。
                    let saveName = self.results.count > 1 ? "\(characterName) · \(style.displayName)" : characterName
                    let saved = CharacterStore.shared.add(name: saveName, bio: characterBio, ageGroup: age, gender: sex,
                                                          artStyle: style, image: result.image)
                    if saved != nil { self.savedCount += 1 }
                    failuresInARow = 0
                    if wantSheet, let saved {
                        // 三视图失败不影响已经存好的立绘，以后可以在角色详情里再生成。
                        self.results[index].status = .running
                        self.results[index].note = "正在画三视图…"
                        do {
                            self.spent += try await CharacterStore.shared.generateSheet(for: saved.id) ?? 0
                            self.results[index].note = "含三视图"
                        } catch is CancellationError {
                            self.results[index].status = .done
                            break
                        } catch {
                            self.results[index].note = "三视图没画成"
                        }
                        self.results[index].status = .done
                    }
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    self.results[index].status = .failed
                    self.results[index].error = error.localizedDescription
                    self.aiError = "\(style.displayName) 失败：\(error.localizedDescription)"
                    failuresInARow += 1
                    if failuresInARow >= 2 { break }
                }
            }
            for index in self.results.indices where self.results[index].status == .running || self.results[index].status == .pending {
                self.results[index].status = .failed
                if self.results[index].error == nil { self.results[index].error = "没有生成" }
            }
            self.running = false
        }
    }

    func cancel() {
        task?.cancel()
        running = false
    }
}

struct CharacterCreateView: View {
    var onClose: () -> Void

    enum Tab: String, CaseIterable, Identifiable, Hashable {
        case profile, style, make
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: return "设定"
            case .style: return "画风"
            case .make: return "生成"
            }
        }
    }
    enum Field: Identifiable {
        case name, bio
        var id: Int { hashValue }
    }

    @State private var model = CharacterCreateModel()
    @State private var tab: Tab = .profile
    @State private var picking = false
    @State private var editing: Field?
    @State private var viewing: UIImage?
    @State private var showSettings = false
    private let settings = AISettings.shared

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if Platform.isMac {
                macLayout
            } else {
                VStack(spacing: 0) {
                    topBar.frame(height: 52)
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    panel
                    BottomTabBar(tabs: Tab.allCases, title: { $0.title }, selection: $tab)
                }
                .ignoresSafeArea(.keyboard)
            }
            if let field = editing {
                TextInputOverlay(initial: field == .name ? model.name : model.bio,
                                 placeholder: field == .name ? "角色名字" : "角色设定，比如：爱笑、总是戴着耳机") { value in
                    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if field == .name { model.name = text } else { model.bio = text }
                    editing = nil
                }
            }
            if let viewing {
                ResultViewer(image: viewing) { self.viewing = nil }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .imageSource(isPresented: $picking) { loaders in
            Task { if let data = await loaders.first?() { setPhoto(UIImage(data: data)) } }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            guard Platform.isMac, !model.running else { return false }
            Task {
                guard let url = await MacRootView.urls(from: providers).first else { return }
                setPhoto(await PhotoLibrary.image(assetID: "", fileURL: url))
            }
            return true
        }
    }

    private func setPhoto(_ image: UIImage?) {
        if let image { model.photo = AIOneShot.prepared(image, maxSide: 2048) }
    }

    private var macLayout: some View {
        MacWorkbench(title: "新建角色", onClose: onClose) {
            if model.savedCount > 0, !model.running {
                Button(action: onClose) { Text("完成").macProminent() }
                    .buttonStyle(.plain)
            }
        } canvas: {
            content
        } header: {
            SegmentBar(items: Tab.allCases, selected: tab, title: { $0.title }) { tab = $0 }
                .padding(.horizontal, 16)
                .padding(.top, 14)
        } panel: {
            panel
        } footer: {
            EmptyView()
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("新建角色").font(.system(size: 16, weight: .bold))
            Spacer()
            Button(action: onClose) {
                Text("完成")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.white, in: Capsule())
            }
            .opacity(model.savedCount > 0 && !model.running ? 1 : 0)
            .disabled(model.savedCount == 0 || model.running)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    // MARK: 上半部分：照片，或者生成结果

    @ViewBuilder
    private var content: some View {
        if !model.results.isEmpty {
            ScrollView {
                LazyVGrid(columns: Platform.isMac ? [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 8)]
                          : Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                    ForEach(model.results) { result in
                        resultCard(result)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else if let photo = model.photo {
            ZStack(alignment: .bottom) {
                Image(uiImage: photo)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                Button { picking = true } label: {
                    Text("换一张照片")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 20)
            }
        } else {
            Button { picking = true } label: {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.rectangle.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.accent)
                    Text("选一张照片")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                    Text("正面、清楚、最好是全身或半身。\nAI 会照着长相、发型和体型画成角色。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func resultCard(_ result: CharacterCreateModel.Result) -> some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel)
            if let image = result.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    switch result.status {
                    case .running:
                        ProgressView().tint(.white)
                        Text("正在画…").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                        Text(result.error ?? "失败").font(.system(size: 11)).foregroundStyle(Theme.dim)
                            .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal, 8)
                    default:
                        Image(systemName: "clock").foregroundStyle(Theme.dim)
                        Text("排队中").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(result.note.map { "\(result.style.displayName) · \($0)" }
                 ?? (result.status == .done ? "\(result.style.displayName) · 已存入角色库" : result.style.displayName))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(6)
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { if let image = result.image { viewing = image } }
    }

    // MARK: 二、三级选项

    @ViewBuilder
    private var panel: some View {
        VStack(spacing: 10) {
            switch tab {
            case .profile: profilePanel
            case .style: stylePanel
            case .make: makePanel
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sheet)
    }

    private var profilePanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if Platform.isMac {
                    MacFieldCell(title: "名字", text: $model.name)
                    MacFieldCell(title: "设定", text: $model.bio)
                } else {
                    fieldCell("名字", value: model.name, placeholder: "可不填") { editing = .name }
                    fieldCell("设定", value: model.bio, placeholder: "可不填") { editing = .bio }
                }
            }
            HStack(spacing: 8) {
                ForEach(CharacterGender.allCases) { item in
                    Chip(title: item.displayName, selected: model.gender == item) { model.gender = item }
                }
                Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(CharacterAgeGroup.allCases) { item in
                            Chip(title: item.displayName, selected: model.ageGroup == item) { model.ageGroup = item }
                        }
                    }
                }
            }
        }
    }

    private func fieldCell(_ title: String, value: String, placeholder: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10)).foregroundStyle(Theme.dim)
                Text(value.isEmpty ? placeholder : value)
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

    private var stylePanel: some View {
        let all = Set(CharacterArtStyle.allCases)
        return VStack(spacing: 10) {
            HStack(spacing: 8) {
                Chip(title: "全部画风", selected: model.styles == all) {
                    model.styles = model.styles == all ? [.jpAnime] : all
                }
                Text("已选 \(model.styles.count) 种，每种生成一张、计一次费")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                Spacer()
            }
            HScroll {
                HRow(spacing: 10) {
                    ForEach(CharacterArtStyle.allCases) { style in
                        let selected = model.styles.contains(style)
                        Button { model.toggle(style) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 13))
                                    Text(style.displayName)
                                        .font(.system(size: 13, weight: .heavy))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(selected ? Theme.accent : Color.white)
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

    @ViewBuilder
    private var makePanel: some View {
        if !settings.isConfigured(settings.active) {
            NeedsKeyView { showSettings = true }
        } else if model.running {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(model.started)))
                    Text("正在画第 \((model.currentIndex ?? 0) + 1) / \(model.results.count) 个 · \(seconds) 秒")
                        .font(.system(size: 14))
                        .monospacedDigit()
                }
                Spacer()
                Button("停止") { model.cancel() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 22)
        } else {
            HStack(spacing: 8) {
                Chip(title: "同时画三视图", selected: model.withSheet) { model.withSheet.toggle() }
                Text("\(model.gender.displayName) · \(model.ageGroup.displayName) · \(model.styles.count) 种画风")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer()
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
            Button { model.start() } label: {
                Label(model.styles.count > 1 ? "生成 \(model.styles.count) 个角色" : "生成角色", systemImage: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent, in: Theme.buttonShape)
            }
            .buttonStyle(.plain)
            Text(model.savedCount > 0
                 ? "已有 \(model.savedCount) 个存进角色库" + (model.spent > 0 ? "，花费约 $\(String(format: "%.2f", model.spent))" : "") + "。不想要的可以回角色库里长按删除。"
                 : (model.withSheet ? "每个角色先画立绘、再画三视图，各计一次费。生成一个就自动存进角色库一个。"
                                    : "生成一个就自动存进角色库一个。三视图也可以以后在角色详情里再画。"))
                .font(.system(size: 11))
                .foregroundStyle(Theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
            AIFailureView(message: model.aiError) { model.start() }
        }
    }
}
