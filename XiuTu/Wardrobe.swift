import CoreImage
import SwiftUI
import UIKit

/// 衣橱里的一身衣服：从照片里抠下来的图（最多三个角度）加一份详细说明，换到别的照片上时照着来。
struct WardrobeItem: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let date: Date
    /// AI 写的款式说明；还没写好是空的。
    var desc: String
    /// 存了几张图（0.jpg、1.jpg……）。
    var count: Int
}

@MainActor
@Observable
final class WardrobeStore {
    static let shared = WardrobeStore()

    /// 新的在前。
    private(set) var items: [WardrobeItem] = []
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var cache: [String: UIImage] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if DEBUG
        // 接模拟接口的调试运行不动正式数据。
        folder = ProcessInfo.processInfo.environment["XIUTU_TEST_BASE"] != nil
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Wardrobe-test", isDirectory: true)
            : base.appendingPathComponent("Wardrobe", isDirectory: true)
        #else
        folder = base.appendingPathComponent("Wardrobe", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([WardrobeItem].self, from: data) {
            items = list.filter { FileManager.default.fileExists(atPath: url($0.id, 0).path) }
        }
    }

    private func url(_ id: UUID, _ i: Int) -> URL { folder.appendingPathComponent("\(id.uuidString)-\(i).jpg") }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }

    func image(_ item: WardrobeItem, _ i: Int = 0) -> UIImage? {
        let key = "\(item.id)-\(i)"
        if let hit = cache[key] { return hit }
        guard let image = UIImage(contentsOfFile: url(item.id, i).path) else { return nil }
        cache[key] = image
        return image
    }

    /// 发给 AI 的参考图。
    func references(_ item: WardrobeItem) -> [UIImage] { (0..<item.count).compactMap { image(item, $0) } }

    func add(_ images: [Data]) -> WardrobeItem? {
        guard !images.isEmpty else { return nil }
        let used = Set(items.map(\.name))
        var n = items.count + 1
        while used.contains("衣服 \(n)") { n += 1 }
        var item = WardrobeItem(id: UUID(), name: "衣服 \(n)", date: Date(), desc: "", count: 0)
        for data in images where (try? data.write(to: url(item.id, item.count), options: [.atomic, .completeFileProtection])) != nil {
            item.count += 1
        }
        guard item.count > 0 else { return nil }
        items.insert(item, at: 0)
        save()
        return item
    }

    /// 补一个角度（最多三张图）。
    func addAngle(_ id: UUID, _ data: Data) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].count < 3,
              (try? data.write(to: url(id, items[i].count), options: [.atomic, .completeFileProtection])) != nil else { return false }
        items[i].count += 1
        save()
        return true
    }

    func update(_ id: UUID, desc: String? = nil, name: String? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let desc { items[i].desc = desc }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { items[i].name = name.trimmingCharacters(in: .whitespaces) }
        save()
    }

    func remove(_ item: WardrobeItem) {
        for i in 0..<3 {
            try? FileManager.default.removeItem(at: url(item.id, i))
            cache["\(item.id)-\(i)"] = nil
        }
        items.removeAll { $0.id == item.id }
        save()
    }
}

enum Wardrobe {
    /// 从照片里抠出穿着的衣服：全身一张、上半身细节一张，灰底，头去掉。认不出人返回空。
    static func cutouts(_ image: CGImage) -> [Data] {
        guard let mask = PersonSegmenter.main(PersonSegmenter.mask(for: image)) else { return [] }
        let photo = CIImage(cgImage: image)
        let e = photo.extent
        let m = AIRegion.scaled(mask: mask, to: e, feather: false)
        let gray = CIImage(color: CIColor(red: 0.82, green: 0.82, blue: 0.82)).cropped(to: e)
        var cut = photo.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: gray, kCIInputMaskImageKey: m]).cropped(to: e)
        let faces = FaceDetector.detect(in: image)
        for f in faces {
            let b = f.box
            let chin = f.contour.map(\.y).max() ?? b.maxY
            let top = b.minY - b.height * 1.1
            let r = CGRect(x: (b.midX - b.width * 0.95) * e.width, y: (1 - chin) * e.height, width: b.width * 1.9 * e.width, height: (chin - top) * e.height)
            cut = gray.cropped(to: r).composited(over: cut).cropped(to: e)
        }
        guard let box = bounds(mask) else { return [] }
        func piece(_ r: CGRect) -> Data? {
            let px = CGRect(x: r.minX * e.width, y: (1 - r.maxY) * e.height, width: r.width * e.width, height: r.height * e.height)
                .integral.intersection(e)
            guard px.width > 60, px.height > 60 else { return nil }
            let out = cut.cropped(to: px).transformed(by: CGAffineTransform(translationX: -px.minX, y: -px.minY))
            return Renderer.shared.rasterize(out, maxDimension: 1600).flatMap { UIImage(cgImage: $0.cg).jpegData(compressionQuality: 0.93) }
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let full = box.insetBy(dx: -box.width * 0.03, dy: -box.height * 0.02).intersection(unit)
        // 上半身：下巴往下一截，看清领口、袖子和装饰。
        var upper = CGRect(x: full.minX, y: full.minY, width: full.width, height: full.height * 0.5)
        if let f = faces.max(by: { $0.box.width < $1.box.width }) {
            let h = max(f.box.height * 4.2, 0.05), w = f.box.width * 5.5
            upper = CGRect(x: f.box.midX - w / 2, y: f.box.maxY - f.box.height * 0.1, width: w, height: h).intersection(unit)
        }
        return [piece(full), piece(upper)].compactMap { $0 }
    }

    private static func bounds(_ mask: CGImage) -> CGRect? {
        let n = 160
        var px = [UInt8](repeating: 0, count: n * n)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(mask, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var x0 = n, x1 = -1, y0 = n, y1 = -1
        for y in 0..<n { for x in 0..<n where px[y * n + x] > 110 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 > x0, y1 > y0 else { return nil }
        let k = 1 / CGFloat(n)
        return CGRect(x: CGFloat(x0) * k, y: CGFloat(y0) * k, width: CGFloat(x1 - x0 + 1) * k, height: CGFloat(y1 - y0 + 1) * k)
    }

    static let describePrompt = """
    图里是一身衣服（头已经去掉）。请像服装设计师写工艺单一样，把它写清楚，好让另一个人在别的照片里做出一模一样的一件。\
    按顺序写：整体款式和廓形；主色和配色（尽量具体到色调）；面料和光泽；领口和肩；袖子（长度、形状、袖口）；上身和腰（结构、系带、扣子、腰带）；\
    裙身或下装（层次、褶皱、长度、裙撑、裙摆）；图案和刺绣是什么样、分布在哪里；装饰（花、蝴蝶结、珠宝、蕾丝）各在什么位置、多大、什么颜色；手套、鞋等配饰（看得见才写）。\
    只写看得见的，不写人、不写姿势、不写背景。不超过 350 个字，直接写，不要标题和列表。
    """

    /// 照着衣橱里的这身衣服换。
    static func prompt(_ item: WardrobeItem, skirt: OutfitSkirt) -> String {
        "把第一张图里主要人物的衣服换成参考图里的那一身。参考图（第二张起）是同一身衣服的全身和细节，头已经去掉，灰底只是背景。" +
            (item.desc.isEmpty ? "" : "这身衣服的样子：\(item.desc)。") +
            "必须和参考图是同一件：款式、颜色、面料、图案、刺绣、每一处装饰的样子和位置都一致，不要改设计、不要增减装饰。" +
            "这张照片里人的姿势、角度和参考图不同：衣服随姿势自然变化，参考图里看不到的部分（侧面、背面）按同一个设计合理延续；光线和明暗按第一张图的现场来，但衣服本身的颜色不变。" +
            "不要把参考图里的身材、姿势、灰色背景搬过来。" + skirt.prompt + OutfitCatalog.clean + OutfitCatalog.keep
    }
}

extension EditorModel {
    /// 把现在这张照片里穿的衣服存进衣橱。into 不为空 = 给那一身补一个角度。
    func saveToWardrobe(into id: UUID? = nil) {
        guard !wardrobeSaving, let proxy else { return }
        wardrobeSaving = true
        aiError = nil
        var ops = liftedFloating.isEmpty ? self.ops : EditOp.splitFloating(self.ops).photo
        // 刚换好还没应用的也算。
        if let edit = currentAIEdit { ops.append(.ai(edit)) }
        Task {
            defer { wardrobeSaving = false }
            let sent = ops
            let images = await Task.detached(priority: .userInitiated) { () -> [Data] in
                guard let big = Renderer.shared.rasterize(EditOp.apply(sent, to: proxy), maxDimension: 4096) else { return [] }
                return Wardrobe.cutouts(big.cg)
            }.value
            guard !images.isEmpty else {
                aiError = "没有认出人，存不了衣服。"
                return
            }
            if let id {
                if !WardrobeStore.shared.addAngle(id, images[0]) { aiError = "这身衣服已经有三张图了。" }
                return
            }
            guard let item = WardrobeStore.shared.add(images) else {
                aiError = "没有存成功。"
                return
            }
            wardrobeSaved = item.name
            // 让能看图的 AI 写一份款式说明；写不了也能用，只是少一份说明。
            guard let endpoint = AISettings.shared.endpoint(), let first = images.first,
                  let text = try? await AIClient.look(endpoint, prompt: Wardrobe.describePrompt, jpeg: first) else { return }
            WardrobeStore.shared.update(item.id, desc: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900)))
        }
    }

    func pickWardrobe(_ item: WardrobeItem?) {
        aiError = nil
        wardrobePick = item
        outfitSkirt = .normal
    }
}
