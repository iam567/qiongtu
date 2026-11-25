import Photos
import SwiftUI
import UIKit

/// 相册访问：授权、相簿列表、缩略图、原图数据。
@MainActor
@Observable
final class PhotoLibrary {
    enum Access { case unknown, granted, denied }

    struct Album: Identifiable, Hashable {
        let id: String
        let title: String
        let collection: PHAssetCollection?
        let count: Int
    }

    var access: Access = .unknown
    var albums: [Album] = []
    var current: Album?
    var count = 0

    @ObservationIgnored private var fetch: PHFetchResult<PHAsset>?

    private static var imageOptions: PHFetchOptions {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return o
    }

    func requestAccess() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            access = .denied
            return
        }
        access = .granted
        loadAlbums()
        if let first = albums.first { select(first) }
    }

    private func loadAlbums() {
        var list: [Album] = []
        let all = PHAsset.fetchAssets(with: Self.imageOptions)
        list.append(Album(id: "all", title: "最近项目", collection: nil, count: all.count))

        func append(_ result: PHFetchResult<PHAssetCollection>) {
            result.enumerateObjects { collection, _, _ in
                let n = PHAsset.fetchAssets(in: collection, options: Self.imageOptions).count
                guard n > 0 else { return }
                list.append(Album(id: collection.localIdentifier,
                                  title: collection.localizedTitle ?? "未命名",
                                  collection: collection, count: n))
            }
        }
        for subtype in [PHAssetCollectionSubtype.smartAlbumFavorites, .smartAlbumSelfPortraits, .smartAlbumScreenshots] {
            append(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype, options: nil))
        }
        append(PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil))
        albums = list
    }

    func select(_ album: Album) {
        current = album
        if let collection = album.collection {
            fetch = PHAsset.fetchAssets(in: collection, options: Self.imageOptions)
        } else {
            fetch = PHAsset.fetchAssets(with: Self.imageOptions)
        }
        count = fetch?.count ?? 0
    }

    func asset(at index: Int) -> PHAsset? {
        guard let fetch, index >= 0, index < fetch.count else { return nil }
        return fetch.object(at: index)
    }

    nonisolated static func asset(id: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    nonisolated static func image(for asset: PHAsset, pixelSize: CGSize, fill: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: pixelSize,
                                                  contentMode: fill ? .aspectFill : .aspectFit,
                                                  options: options) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }

    nonisolated static func data(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = true
            var resumed = false
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: data)
            }
        }
    }
}

/// 方形缩略图。
struct AssetThumb: View {
    let asset: PHAsset
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: asset.localIdentifier) {
            let px = side * 3
            image = await PhotoLibrary.image(for: asset, pixelSize: CGSize(width: px, height: px), fill: true)
        }
    }
}

extension PhotoLibrary {
    /// 读一张照片：有文件就读文件（Mac），没有就从相册取。
    static func image(assetID: String, fileURL: URL?) async -> UIImage? {
        if let fileURL {
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                let scoped = fileURL.startAccessingSecurityScopedResource()
                defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
                return try? Data(contentsOf: fileURL)
            }.value
            return data.flatMap { UIImage(data: $0) }
        }
        guard let asset = asset(id: assetID), let data = await data(for: asset) else { return nil }
        return UIImage(data: data)
    }
}
