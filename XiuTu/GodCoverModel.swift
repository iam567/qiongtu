import Photos
import SwiftUI
import UIKit

/// "封神"封面生成的全部状态。
@MainActor
@Observable
final class GodCoverModel {
    struct Option: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
    }
    struct Style: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let desc: String
    }
    struct Category: Decodable, Identifiable {
        let icon: String
        let title: String
        let styles: [Style]
        var id: String { title }
    }
    struct Catalog: Decodable {
        var categories: [Category] = []
        var beauty: [Option] = []
        var age: [Option] = []
        var persona: [Option] = []
        var gender: [Option] = []
        var filter: [Option] = []
    }
    enum OptionGroup: String, CaseIterable, Identifiable {
        case beauty, age, persona, gender
        var id: String { rawValue }
        var title: String {
            switch self {
            case .beauty: return "美颜"
            case .age: return "年龄"
            case .persona: return "人设"
            case .gender: return "性别"
            }
        }
    }

    let catalog: Catalog
    let engine = GodCoverEngine()

    var isLoading = true
    var errorText: String?
    var preview: UIImage?

    // 风格
    var categoryIndex = 0
    var styleID = "vogue"

    // AI 改造
    var optionGroup: OptionGroup = .beauty
    var beauty = "medium"
    var age = "original"
    var persona = "random"
    var gender = "auto"
    var running = false
    var started = Date()
    var aiError: String?
    var usageText: String?
    var hasAI = false
    var showingAI = false

    /// 封面的主角是人（原来的玩法）还是场景本身（AI 不加人）。打开照片时自动判断，可以手动换。
    var subject: SubjectMode = .person
    // 场景模式的 AI 改造：大片感、光线、天气、季节、时间、清理
    var sceneGroup: GodCoverScene.Group = .look
    var sceneValues: [GodCoverScene.Group: String] = [:]

    // 文字
    var mainTitle = ""
    var subtitle = ""
    var extra1 = ""
    var extra2 = ""
    var showTemplate = true
    var forceText = false

    // 调整
    var scale: Double = 100
    var offsetX: Double = 0
    var offsetY: Double = 0
    var filter = "none"

    @ObservationIgnored private var original: UIImage?
    @ObservationIgnored private var aiImage: UIImage?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var aiTask: Task<Void, Never>?
    @ObservationIgnored private var lastNoText = false

    init() {
        let url = Bundle.main.url(forResource: "catalog.json", withExtension: "gcweb")
            ?? Bundle.main.url(forResource: "catalog.json", withExtension: "gcweb", subdirectory: "GodCover")
        if let url, let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Catalog.self, from: data) {
            catalog = c
        } else {
            catalog = Catalog()
        }
    }

    var currentStyle: Style? {
        catalog.categories.flatMap(\.styles).first { $0.id == styleID }
    }

    func value(_ group: OptionGroup) -> String {
        switch group {
        case .beauty: return beauty
        case .age: return age
        case .persona: return persona
        case .gender: return gender
        }
    }

    func options(_ group: OptionGroup) -> [Option] {
        switch group {
        case .beauty: return catalog.beauty
        case .age: return catalog.age
        case .persona: return catalog.persona
        case .gender: return catalog.gender
        }
    }

    func setValue(_ id: String, for group: OptionGroup) {
        switch group {
        case .beauty: beauty = id
        case .age: age = id
        case .persona: persona = id
        case .gender: gender = id
        }
    }

    func sceneValue(_ group: GodCoverScene.Group) -> String {
        sceneValues[group] ?? group.fallback
    }

    // MARK: 加载

    private static func prepared(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        let k = min(1, maxSide / max(longest, 1))
        let size = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        // 重新画一遍：摆正方向，同时得到一张格式最普通的位图。
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func dataURL(_ image: UIImage, quality: CGFloat = 0.92) -> String? {
        image.jpegData(compressionQuality: quality).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    /// fileURL：Mac 上从文件来的照片；没有就按 assetID 从相册取。
    func load(assetID: String, fileURL: URL? = nil) async {
        guard let image = await PhotoLibrary.image(assetID: assetID, fileURL: fileURL) else {
            errorText = "无法读取这张图片"
            isLoading = false
            return
        }
        let photo = Self.prepared(image, maxSide: 2048)
        original = photo
        guard let url = Self.dataURL(photo) else {
            errorText = "这张图片的格式暂不支持"
            isLoading = false
            return
        }
        async let detected = SubjectMode.detect(in: photo)
        do {
            try await engine.setPhoto(ai: false, dataURL: url)
        } catch {
            errorText = "封面引擎没有启动成功"
            isLoading = false
            return
        }
        subject = await detected
        await randomizeText(render: false)
        isLoading = false
        refresh()
    }

    // MARK: 预览

    private var params: [String: Any] {
        [
            "style": styleID, "mainTitle": mainTitle, "subtitle": subtitle, "issueDate": extra1, "price": extra2,
            "scale": scale / 100, "offsetX": Int(offsetX.rounded()), "offsetY": Int(offsetY.rounded()),
            "filter": filter, "showTemplate": showTemplate, "forceCustomText": forceText,
            "photoMode": showingAI && hasAI ? "ai" : "original",
        ]
    }

    func refresh() {
        let p = params
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            guard let self else { return }
            let image = try? await self.engine.render(p)
            guard !Task.isCancelled, let image else { return }
            self.preview = image
        }
    }

    func selectStyle(_ id: String) {
        styleID = id
        Task { await randomizeText(render: true) }
    }

    /// 换一组这个杂志风格的标题文案（和网站里选风格时的行为一致）。
    func randomizeText(render: Bool) async {
        if let t = await engine.randomText(style: styleID) {
            mainTitle = t.title
            subtitle = t.sub
        }
        if render { refresh() }
    }

    func showAI(_ on: Bool) {
        showingAI = on && hasAI
        refresh()
    }

    // MARK: AI 生成

    func generate(noText: Bool) {
        guard !running, let original else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            aiError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        lastNoText = noText
        aiError = nil
        usageText = nil
        running = true
        started = Date()
        let task: [String: Any] = [
            "style": styleID, "styleName": currentStyle?.name ?? styleID,
            "beauty": beauty, "age": age, "persona": persona, "gender": gender, "photoSchool": "random",
            "forceCustomText": forceText, "customMainTitle": mainTitle, "customSubtitle": subtitle,
            "customIssueDate": extra1, "customPrice": extra2,
        ]
        // 场景模式：指令在本机拼；无字版的画幅跟原图走，带字的封面仍然是竖幅。
        let scene = subject == .scene
        let scenePrompt = !scene ? "" : GodCoverScene.prompt(
            styleName: currentStyle?.name ?? styleID, styleDesc: currentStyle?.desc ?? "",
            category: catalog.categories.first { $0.styles.contains { $0.id == styleID } }?.title ?? "",
            values: sceneValues, noText: noText, texts: forceText ? [mainTitle, subtitle, extra1, extra2] : [],
            orientation: SceneLook.orientation(of: original))
        let size = scene && noText ? AIOneShot.size(matching: original) : "1024x1536"
        aiTask = Task { [weak self] in
            guard let self else { return }
            do {
                // 两条路出来的指令都过同一套清理：人物在 gc.prompt 里，场景单独调一次。
                let prompt = try await (scene
                    ? self.engine.sanitize(scenePrompt)
                    : self.engine.prompt(task: task, noText: noText))
                guard !prompt.isEmpty else { throw AIError(text: "这个风格的指令没有生成出来。") }
                // 发给 AI 的图：长边 1536 足够，输出本身就是 1024×1536。
                let upload = Self.prepared(original, maxSide: 1536)
                let usePNG = endpoint.provider.supportsMask
                guard let bytes = usePNG ? upload.pngData() : upload.jpegData(compressionQuality: 0.92) else {
                    throw AIError(text: "图片编码失败。")
                }
                let payload = AIPayload(prompt: prompt, image: bytes, imageMime: usePNG ? "image/png" : "image/jpeg",
                                        maskPNG: nil, markedJPEG: nil, size: size)
                _ = AIClient.takeLastUsage()
                let data = try await AIClient.edit(endpoint, payload)
                let usage = AIClient.takeLastUsage()
                if let cost = usage?.cost { AISettings.shared.addSpend(cost) }
                guard !Task.isCancelled else { return }
                guard let raw = UIImage(data: data) else { throw AIError(text: "服务商返回的不是有效图片。") }
                let result = Self.prepared(raw, maxSide: 4096)
                guard let url = Self.dataURL(result, quality: 0.95) else { throw AIError(text: "结果图片无法处理。") }
                try await self.engine.setPhoto(ai: true, dataURL: url)
                self.aiImage = result
                self.hasAI = true
                self.showingAI = true
                // AI 出的图通常已经带了刊名和排版，再叠一层模板会重影，所以默认关掉模板。
                // 场景的无字版是一张干净的照片，模板照旧叠在上面，就是成品封面。
                if !(scene && noText) { self.showTemplate = false }
                self.usageText = usage?.summary
                self.running = false
                self.refresh()
            } catch is CancellationError {
                self.running = false
            } catch {
                guard !Task.isCancelled else { return }
                self.running = false
                self.aiError = error.localizedDescription
            }
        }
    }

    func retry() { generate(noText: lastNoText) }

    func cancelAI() {
        aiTask?.cancel()
        aiTask = nil
        running = false
    }

    // MARK: 保存

    /// 现在这张封面的图片数据。
    func exportData() async -> Data? {
        var data: Data?
        if showTemplate {
            data = try? await engine.export(params, scale: 3)
        } else {
            let image = showingAI && hasAI ? aiImage : original
            data = image?.jpegData(compressionQuality: 0.95)
        }
        return data
    }

    func save() async -> Bool {
        guard let data = await exportData() else { return false }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            if HistoryStore.shared.enabled {
                // 带排版的封面导出来是 PNG，其余是 JPG。
                await HistoryStore.shared.add(data: data, ext: data.first == 0x89 ? "png" : "jpg", source: "封神")
            }
            return true
        } catch {
            return false
        }
    }
}
