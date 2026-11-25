import SwiftUI
import UniformTypeIdentifiers

/// Mac 版封神、摄影棚、漫画人生这几页的外框：顶栏，左边画面，右边选项（高了就在里面滚动）。
struct MacWorkbench<Trailing: View, Canvas: View, Header: View, Panel: View, Footer: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var canvas: Canvas
    /// 右边面板里固定在上面的一块（分组、步骤条）。
    @ViewBuilder var header: Header
    @ViewBuilder var panel: Panel
    /// 固定在面板底部的一块（上一步 / 下一步）。
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // 让开左上角的红绿灯。
                Color.clear.frame(width: 70, height: 1)
                MacIconButton(symbol: "chevron.left", help: "返回", action: onClose)
                Text(title).font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                Spacer()
                trailing
            }
            .foregroundStyle(.white)
            .padding(.trailing, 12)
            .frame(height: 44)
            .background(MacTheme.chrome)
            Rectangle().fill(MacTheme.line).frame(height: 1)
            HStack(spacing: 0) {
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(MacTheme.canvas)
                Rectangle().fill(MacTheme.line).frame(width: 1)
                VStack(spacing: 0) {
                    header
                    ScrollView { panel.frame(maxWidth: .infinity) }
                        .frame(maxHeight: .infinity)
                    footer
                }
                .frame(width: 372)
                .background(MacTheme.panel)
            }
            .frame(maxHeight: .infinity)
        }
        .background(MacTheme.canvas)
    }
}

/// 要导出成文件的一张图。
struct MacExport {
    var data: Data
    var name: String
    /// 历史图库里显示的来源。
    var source: String

    var type: UTType { data.first == 0x89 ? .png : .jpeg }

    @MainActor
    init?(_ image: UIImage?, name: String, source: String) {
        guard let data = image?.jpegData(compressionQuality: 0.95) else { return nil }
        self.init(data: data, name: name, source: source)
    }

    init(data: Data, name: String, source: String) {
        self.data = data
        self.name = name
        self.source = source
    }

    /// 同时在历史图库里留一份。
    @MainActor
    func keep() async {
        guard HistoryStore.shared.enabled else { return }
        await HistoryStore.shared.add(data: data, ext: type == .png ? "png" : "jpg", source: source)
    }
}

extension View {
    /// Mac：导出图片到文件。一张 = 存储面板；好几张 = 选一个文件夹，全部存进去。
    func macExport(_ items: Binding<[MacExport]>, done: @escaping (Int) -> Void) -> some View {
        modifier(MacExportModifier(items: items, done: done))
    }
}

private struct MacExportModifier: ViewModifier {
    @Binding var items: [MacExport]
    var done: (Int) -> Void
    @State private var current: MacExport?

    func body(content: Content) -> some View {
        content
            .background {
                // 存储面板和选文件夹面板各挂在一个视图上，互不覆盖。
                Color.clear
                    .fileExporter(isPresented: Binding(get: { items.count == 1 }, set: { if !$0, items.count == 1 { items = [] } }),
                                  document: items.count == 1 ? ImageFileDocument(data: items[0].data, type: items[0].type) : nil,
                                  contentType: items.first?.type ?? .jpeg,
                                  defaultFilename: items.first?.name ?? "穷图") { result in
                        let item = current
                        guard case .success = result, let item else { return }
                        Task {
                            await item.keep()
                            done(1)
                        }
                    }
                Color.clear
                    .fileImporter(isPresented: Binding(get: { items.count > 1 }, set: { if !$0, items.count > 1 { items = [] } }),
                                  allowedContentTypes: [.folder]) { result in
                        guard case .success(let folder) = result else { return }
                        save(batch, to: folder)
                    }
            }
            .onChange(of: items.count) {
                if items.count == 1 { current = items[0] }
                if items.count > 1 { batch = items }
            }
    }

    @State private var batch: [MacExport] = []

    private func save(_ list: [MacExport], to folder: URL) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            var count = 0
            for item in list {
                // 文件夹里已经有同名文件就在后面加数字，不覆盖。
                let ext = item.type == .png ? "png" : "jpg"
                var url = folder.appendingPathComponent("\(item.name).\(ext)")
                var n = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = folder.appendingPathComponent("\(item.name) \(n).\(ext)")
                    n += 1
                }
                guard (try? item.data.write(to: url)) != nil else { continue }
                await item.keep()
                count += 1
            }
            done(count)
        }
    }
}

extension Theme {
    /// 大按钮的形状：手机是胶囊，Mac 是圆角方块。
    static var buttonShape: AnyShape {
        Platform.isMac ? AnyShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) : AnyShape(Capsule())
    }
    /// 选项区的底色。
    static var sheet: Color { Platform.isMac ? MacTheme.panel : panel }
}

extension View {
    /// 一张选项卡片的大小：手机固定宽高；Mac 拉满格子，字多就长高，不截断。
    @ViewBuilder
    func optionCard(width: CGFloat) -> some View {
        if Platform.isMac {
            frame(minWidth: 90, idealWidth: 134, maxWidth: .infinity, minHeight: 44, maxHeight: .infinity, alignment: .topLeading)
        } else {
            frame(width: width, height: 62, alignment: .topLeading)
        }
    }
}

/// 一排选项，后面跟着换 AI 服务商的菜单。Mac 面板窄，菜单单独放一行，选项才不会被挤小。
struct OptionLine<Content: View>: View {
    var openSettings: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        if Platform.isMac {
            HStack {
                Spacer()
                ProviderMenu(openSettings: openSettings, compact: true)
            }
            HRow(spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 8) {
                content
                Spacer()
                ProviderMenu(openSettings: openSettings, compact: true)
            }
        }
    }
}

/// Mac：面板里直接打字的一格。
struct MacFieldCell: View {
    let title: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Theme.dim)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.chip, in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
