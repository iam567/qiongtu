import SwiftUI
import UIKit

/// 角色详情：看立绘和三视图，生成或重画三视图，让角色出场，删除。
struct CharacterDetailView: View {
    let characterID: UUID
    var isInCast: (UUID) -> Bool
    var toggleCast: (MangaCharacter) -> Void
    var onClose: () -> Void

    enum Page: String, CaseIterable, Identifiable, Hashable {
        case portrait, sheet
        var id: String { rawValue }
        var title: String { self == .portrait ? "立绘" : "三视图" }
    }

    @State private var page: Page = .portrait
    @State private var running = false
    @State private var started = Date()
    @State private var aiError: String?
    @State private var note: String?
    @State private var viewing: UIImage?
    @State private var showSettings = false
    @State private var confirmDelete = false
    @State private var task: Task<Void, Never>?
    private let library = CharacterStore.shared
    private let settings = AISettings.shared

    private var character: MangaCharacter? { library.characters.first { $0.id == characterID } }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let character {
                if Platform.isMac {
                    macLayout(character)
                } else {
                    VStack(spacing: 0) {
                        topBar(character).frame(height: 52)
                        content(character).frame(maxWidth: .infinity, maxHeight: .infinity)
                        panel(character)
                        BottomTabBar(tabs: Page.allCases, title: { $0.title }, selection: $page)
                    }
                }
            }
            if let viewing {
                ResultViewer(image: viewing) { self.viewing = nil }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .confirmationDialog("删除这个角色？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let character {
                    if isInCast(character.id) { toggleCast(character) }
                    library.remove(character)
                }
                onClose()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("立绘和三视图都会从角色库里删掉，不能恢复。")
        }
        .onDisappear { task?.cancel() }
    }

    private func macLayout(_ character: MangaCharacter) -> some View {
        MacWorkbench(title: character.name, onClose: onClose) {
            MacIconButton(symbol: "trash", help: "删除角色") { confirmDelete = true }
                .disabled(running)
        } canvas: {
            content(character)
        } header: {
            SegmentBar(items: Page.allCases, selected: page, title: { $0.title }) { page = $0 }
                .padding(.horizontal, 16)
                .padding(.top, 14)
        } panel: {
            panel(character)
        } footer: {
            EmptyView()
        }
        .ignoresSafeArea()
    }

    private func topBar(_ character: MangaCharacter) -> some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text(character.name).font(.system(size: 16, weight: .bold)).lineLimit(1)
            Spacer()
            Button { confirmDelete = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .disabled(running)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func content(_ character: MangaCharacter) -> some View {
        let image = page == .portrait ? library.image(for: character) : library.sheet(for: character)
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .onTapGesture { viewing = image }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "person.3.sequence")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.dim)
                Text("还没有三视图。\n画出来以后，AI 画漫画时就知道这个角色的侧面和背面。")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder
    private func panel(_ character: MangaCharacter) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text("\(character.artStyle.displayName) · \(character.gender.displayName) · \(character.ageGroup.displayName)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                Spacer()
                ProviderMenu(openSettings: { showSettings = true }, compact: true)
            }
            if !character.bio.isEmpty {
                Text(character.bio)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if running {
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                        Text("正在画三视图… \(seconds) 秒")
                            .font(.system(size: 14))
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("取消") {
                        task?.cancel()
                        running = false
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 10)
            } else {
                HStack(spacing: 10) {
                    Button { makeSheet() } label: {
                        Label(character.sheetFile == nil ? "画三视图" : "重画三视图", systemImage: "person.3.sequence.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Theme.accent, in: Theme.buttonShape)
                    }
                    .buttonStyle(.plain)
                    Button { toggleCast(character) } label: {
                        Text(isInCast(character.id) ? "取消出场" : "让它出场")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 104, height: 44)
                            .background(Theme.chip, in: Theme.buttonShape)
                    }
                    .buttonStyle(.plain)
                }
                Text(note ?? "三视图以立绘为准，把正面、侧面、背面画在一张横图上，计一次费。")
                    .font(.system(size: 11))
                    .foregroundStyle(note == nil ? Theme.dim : Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AIFailureView(message: aiError) { makeSheet() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.sheet)
    }

    private func makeSheet() {
        guard !running else { return }
        guard settings.isConfigured(settings.active) else {
            aiError = "还没有设置 \(settings.active.shortTitle) 的 API Key。"
            return
        }
        aiError = nil
        note = nil
        running = true
        started = Date()
        task = Task {
            do {
                let cost = try await library.generateSheet(for: characterID)
                guard !Task.isCancelled else { return }
                running = false
                page = .sheet
                note = cost.map { "三视图画好了，这次约 $\(String(format: "%.3f", $0))。" } ?? "三视图画好了。"
            } catch is CancellationError {
                running = false
            } catch {
                guard !Task.isCancelled else { return }
                running = false
                aiError = error.localizedDescription
            }
        }
    }
}
