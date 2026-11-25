import CoreImage
import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// 统一风格：一批照片全部参考同一张存好的风格图，AI 一张张给出色彩，套回各自的原图。
@MainActor
@Observable
final class BatchStyleModel {
    struct Item: Identifiable {
        enum Status { case pending, running, done, failed }
        let id = UUID()
        let name: String
        let url: URL
        var preview: UIImage?
        var result: UIImage?
        /// AI 的色彩换算成的颜色对照表。
        var cube: Data?
        var status: Status = .pending
        var error: String?
    }

    var style: SavedStyle? = StyleStore.shared.styles.first
    var items: [Item] = []
    var selected: UUID?
    var running = false
    var started = Date()
    var strength: CGFloat = 1
    var spent: Double = 0
    var error: String?
    var loading = false
    var exporting = false
    var exported = 0

    @ObservationIgnored private var task: Task<Void, Never>?

    var current: Item? { items.first { $0.id == selected } }
    var doneCount: Int { items.filter { $0.status == .done }.count }
    var remaining: Int { items.filter { $0.status != .done }.count }
    var runningIndex: Int? { items.firstIndex { $0.status == .running } }

    // MARK: 导入

    func add(urls: [URL]) {
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            append(url, name: url.deletingPathExtension().lastPathComponent)
        }
        loadPreviews()
    }

    /// 相册里选的：先落成临时文件，要用的时候再读，不把一批大图都放在内存里。
    func add(loaders: [ImageLoader]) {
        loading = true
        Task {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("batch-" + UUID().uuidString)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for load in loaders {
                guard let data = await load() else { continue }
                let n = items.count + 1
                let url = folder.appendingPathComponent("照片 \(n).img")
                guard (try? data.write(to: url)) != nil else { continue }
                append(url, name: "照片 \(n)")
                loadPreviews()
            }
            loading = false
        }
    }

    private func append(_ url: URL, name: String) {
        guard !items.contains(where: { $0.url == url }) else { return }
        items.append(Item(name: name, url: url))
        if selected == nil { selected = items.last?.id }
    }

    private func loadPreviews() {
        for item in items where item.preview == nil {
            let url = item.url, id = item.id
            Task {
                let image = await Task.detached(priority: .userInitiated) { Self.thumbnail(url, 1400) }.value
                guard let i = items.firstIndex(where: { $0.id == id }) else { return }
                if let image {
                    items[i].preview = image
                } else {
                    items.remove(at: i)
                    error = "有照片打不开，已跳过"
                }
            }
        }
    }

    func remove(_ id: UUID) {
        guard !running else { return }
        items.removeAll { $0.id == id }
        if selected == id { selected = items.first?.id }
    }

    private nonisolated static func thumbnail(_ url: URL, _ side: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    // MARK: 生成

    static let prompt = """
    第一张是要处理的照片，第二张是风格参考。把第一张的色彩、白平衡、曝光、反差、影调和肤色处理成和第二张完全一样的风格，\
    像同一台相机、同一套直出设置、同一天连着拍的一组照片：黑位和白位的位置一致，暗部和高光的色彩倾向一致，绿色、蓝色、红色各自的颜色走向一致，饱和度一致，肤色一致。\
    自然得像相机直出，不要有后期修过的痕迹，不要加暗角、颗粒、柔光、光斑。\
    只调整颜色和明暗；不要把第二张里的人、物、背景搬过来，不要移动、裁剪、旋转或改变第一张画面里任何东西的形状和位置，结果要和第一张逐像素对齐。
    """

    /// 从没做完的第一张接着做。
    func start() {
        run(items.filter { $0.status != .done }.map(\.id))
    }

    /// 这一张不满意，重做。
    func redo(_ id: UUID) {
        guard !running else { return }
        run([id])
    }

    private func run(_ ids: [UUID]) {
        guard !running, !ids.isEmpty else { return }
        var reference = style.flatMap { StyleStore.shared.image($0) }
        #if DEBUG
        if ProcessInfo.processInfo.environment["XIUTU_AUTORUN"] != nil { reference = items.first?.preview }
        #endif
        guard let reference else {
            error = "先选一个风格"
            return
        }
        guard var endpoint = AISettings.shared.endpoint() else {
            error = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        // 只要色彩，AI 图的清晰度用不上，按标准尺寸要，省钱。
        endpoint.hires = false
        error = nil
        running = true
        for i in items.indices where ids.contains(items[i].id) {
            items[i].status = .pending
            items[i].error = nil
        }
        task = Task { [weak self] in
            var failures = 0
            for id in ids {
                guard let self, !Task.isCancelled, let i = self.items.firstIndex(where: { $0.id == id }) else { break }
                self.items[i].status = .running
                self.started = Date()
                do {
                    let cube = try await Self.process(url: self.items[i].url, reference: reference, endpoint: endpoint)
                    if let cost = AIClient.takeLastUsage()?.cost {
                        self.spent += cost
                        AISettings.shared.addSpend(cost)
                    }
                    guard !Task.isCancelled, let j = self.items.firstIndex(where: { $0.id == id }) else { break }
                    self.items[j].cube = cube
                    self.items[j].status = .done
                    failures = 0
                    await self.renderPreview(id)
                    self.selected = id
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, let j = self.items.firstIndex(where: { $0.id == id }) else { break }
                    self.items[j].status = .failed
                    self.items[j].error = error.localizedDescription
                    self.error = "\(self.items[j].name)：\(error.localizedDescription)"
                    failures += 1
                    // 连着两张都失败，多半是 Key、余额或网络的问题，先停下。
                    if failures >= 2 { break }
                }
            }
            guard let self else { return }
            for i in self.items.indices where self.items[i].status == .running {
                self.items[i].status = self.items[i].cube == nil ? .pending : .done
            }
            self.running = false
        }
    }

    func stop() {
        task?.cancel()
        for i in items.indices where items[i].status == .running {
            items[i].status = items[i].cube == nil ? .pending : .done
        }
        running = false
    }

    private nonisolated static func process(url: URL, reference: UIImage, endpoint: AIEndpoint) async throws -> Data {
        guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]),
              let small = Renderer.shared.rasterize(full, maxDimension: 1536) else { throw AIError(text: "这张照片打不开。") }
        _ = AIClient.takeLastUsage()
        let graded = try await AIRunner.run(endpoint: endpoint, prompt: prompt, proxy: small.ci, ops: [], strokes: [],
                                            appendGuidance: false, references: [reference])
        guard let cube = StyleLUT.fit(original: small.cg, graded: graded) else { throw AIError(text: "AI 的结果用不了，可以重做这一张。") }
        return cube
    }

    // MARK: 预览和导出

    func renderPreview(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), let cube = item.cube, let preview = item.preview?.cgImage else { return }
        let strength = self.strength
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let out = StyleLUT.apply(cube, to: CIImage(cgImage: preview), strength: strength)
            return Renderer.shared.cgImage(out).map { UIImage(cgImage: $0) }
        }.value
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].result = image
    }

    /// 强度滑块：先改正在看的这张，松手再改其余的。
    func setStrength(_ value: CGFloat, editing: Bool) {
        strength = value
        if let selected { Task { await renderPreview(selected) } }
        guard !editing else { return }
        Task { for item in items where item.status == .done && item.id != selected { await renderPreview(item.id) } }
    }

    /// 原图分辨率的成品，保留相机信息（拍摄时间、机型、光圈……）。
    nonisolated static func render(url: URL, cube: Data, strength: CGFloat) -> Data? {
        guard let full = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        let out = StyleLUT.apply(cube, to: full, strength: strength)
        let space = full.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = Renderer.shared.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: space) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let old = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary] {
                if let value = old[key] { props[key] = value }
            }
            if var tiff = old[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                props[kCGImagePropertyTIFFDictionary] = tiff
            }
        }
        props[kCGImagePropertyOrientation] = 1
        props[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// 一张张出成品交给 write；返回写成了几张。
    private func export(_ write: @escaping (Item, Data) async -> Bool) async -> Int {
        exporting = true
        exported = 0
        for item in items where item.status == .done {
            guard let cube = item.cube else { continue }
            let url = item.url, strength = self.strength
            guard let data = await Task.detached(priority: .userInitiated, operation: {
                Self.render(url: url, cube: cube, strength: strength)
            }).value, await write(item, data) else { continue }
            exported += 1
            if HistoryStore.shared.enabled { await HistoryStore.shared.add(data: data, ext: "jpg", source: "统一风格") }
        }
        exporting = false
        return exported
    }

    /// Mac：全部存进一个文件夹，同名的后面加数字。
    func exportAll(to folder: URL) async -> Int {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        return await export { item, data in
            var url = folder.appendingPathComponent(item.name + "-穷图.jpg")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = folder.appendingPathComponent("\(item.name)-穷图 \(n).jpg")
                n += 1
            }
            return (try? data.write(to: url)) != nil
        }
    }

    /// 手机：全部存进相册。
    func saveAll() async -> Int {
        await export { _, data in
            (try? await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }) != nil
        }
    }
}
