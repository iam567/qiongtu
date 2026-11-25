import ImageIO
import SwiftUI
import UIKit

/// 存下来的一种照片风格：就是一张修好的图，批量统一风格时给 AI 当参考。
struct SavedStyle: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    let date: Date
}

@MainActor
@Observable
final class StyleStore {
    static let shared = StyleStore()

    /// 新的在前。
    private(set) var styles: [SavedStyle] = []
    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var cache: [UUID: UIImage] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("Styles", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([SavedStyle].self, from: data) {
            styles = list.filter { FileManager.default.fileExists(atPath: url($0.id).path) }
        }
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }

    private func save() {
        guard let data = try? JSONEncoder().encode(styles) else { return }
        try? data.write(to: folder.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
    }

    func image(_ style: SavedStyle) -> UIImage? {
        if let hit = cache[style.id] { return hit }
        guard let image = UIImage(contentsOfFile: url(style.id).path) else { return nil }
        cache[style.id] = image
        return image
    }

    /// 从一个图片文件存成风格。
    func add(file: URL) async -> SavedStyle? {
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            return Self.reduced(source)
        }.value
        return insert(jpeg)
    }

    func add(data: Data) async -> SavedStyle? {
        let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return Self.reduced(source)
        }.value
        return insert(jpeg)
    }

    private func insert(_ jpeg: Data?) -> SavedStyle? {
        guard let jpeg else { return nil }
        let used = Set(styles.map(\.name))
        var n = styles.count + 1
        while used.contains("风格 \(n)") { n += 1 }
        let style = SavedStyle(id: UUID(), name: "风格 \(n)", date: Date())
        guard (try? jpeg.write(to: url(style.id), options: [.atomic, .completeFileProtection])) != nil else { return nil }
        styles.insert(style, at: 0)
        save()
        return style
    }

    private nonisolated static func reduced(_ source: CGImageSource) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            .flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.92) }
    }

    func rename(_ style: SavedStyle, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = styles.firstIndex(where: { $0.id == style.id }) else { return }
        styles[i].name = name
        save()
    }

    func remove(_ style: SavedStyle) {
        try? FileManager.default.removeItem(at: url(style.id))
        cache[style.id] = nil
        styles.removeAll { $0.id == style.id }
        save()
    }
}
