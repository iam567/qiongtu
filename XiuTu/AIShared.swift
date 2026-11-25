import Photos
import SwiftUI
import UIKit

/// 封神、摄影棚、漫画人生共用的小工具。
enum AIOneShot {
    /// 重新画一遍：摆正方向、限制最长边，得到一张格式最普通的位图。
    static func prepared(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let k = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 按照片的横竖挑输出尺寸（场景模式保持原图的画幅）。
    static func size(matching image: UIImage) -> String {
        let ratio = image.size.width / max(image.size.height, 1)
        if ratio > 1.15 { return "1536x1024" }
        if ratio < 0.87 { return "1024x1536" }
        return "1024x1024"
    }

    /// 用 App 当前选中的服务商，按"指令 + 参考图"生成一张图。第一张图是主图，其余是附加参考。
    @MainActor
    static func run(prompt: String, images: [UIImage], size: String = "1024x1536") async throws -> (image: UIImage, usage: AIUsage?) {
        guard let endpoint = AISettings.shared.endpoint() else {
            throw AIError(text: "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。")
        }
        guard !images.isEmpty else { throw AIError(text: "还没有选照片。") }
        let usePNG = endpoint.provider.supportsMask
        var encoded: [Data] = []
        for image in images {
            let upload = prepared(image, maxSide: 1536)
            guard let bytes = usePNG ? upload.pngData() : upload.jpegData(compressionQuality: 0.92) else {
                throw AIError(text: "图片编码失败。")
            }
            encoded.append(bytes)
        }
        var payload = AIPayload(prompt: prompt, image: encoded[0], imageMime: usePNG ? "image/png" : "image/jpeg",
                                maskPNG: nil, markedJPEG: nil, size: size)
        payload.extraImages = Array(encoded.dropFirst())
        _ = AIClient.takeLastUsage()
        let data = try await AIClient.edit(endpoint, payload)
        let usage = AIClient.takeLastUsage()
        if let cost = usage?.cost { AISettings.shared.addSpend(cost) }
        guard let raw = UIImage(data: data) else { throw AIError(text: "服务商返回的不是有效图片。") }
        return (prepared(raw, maxSide: 4096), usage)
    }

    /// 存到相册；开着"存入历史图库"时同时在 App 里留一份。source 是历史图库里显示的来源。
    static func saveToPhotos(_ image: UIImage, source: String = "AI 生成") async -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        } catch {
            return false
        }
        if await HistoryStore.shared.enabled {
            await HistoryStore.shared.add(data: data, ext: "jpg", source: source)
        }
        return true
    }
}

/// 一排可横向滑动的选项标签（单选或多选都用它）。
struct ChipRow<Item: Identifiable>: View {
    let items: [Item]
    let title: (Item) -> String
    let isSelected: (Item) -> Bool
    let onTap: (Item) -> Void

    var body: some View {
        HScroll {
            HRow(spacing: 8) {
                ForEach(items) { item in
                    Chip(title: title(item), selected: isSelected(item)) { onTap(item) }
                }
            }
        }
    }
}

/// 页面底部的一级菜单（和修图编辑器同款）。
struct BottomTabBar<Tab: Identifiable & Hashable>: View {
    let tabs: [Tab]
    let title: (Tab) -> String
    @Binding var selection: Tab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { item in
                Button { selection = item } label: {
                    VStack(spacing: 6) {
                        Text(title(item))
                            .font(.system(size: 16, weight: selection == item ? .bold : .regular))
                            .foregroundStyle(selection == item ? Theme.accent : Color.white)
                        Capsule()
                            .fill(selection == item ? Theme.accent : Color.clear)
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
}

/// AI 出错时的红字说明，外加"换一家重试"的按钮。
struct AIFailureView: View {
    let message: String?
    var retry: () -> Void
    private let settings = AISettings.shared

    var body: some View {
        if let message {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
                let others = AIProvider.allCases.filter { $0 != settings.active && settings.isConfigured($0) }
                if !others.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(others) { provider in
                            Button {
                                settings.setActive(provider)
                                retry()
                            } label: {
                                Text("换 \(provider.shortTitle) 重试")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 没填 Key 时的提示。
struct NeedsKeyView: View {
    var openSettings: () -> Void
    private let settings = AISettings.shared

    var body: some View {
        VStack(spacing: 10) {
            Text("还没有设置 \(settings.active.shortTitle) 的 API Key").font(.system(size: 14))
            Button(action: openSettings) {
                Text("去设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

/// 全屏看一张生成结果，可以保存。
struct ResultViewer: View {
    let image: UIImage
    var onClose: () -> Void
    @State private var note: String?
    @State private var exports: [MacExport] = []

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableCanvas(image: image, handlers: nil)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.5), in: Circle())
                    }
                    Spacer()
                    Button {
                        if Platform.isMac {
                            exports = [MacExport(image, name: "穷图", source: "AI 生成")].compactMap { $0 }
                            return
                        }
                        Task {
                            let ok = await AIOneShot.saveToPhotos(image)
                            note = ok ? "已保存到相册" : "保存失败"
                        }
                    } label: {
                        Text(note ?? (Platform.isMac ? "导出" : "保存"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Color.white, in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, Platform.isMac ? 44 : 0)
        }
        .macExport($exports) { _ in note = "已导出" }
    }
}
