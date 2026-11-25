import ImageIO
import SwiftUI
import UIKit

/// 满意脸型：用户自己修满意的一张脸，存下来当参考。下次修图时让 AI 按这张参考把脸一键修成同样的感觉。
struct FavoriteFace: Identifiable, Codable, Equatable {
    let id: UUID
    let date: Date
}

@MainActor
@Observable
final class FavoriteFaceStore {
    static let shared = FavoriteFaceStore()

    /// 新的在前。
    private(set) var faces: [FavoriteFace] = []
    /// 修图时用哪一张；nil = 用最新的一张。
    private(set) var currentID: UUID?

    @ObservationIgnored private let folder: URL
    @ObservationIgnored private var cache: [UUID: UIImage] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("FavoriteFaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")),
           let list = try? JSONDecoder().decode([FavoriteFace].self, from: data) {
            faces = list.filter { FileManager.default.fileExists(atPath: url($0.id).path) }
        }
        if let raw = UserDefaults.standard.string(forKey: "favoriteFace.current"), let id = UUID(uuidString: raw),
           faces.contains(where: { $0.id == id }) {
            currentID = id
        }
    }

    var current: FavoriteFace? {
        faces.first { $0.id == currentID } ?? faces.first
    }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }

    private func save() {
        if let data = try? JSONEncoder().encode(faces) {
            try? data.write(to: folder.appendingPathComponent("index.json"), options: [.atomic, .completeFileProtection])
        }
        UserDefaults.standard.set(currentID?.uuidString, forKey: "favoriteFace.current")
    }

    func image(_ face: FavoriteFace) -> UIImage? {
        if let hit = cache[face.id] { return hit }
        guard let image = UIImage(contentsOfFile: url(face.id).path) else { return nil }
        cache[face.id] = image
        return image
    }

    /// 从一张图里找到最大的脸，把头部这一块存成满意脸型，并设为当前。找不到脸返回 false。
    func add(from data: Data) async -> Bool {
        let crop = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3000,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let face = FaceDetector.detect(in: cg).first else { return nil }
            let w = CGFloat(cg.width), h = CGFloat(cg.height)
            let side = min(max(face.box.width * w, face.box.height * h) * 2.2, min(w, h))
            let cx = face.box.midX * w, cy = face.box.midY * h - face.box.height * h * 0.1
            var rect = CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
            rect.origin.x = min(max(rect.minX, 0), w - side)
            rect.origin.y = min(max(rect.minY, 0), h - side)
            guard let piece = cg.cropping(to: rect.integral) else { return nil }
            let image = AIOneShot.prepared(UIImage(cgImage: piece), maxSide: 1024)
            return image.jpegData(compressionQuality: 0.92)
        }.value
        guard let crop else { return false }
        let face = FavoriteFace(id: UUID(), date: Date())
        do {
            try crop.write(to: url(face.id), options: [.atomic, .completeFileProtection])
        } catch {
            return false
        }
        faces.insert(face, at: 0)
        currentID = face.id
        save()
        return true
    }

    func setCurrent(_ face: FavoriteFace) {
        currentID = face.id
        save()
    }

    func remove(_ face: FavoriteFace) {
        try? FileManager.default.removeItem(at: url(face.id))
        cache[face.id] = nil
        faces.removeAll { $0.id == face.id }
        if currentID == face.id { currentID = nil }
        save()
    }
}

/// 主页进来的"满意脸型"：看、换当前、删除，也可以直接从相册添加。
struct FavoriteFaceView: View {
    var onClose: () -> Void

    private let store = FavoriteFaceStore.shared
    @State private var picking = false
    @State private var busy = false
    @State private var note: String?
    @State private var deleting: FavoriteFace?

    private let columns = Platform.isMac ? [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 10)]
        : Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ZStack {
            (Platform.isMac ? MacTheme.canvas : Theme.bg).ignoresSafeArea()
            VStack(spacing: 0) {
                if Platform.isMac {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 70, height: 1)
                        MacIconButton(symbol: "chevron.left", help: "返回", action: onClose)
                        Text("满意脸型").font(.system(size: 13, weight: .semibold)).padding(.leading, 4)
                        Spacer()
                        Button { picking = true } label: { Text(busy ? "正在添加…" : "添加…").macProminent() }
                            .buttonStyle(.plain)
                            .disabled(busy)
                    }
                    .foregroundStyle(.white)
                    .padding(.trailing, 12)
                    .frame(height: 44)
                    .background(MacTheme.chrome)
                } else {
                    phoneBar
                }
                if let note {
                    Text(note).font(.system(size: 13)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4)).padding(.top, Platform.isMac ? 10 : 0)
                }
                if store.faces.isEmpty {
                    Spacer()
                    Image(systemName: "face.smiling").font(.system(size: 40)).foregroundStyle(Theme.dim)
                    Text("还没有满意脸型").foregroundStyle(Theme.dim).padding(.top, 8)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(store.faces) { face in
                                cell(face)
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .imageSource(isPresented: $picking) { loaders in
            guard let load = loaders.first else { return }
            add(load)
        }
        // Mac：图片拖进窗口就添加。
        .onChange(of: MacSession.shared.dropped, initial: true) {
            guard let file = MacSession.shared.dropped.first else { return }
            MacSession.shared.dropped = []
            add { try? Data(contentsOf: file) }
        }
        .confirmationDialog("删除这个满意脸型？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let deleting { store.remove(deleting) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }

    private var phoneBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            Text("满意脸型").font(.system(size: 17, weight: .semibold))
            Spacer()
            Button { picking = true } label: {
                Group {
                    if busy { ProgressView().tint(.white) } else { Image(systemName: "plus") }
                }
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 44)
            }
            .disabled(busy)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 52)
    }

    private func add(_ load: @escaping ImageLoader) {
        guard !busy else { return }
        busy = true
        note = nil
        Task {
            var ok = false
            if let data = await load() { ok = await store.add(from: data) }
            busy = false
            if !ok { note = "这张图里没有找到人脸" }
        }
    }

    private func cell(_ face: FavoriteFace) -> some View {
        let isCurrent = store.current?.id == face.id
        return Button { store.setCurrent(face) } label: {
            Color(white: 0.12)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = store.image(face) { Image(uiImage: image).resizable().scaledToFill() }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isCurrent ? Theme.accent : Color.clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if isCurrent {
                        Image(systemName: "star.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.black)
                            .padding(5)
                            .background(Theme.accent, in: Circle())
                            .padding(5)
                    }
                }
        }
        .buttonStyle(PressStyle())
        .contextMenu {
            Button("设为当前") { store.setCurrent(face) }
            Button("删除", role: .destructive) { deleting = face }
        }
    }
}
