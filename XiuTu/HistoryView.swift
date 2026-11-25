import Photos
import SwiftUI

/// 历史图库：App 里留的那份图。可以设密码、批量删除、一键清空。
struct HistoryView: View {
    var onEdit: (URL) -> Void
    /// 把某张图的处理步骤套到一张新照片上。
    var onApply: (UUID) -> Void
    /// 存成风格，接着批量处理照片。
    var onBatch: (UUID) -> Void = { _ in }
    var onClose: () -> Void

    private let store = HistoryStore.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var unlocked = !HistoryStore.shared.hasPassword
    @State private var selecting = false
    @State private var selected: Set<UUID> = []
    @State private var viewing: HistoryItem?
    @State private var confirmDelete = false
    @State private var confirmClear = false
    @State private var settingPassword = false
    @State private var toast: String?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar.frame(height: 52)
                if !unlocked {
                    HistoryLock(onUnlock: { unlocked = true })
                } else if store.items.isEmpty {
                    Spacer()
                    Text("还没有图片").foregroundStyle(Theme.dim)
                    Spacer()
                } else {
                    grid
                    if selecting { selectionBar }
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
                        .padding(.bottom, 90)
                }
                .allowsHitTesting(false)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // 离开 App 再回来要重新输密码。
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, store.hasPassword {
                unlocked = false
                viewing = nil
                selecting = false
                selected = []
            }
        }
        .fullScreenCover(item: $viewing) { item in
            HistoryViewer(item: item, onEdit: { url in
                viewing = nil
                // 等大图收起来再进编辑器。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onEdit(url) }
            }, onApply: {
                viewing = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onApply(item.id) }
            }, onClose: { viewing = nil })
        }
        .sheet(isPresented: $settingPassword) { HistoryPasswordSheet() }
        .confirmationDialog("删除选中的 \(selected.count) 张？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                store.delete(selected)
                selected = []
                selecting = false
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog("清空历史图库？共 \(store.items.count) 张，删了找不回来。", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("全部删除", role: .destructive) {
                store.clear()
                selected = []
                selecting = false
            }
            Button("取消", role: .cancel) {}
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
            Text(selecting ? "已选 \(selected.count) 张" : "历史图库")
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            if unlocked {
                if !store.items.isEmpty {
                    Button(selecting ? "完成" : "选择") {
                        selecting.toggle()
                        selected = []
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 44)
                }
                Menu {
                    Button {
                        store.setEnabled(!store.enabled)
                    } label: {
                        if store.enabled {
                            Label("保存时存入历史图库", systemImage: "checkmark")
                        } else {
                            Text("保存时存入历史图库")
                        }
                    }
                    Button(store.hasPassword ? "修改密码" : "设置密码") { settingPassword = true }
                    if store.hasPassword {
                        Button("关闭密码") { store.removePassword() }
                    }
                    if !store.items.isEmpty {
                        Divider()
                        Button("清空图库", role: .destructive) { confirmClear = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 19))
                        .frame(width: 44, height: 44)
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(store.items) { item in
                    HistoryCell(item: item, selecting: selecting, selected: selected.contains(item.id))
                        .onTapGesture {
                            if selecting {
                                if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
                            } else {
                                viewing = item
                            }
                        }
                        .contextMenu {
                            Button("保存此风格") { saveStyle(item, batch: false) }
                            Button("用此风格批量处理…") { saveStyle(item, batch: true) }
                        }
                }
            }
            .padding(.bottom, 20)
        }
    }

    private var selectionBar: some View {
        HStack {
            Button(selected.count == store.items.count ? "取消全选" : "全选") {
                selected = selected.count == store.items.count ? [] : Set(store.items.map(\.id))
            }
            Spacer()
            Button {
                Task { await saveSelected() }
            } label: {
                Label("存到相册", systemImage: "square.and.arrow.down")
            }
            .disabled(selected.isEmpty)
            Spacer()
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("删除", systemImage: "trash")
            }
            .disabled(selected.isEmpty)
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 20)
        .frame(height: 56)
        .background(Theme.panel)
    }

    private func saveStyle(_ item: HistoryItem, batch: Bool) {
        Task {
            guard let style = await StyleStore.shared.add(file: store.fileURL(item)) else {
                show("保存失败")
                return
            }
            if batch { onBatch(style.id) } else { show("已保存此风格") }
        }
    }

    private func saveSelected() async {
        var saved = 0
        for item in store.items where selected.contains(item.id) {
            if await HistoryViewer.saveToPhotos(store.fileURL(item)) { saved += 1 }
        }
        show(saved == selected.count ? "已存到相册 \(saved) 张" : "存了 \(saved) 张，\(selected.count - saved) 张失败")
    }

    private func show(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if toast == message { toast = nil }
        }
    }
}

/// 图库里的一格。
private struct HistoryCell: View {
    let item: HistoryItem
    let selecting: Bool
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        Color(white: 0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(item.source)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22))
                        .foregroundStyle(selected ? Theme.accent : Color.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay { if selected { Color.black.opacity(0.25) } }
            .contentShape(Rectangle())
            .task(id: item.id) { image = await HistoryStore.shared.thumbnail(item) }
    }
}

/// 输密码才能进。
private struct HistoryLock: View {
    var onUnlock: () -> Void

    private let store = HistoryStore.shared
    @State private var password = ""
    @State private var wrong = false
    @State private var confirmReset = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            SecureField("密码", text: $password)
                .textContentType(.password)
                .multilineTextAlignment(.center)
                .font(.system(size: 18))
                .padding(.vertical, 12)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 60)
                .focused($focused)
                .onSubmit(unlock)
            if wrong {
                Text("密码不对").font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            }
            Button(action: unlock) {
                Text("解锁")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 160, height: 44)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressStyle())
            Button("忘记密码") { confirmReset = true }
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
            Spacer()
            Spacer()
        }
        .onAppear { focused = true }
        .confirmationDialog("忘记密码只能清空图库后重设。图库里的 \(store.items.count) 张会全部删除，找不回来。",
                            isPresented: $confirmReset, titleVisibility: .visible) {
            Button("清空图库并去掉密码", role: .destructive) {
                store.clear()
                store.removePassword()
                onUnlock()
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func unlock() {
        if store.check(password) {
            onUnlock()
        } else {
            wrong = true
            password = ""
        }
    }
}

/// 设置 / 修改密码。
private struct HistoryPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var first = ""
    @State private var second = ""
    @State private var mismatch = false

    var body: some View {
        VStack(spacing: 14) {
            Text(HistoryStore.shared.hasPassword ? "修改密码" : "设置密码")
                .font(.system(size: 17, weight: .bold))
            SecureField("新密码", text: $first).modifier(Field())
            SecureField("再输一次", text: $second).modifier(Field())
            if mismatch {
                Text("两次输入不一样").font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
            }
            Button {
                if first == second {
                    HistoryStore.shared.setPassword(first)
                    dismiss()
                } else {
                    mismatch = true
                }
            } label: {
                Text("确定")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(PressStyle())
            .disabled(first.isEmpty)
            .opacity(first.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .presentationDetents([.height(280)])
        .presentationBackground(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private struct Field: ViewModifier {
        func body(content: Content) -> some View {
            content
                .textContentType(.newPassword)
                .font(.system(size: 17))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// 看大图：可以继续编辑、存到相册、分享、删除。
struct HistoryViewer: View {
    let item: HistoryItem
    var onEdit: (URL) -> Void
    var onApply: () -> Void = {}
    var onClose: () -> Void

    @State private var image: UIImage?
    @State private var recipe: EditRecipe?
    @State private var showSteps = false
    @State private var confirmDelete = false
    @State private var note: String?

    private var url: URL { HistoryStore.shared.fileURL(item) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(item.source).font(.system(size: 14, weight: .semibold))
                        Text("\(item.date.formatted(date: .numeric, time: .shortened)) · \(item.width) × \(item.height)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dim)
                    }
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                ZoomableCanvas(image: image, handlers: nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let note {
                    Text(note).font(.system(size: 13)).foregroundStyle(Theme.accent).padding(.bottom, 4)
                }
                HStack(spacing: 0) {
                    IconTile(symbol: "slider.horizontal.3", title: "编辑") { onEdit(url) }
                    if recipe != nil {
                        IconTile(symbol: "list.number", title: "步骤") { showSteps = true }
                    }
                    IconTile(symbol: "square.and.arrow.down", title: "存到相册") {
                        Task { note = await Self.saveToPhotos(url) ? "已存到相册" : "保存失败，请检查相册权限" }
                    }
                    ShareLink(item: url) {
                        VStack(spacing: 7) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 22))
                                .frame(width: 44, height: 30)
                            Text("分享").font(.system(size: 12))
                        }
                        .foregroundStyle(.white)
                        .frame(minWidth: 58)
                    }
                    IconTile(symbol: "star", title: "满意脸型") {
                        Task {
                            var ok = false
                            if let data = try? Data(contentsOf: url) { ok = await FavoriteFaceStore.shared.add(from: data) }
                            note = ok ? "已设为满意脸型" : "这张图里没有找到人脸"
                        }
                    }
                    IconTile(symbol: "trash", title: "删除") { confirmDelete = true }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Theme.panel)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSteps) {
            if let recipe {
                RecipeSheet(recipe: recipe) {
                    showSteps = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onApply() }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            recipe = HistoryStore.shared.recipe(item.id)
            let url = url
            image = await Task.detached(priority: .userInitiated) {
                guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
                      let cg = Renderer.shared.rasterize(full, maxDimension: 2400)?.cg else { return nil as UIImage? }
                return UIImage(cgImage: cg)
            }.value
        }
        .confirmationDialog("删除这张？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                HistoryStore.shared.delete([item.id])
                onClose()
            }
            Button("取消", role: .cancel) {}
        }
    }

    static func saveToPhotos(_ url: URL) async -> Bool {
        (try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
        }) != nil
    }
}
