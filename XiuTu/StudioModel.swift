import SwiftUI
import UIKit

/// 摄影棚：一张照片，按选好的场景、摄影师、器材拍出一组不同景别和姿势的套图。
@MainActor
@Observable
final class StudioModel {
    struct Option: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        var swatch: String? = nil
    }
    struct SceneCategory: Decodable, Identifiable {
        let title: String
        let scenes: [Option]
        var id: String { title }
    }
    struct BrandCategory: Decodable, Identifiable {
        let title: String
        let items: [Option]
        var id: String { title }
    }
    struct Catalog: Decodable {
        var categories: [SceneCategory] = []
        var photographers: [Option] = []
        var equipment: [Option] = []
        var timeOfDay: [Option] = []
        var retouchParts: [Option] = []
        var hairColors: [Option] = []
        var brands: [BrandCategory] = []
        var persona: [Option] = []
        var age: [Option] = []
        var beauty: [Option] = []
        var gender: [Option] = []
        var counts: [Int] = [3, 6, 10, 15, 20]
    }
    struct Shot: Identifiable {
        enum Status { case pending, running, done, failed }
        let id: Int
        let prompt: String
        let framing: String
        let photographer: String
        var status: Status = .pending
        var image: UIImage?
        var error: String?
        /// 场景模式下这一张的拍法（原构图、更广全景……）。
        var sceneTitle: String?

        var framingTitle: String {
            if let sceneTitle { return sceneTitle }
            switch framing {
            case "closeup": return "近景"
            case "medium": return "中景"
            case "full_body": return "全身"
            case "wide": return "远景"
            default: return ""
            }
        }
    }

    var catalog: Catalog
    let engine = GodCoverEngine()

    var isLoading = true
    var errorText: String?
    var original: UIImage?
    /// 摄影师、器材格子上的小图（key 见 StudioLooks），"original" 是原图。打开照片后在后台算一次。
    var thumbs: [String: UIImage] = [:]

    /// 拍人物（原来的玩法）还是拍场景（照片里的场景就是拍摄对象，不加人）。打开照片时自动判断，可以手动换。
    var subject: SubjectMode = .person
    // 拍场景：氛围（没选的就是保持原样）、拍法、张数
    var scenePicks: [SceneLook.Group: String] = [:]
    var sceneVariations = StudioScene.defaultVariations
    var sceneCount = 3
    /// 这一组照片的宽高比，排缩略图用。
    var shotAspect: CGFloat = 2.0 / 3.0

    // 场景
    var categoryIndex = 0
    /// "keep" = 不换地方，保持原照片的背景。
    var sceneID = "keep"
    var sceneHint = ""
    // 人物
    var gender = "auto"
    var persona = "random"
    var age = "original"
    var beauty = "none"
    var retouchParts: Set<String> = []
    var hairColors: Set<String> = []
    // 摄影
    /// "none" = 不指定摄影师。
    var photographer = "none"
    var equipment = "auto"
    var timeOfDay = "auto"
    var brands: Set<String> = []
    var brandCategoryIndex = 0
    // 套图
    var count = 3
    var shots: [Shot] = []
    var running = false
    var started = Date()
    var aiError: String?
    var spent: Double = 0

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastExplore = false

    init() {
        let url = Bundle.main.url(forResource: "studio_catalog.json", withExtension: "gcweb")
            ?? Bundle.main.url(forResource: "studio_catalog.json", withExtension: "gcweb", subdirectory: "GodCover")
        if let url, let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Catalog.self, from: data) {
            catalog = c
        } else {
            catalog = Catalog()
        }
        // 每一项都可以不选。
        catalog.photographers.insert(Option(id: "none", title: "不指定"), at: 0)
    }

    var scenes: [Option] {
        catalog.categories.indices.contains(categoryIndex) ? catalog.categories[categoryIndex].scenes : []
    }

    var doneCount: Int { shots.filter { $0.status == .done }.count }
    var currentIndex: Int? { shots.firstIndex { $0.status == .running } }

    func selectCategory(_ index: Int) {
        categoryIndex = index
    }

    /// fileURL：Mac 上从文件来的照片；没有就按 assetID 从相册取。
    func load(assetID: String, fileURL: URL? = nil) async {
        guard let image = await PhotoLibrary.image(assetID: assetID, fileURL: fileURL) else {
            errorText = "无法读取这张图片"
            isLoading = false
            return
        }
        let photo = AIOneShot.prepared(image, maxSide: 2048)
        subject = await SubjectMode.detect(in: photo)
        original = photo
        isLoading = false
        Task.detached(priority: .userInitiated) { [weak self] in
            let out = StudioLooks.render(photo)
            await self?.setThumbs(out)
        }
    }

    private func setThumbs(_ out: [String: UIImage]) {
        thumbs = out
    }

    func toggleSceneVariation(_ id: String) {
        if !sceneVariations.contains(id) {
            sceneVariations.insert(id)
        } else if sceneVariations.count > 1 {
            // 至少留一种拍法。
            sceneVariations.remove(id)
        }
    }

    /// 开始拍摄。explore = true 是"试拍"：固定 6 张，每张换一位摄影师（拍人物时还换一种器材）。
    func start(explore: Bool) {
        let scene = subject == .scene
        guard !running, let original else { return }
        guard scene || (catalog.categories.indices.contains(categoryIndex) && !sceneID.isEmpty) else { return }
        guard AISettings.shared.endpoint() != nil else {
            aiError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        lastExplore = explore
        aiError = nil
        running = true
        started = Date()
        // 拍场景：画幅跟原图走，指令在本机拼。
        let size = scene ? AIOneShot.size(matching: original) : "1024x1536"
        let scenePlan = !scene ? [] : StudioScene.plan(
            photographer: photographer, equipment: equipment, photographers: catalog.photographers,
            equipmentList: catalog.equipment, picks: scenePicks, variations: sceneVariations, count: sceneCount,
            explore: explore, orientation: SceneLook.orientation(of: original))
        let params: [String: Any] = scene ? [:] : [
            "mainCategory": catalog.categories[categoryIndex].title, "subScene": sceneID, "sceneHint": sceneHint,
            "persona": persona, "gender": gender, "age": age, "beauty": beauty,
            "retouchParts": Array(retouchParts), "hairColors": Array(hairColors),
            "photographer": photographer, "equipment": equipment, "timeOfDay": timeOfDay,
            "brands": Array(brands), "count": count, "explore": explore,
        ]
        let wh = size.split(separator: "x").compactMap { Double($0) }
        let aspect: CGFloat = wh.count == 2 && wh[1] > 0 ? CGFloat(wh[0] / wh[1]) : 2.0 / 3.0
        if scene {
            guard !scenePlan.isEmpty else {
                running = false
                aiError = "这组设置没有排出拍摄计划。"
                return
            }
            shots = scenePlan.enumerated().map { index, item in
                Shot(id: index, prompt: item.prompt, framing: "", photographer: item.photographer, sceneTitle: item.variation)
            }
            shotAspect = aspect
        }
        task = Task { [weak self] in
            guard let self else { return }
            if !scene {
                do {
                    let plan = try await self.engine.studioPlan(params)
                    guard !plan.isEmpty else { throw AIError(text: "这组设置没有排出拍摄计划。") }
                    self.shots = plan.enumerated().map { index, item in
                        Shot(id: index, prompt: item["prompt"] as? String ?? "", framing: item["framing"] as? String ?? "",
                             photographer: item["photographer"] as? String ?? "")
                    }
                    self.shotAspect = aspect
                } catch {
                    self.running = false
                    self.aiError = error.localizedDescription
                    return
                }
            }
            var failuresInARow = 0
            for index in self.shots.indices {
                if Task.isCancelled { break }
                self.shots[index].status = .running
                self.started = Date()
                do {
                    let result = try await AIOneShot.run(prompt: self.shots[index].prompt, images: [original], size: size)
                    if Task.isCancelled { break }
                    self.shots[index].image = result.image
                    self.shots[index].status = .done
                    self.spent += result.usage?.cost ?? 0
                    failuresInARow = 0
                } catch is CancellationError {
                    break
                } catch {
                    if Task.isCancelled { break }
                    self.shots[index].status = .failed
                    self.shots[index].error = error.localizedDescription
                    self.aiError = "第 \(index + 1) 张失败：\(error.localizedDescription)"
                    failuresInARow += 1
                    // 连着两张都失败，多半是 Key、余额或审核的问题，继续拍只会白等。
                    if failuresInARow >= 2 { break }
                }
            }
            for index in self.shots.indices where self.shots[index].status == .running || self.shots[index].status == .pending {
                self.shots[index].status = .failed
                if self.shots[index].error == nil { self.shots[index].error = "没有拍" }
            }
            self.running = false
        }
    }

    func retry() { start(explore: lastExplore) }

    func cancel() {
        task?.cancel()
        running = false
    }

    func saveAll() async -> Int {
        var saved = 0
        for shot in shots {
            if let image = shot.image, await AIOneShot.saveToPhotos(image, source: "摄影棚") { saved += 1 }
        }
        return saved
    }
}
