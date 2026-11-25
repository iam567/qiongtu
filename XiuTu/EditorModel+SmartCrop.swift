import CoreImage
import Photos
import SwiftUI

struct SmartCropState {
    var items: [SmartCropItem] = []
    var selected: UUID?
    var ratio: SmartCropRatio = .free
    var running = false
    var started = Date()
    var rounds = 0
    var error: String?
    var usage: String?
    var saving = false
    var note: String?

    var current: SmartCropItem? { items.first { $0.id == selected } }
}

extension EditorModel {
    func beginSmartCrop() {
        smartCropTask?.cancel()
        smartCropState = SmartCropState()
        #if DEBUG
        // 调试用：不连 AI，摆几个假的取景看界面。
        if ProcessInfo.processInfo.environment["XIUTU_SMARTCROP"] == "demo" {
            let demo = """
            {"crops":[{"title":"光与柱","how":"引导线","why":"线条把视线带到亮处","box":[120,180,560,820]},{"title":"小圆特写","how":"居中","why":"圆在大片留白里","box":[430,380,620,640]},{"title":"横幅全景","how":"三分法","why":"重心在右三分之一","box":[60,520,980,960]},{"title":"右上角落","how":"留白","why":"安静的一角","box":[640,40,960,330]},{"title":"方形对称","how":"对称","why":"左右平衡","box":[250,250,750,750]}]}
            """
            smartCropState.items = SmartCrop.parse(demo, minimum: 0.08)
            smartCropState.selected = smartCropState.items.first?.id
            smartCropState.usage = "本次实际用量：输入 2310、输出 640 token"
        }
        #endif
    }

    /// 照片的像素大小（按成品算）。
    private var smartCropPixels: CGSize {
        guard let base = basePreview?.extent.size, let proxy, let source else { return CGSize(width: 1, height: 1) }
        let long = max(proxy.extent.width, proxy.extent.height)
        let k = max(source.extent.width, source.extent.height) / max(long, 1)
        let preview = max(base.width, base.height)
        // 预览最长 1600：按原图比例放大回去。
        let full = max(proxy.extent.width, proxy.extent.height) * k
        return CGSize(width: base.width / preview * full, height: base.height / preview * full)
    }

    /// 裁出来的短边至少这么大（占宽高的比例）：大约 800 像素，最多三成。
    private var smartCropMinimum: CGFloat {
        let size = smartCropPixels
        return min(max(800 / max(min(size.width, size.height), 1), 0.08), 0.3)
    }

    func runSmartCrop() {
        guard tool == .smartCrop, !smartCropState.running, let base = basePreview else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            smartCropState.error = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        smartCropState.error = nil
        smartCropState.running = true
        smartCropState.started = Date()
        smartCropState.note = nil
        let size = smartCropPixels, minimum = smartCropMinimum, again = smartCropState.rounds > 0
        let ops = self.ops, proxy = self.proxy
        smartCropTask = Task { [weak self] in
            do {
                _ = AIClient.takeLastUsage()
                let jpeg = await Task.detached(priority: .userInitiated) { () -> Data? in
                    // 小局部也要看得清：发大一点的图。
                    let full = proxy.map { EditOp.apply(ops, to: $0) } ?? base
                    let small = Renderer.shared.downscaled(full, maxDimension: 2048)
                    let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                    return Renderer.shared.context.jpegRepresentation(of: small, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                      options: [quality: 0.88])
                }.value
                guard let jpeg else { throw AIError(text: "图片编码失败。") }
                let text = try await AIClient.look(endpoint, prompt: SmartCrop.prompt(size: size, minimum: minimum, hint: "", again: again), jpeg: jpeg)
                let usage = AIClient.takeLastUsage()
                if let cost = usage?.cost { AISettings.shared.addSpend(cost) }
                let found = SmartCrop.parse(text, minimum: minimum)
                guard let self, !Task.isCancelled, self.tool == .smartCrop else { return }
                self.smartCropState.running = false
                self.smartCropState.usage = usage?.summary
                guard !found.isEmpty else {
                    self.smartCropState.error = "AI 没有给出可用的取景，可以再试一次或换一家服务商。"
                    return
                }
                self.smartCropState.rounds += 1
                self.smartCropState.items = found
                self.smartCropState.selected = found.first?.id
                self.setSmartCropRatio(self.smartCropState.ratio)
            } catch is CancellationError {
                self?.smartCropState.running = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.smartCropState.running = false
                self.smartCropState.error = error.localizedDescription
            }
        }
    }

    func cancelSmartCrop() {
        smartCropTask?.cancel()
        smartCropState.running = false
    }

    func setSmartCropRatio(_ ratio: SmartCropRatio) {
        smartCropState.ratio = ratio
        guard let size = baseUIImage?.size else { return }
        for i in smartCropState.items.indices {
            smartCropState.items[i].rect = SmartCrop.fit(smartCropState.items[i].original, ratio: ratio.value(size), size: size)
        }
    }

    /// 手动拖框时锁定的比例（归一化坐标下的宽 / 高）。
    var smartCropLocked: CGFloat? {
        guard let size = baseUIImage?.size, let r = smartCropState.ratio.value(size) else { return nil }
        return r * size.height / size.width
    }

    var smartCropRect: CGRect {
        get { smartCropState.current?.rect ?? CGRect(x: 0, y: 0, width: 1, height: 1) }
        set {
            guard let i = smartCropState.items.firstIndex(where: { $0.id == smartCropState.selected }) else { return }
            smartCropState.items[i].rect = newValue
        }
    }

    func smartCropOp() -> EditOp? {
        guard let rect = smartCropState.current?.rect else { return nil }
        var p = CropParams()
        p.rect = rect
        return .crop(p)
    }

    /// 某个取景的小图。
    func smartCropThumb(_ item: SmartCropItem) -> UIImage? {
        guard let cg = baseUIImage?.cgImage else { return nil }
        let r = CGRect(x: item.rect.minX * CGFloat(cg.width), y: item.rect.minY * CGFloat(cg.height),
                       width: item.rect.width * CGFloat(cg.width), height: item.rect.height * CGFloat(cg.height)).integral
        return cg.cropping(to: r).map { UIImage(cgImage: $0) }
    }

    /// 所有取景按原图分辨率各裁一张。
    func smartCropImages() async -> [(title: String, data: Data)] {
        guard let source else { return [] }
        let ops = self.ops
        let items = smartCropState.items
        return await Task.detached(priority: .userInitiated) {
            items.compactMap { item in
                var p = CropParams()
                p.rect = item.rect
                let out = EditOp.apply(ops + [.crop(p)], to: source)
                let moved = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                return Renderer.shared.context.jpegRepresentation(of: moved, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                                  options: [quality: 0.95]).map { (item.title, $0) }
            }
        }.value
    }

    /// 手机：全部存进相册。
    func saveSmartCrops() {
        guard !smartCropState.saving else { return }
        smartCropState.saving = true
        Task {
            let list = await smartCropImages()
            var saved = 0
            for item in list {
                let ok = (try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: item.data, options: nil)
                }) != nil
                guard ok else { continue }
                saved += 1
                if HistoryStore.shared.enabled { await HistoryStore.shared.add(data: item.data, ext: "jpg", source: "智能构图") }
            }
            smartCropState.saving = false
            smartCropState.note = saved == list.count && saved > 0 ? "已保存 \(saved) 张到相册" : "保存失败，请检查相册权限"
        }
    }
}
