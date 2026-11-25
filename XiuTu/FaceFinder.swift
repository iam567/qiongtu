import CoreImage
import SwiftUI
import Vision

/// 找不到脸时的几道补救：大图分块放大找、在点的位置放大找、让 AI 指出位置。
enum FaceFinder {
    /// 小脸：把画面里有人的地方切成小块放大了再找。没人的照片很快就放弃。
    static func deep(_ image: CGImage, thorough: Bool = false) -> [FaceInfo] {
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = false
        let upper = VNDetectHumanRectanglesRequest()
        upper.upperBodyOnly = true
        #if targetEnvironment(simulator)
        human.usesCPUOnly = true
        upper.usesCPUOnly = true
        #endif
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([human, upper])
        var crops: [CGRect] = []
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        for (list, share) in [(human.results ?? [], 0.36), (upper.results ?? [], 0.7)] {
            for r in list where r.confidence > 0.25 {
                // 人的上面一截，左右上下多留一些。
                let b = r.boundingBox
                let h = b.height * share
                let side = max(b.width * 1.3, h * 1.5 / aspect)
                crops.append(CGRect(x: b.midX - side / 2, y: 1 - b.maxY - h * 0.35, width: side, height: h * 1.7))
            }
        }
        var found = search(image, crops)
        if found.isEmpty, thorough || !crops.isEmpty || PersonSegmenter.mask(for: image) != nil {
            for size in (thorough ? [0.5, 0.3, 0.18] : [0.5, 0.3]) as [CGFloat] {
                let step = size * 0.6
                var tiles: [CGRect] = []
                var y: CGFloat = 0
                while true {
                    var x: CGFloat = 0
                    while true {
                        tiles.append(CGRect(x: min(x, 1 - size), y: min(y, 1 - size), width: size, height: size))
                        if x + size >= 1 { break }
                        x += step
                    }
                    if y + size >= 1 { break }
                    y += step
                }
                found = search(image, tiles)
                if !found.isEmpty { break }
            }
        }
        return found
    }

    /// 在点的位置找：从小到大几种范围，放大了再找；都认不出就按点的位置给一个框（没有五官，AI 美颜够用）。
    static func at(_ point: CGPoint, in image: CGImage) -> FaceInfo {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        for side in [0.1, 0.18, 0.06, 0.32] as [CGFloat] {
            let h = side * aspect
            let hit = search(image, [CGRect(x: point.x - side / 2, y: point.y - h / 2, width: side, height: h)])
                .first { $0.box.insetBy(dx: -$0.box.width * 0.4, dy: -$0.box.height * 0.4).contains(point) }
            if let hit { return hit }
        }
        let w: CGFloat = 0.045
        return FaceInfo(box: CGRect(x: point.x - w / 2, y: point.y - w * aspect * 0.6, width: w, height: w * aspect * 1.2))
    }

    /// AI 说脸在这个框里：在那儿放大了量五官，量不出就只用框。
    static func refine(_ box: CGRect, in image: CGImage) -> FaceInfo {
        let grown = box.insetBy(dx: -box.width * 0.8, dy: -box.height * 0.8)
        let c = CGPoint(x: box.midX, y: box.midY)
        return search(image, [grown, box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3)])
            .first { $0.box.insetBy(dx: -$0.box.width * 0.5, dy: -$0.box.height * 0.5).contains(c) } ?? FaceInfo(box: box)
    }

    /// 每一块裁出来放大到 1000 像素找脸，坐标换回整张图；同一张脸只留一个。
    private static func search(_ image: CGImage, _ crops: [CGRect]) -> [FaceInfo] {
        let size = CGSize(width: image.width, height: image.height)
        var out: [FaceInfo] = []
        for crop in crops {
            let r = CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
                .intersection(CGRect(origin: .zero, size: size)).integral
            guard r.width >= 24, r.height >= 24, let piece = image.cropping(to: r) else { continue }
            let k = min(6, 1000 / max(r.width, r.height))
            let w = max(1, Int(r.width * max(k, 0.2))), h = max(1, Int(r.height * max(k, 0.2)))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let big = ctx.makeImage() else { continue }
            for face in FaceDetector.direct(in: big) {
                let moved = face.mapped { CGPoint(x: (r.minX + $0.x * r.width) / size.width, y: (r.minY + $0.y * r.height) / size.height) }
                if !out.contains(where: { $0.box.intersects(moved.box) && $0.box.intersection(moved.box).width > min($0.box.width, moved.box.width) * 0.4 }) {
                    out.append(moved)
                }
            }
        }
        return out.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height }
    }

    static let prompt = """
    找出这张照片里所有人的脸（包括很小的、侧着的、逆光的、被头发或帽子挡住一部分的），不要把雕像、画、玩偶和花纹当成脸。\
    框要贴着脸：上到发际线，下到下巴，左右到脸颊边缘。坐标用千分比：照片左上角是 (0,0)，右下角是 (1000,1000)，box 依次是 左、上、右、下。\
    只输出 JSON，不要别的字：{"faces":[{"box":[左,上,右,下]}]}。没有人脸就输出 {"faces":[]}。
    """
}

extension FaceInfo {
    /// 所有坐标换一套。
    func mapped(_ f: (CGPoint) -> CGPoint) -> FaceInfo {
        let a = f(CGPoint(x: box.minX, y: box.minY)), b = f(CGPoint(x: box.maxX, y: box.maxY))
        var out = self
        out.box = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
        out.contour = contour.map(f)
        out.leftEye = leftEye.map(f)
        out.rightEye = rightEye.map(f)
        out.leftBrow = leftBrow.map(f)
        out.rightBrow = rightBrow.map(f)
        out.outerLips = outerLips.map(f)
        out.innerLips = innerLips.map(f)
        out.nose = nose.map(f)
        out.leftPupil = leftPupil.map(f)
        out.rightPupil = rightPupil.map(f)
        out.noseCrest = noseCrest.map { $0.map(f) }
        out.medianLine = medianLine.map { $0.map(f) }
        return out
    }
}

extension EditorModel {
    /// 找脸：先用预览图，找不到就用大图放大找；用户点的、AI 指的脸优先。
    func findFaces() async -> [FaceInfo] {
        if !forcedFaces.isEmpty, forcedFacesSize == basePreview?.extent.size { return forcedFaces }
        guard let cg = baseUIImage?.cgImage else { return [] }
        let first = await Task.detached(priority: .userInitiated) { FaceDetector.direct(in: cg) }.value
        if !first.isEmpty { return first }
        guard let big = await faceSource() else { return [] }
        return await Task.detached(priority: .userInitiated) {
            let whole = FaceDetector.direct(in: big)
            return whole.isEmpty ? FaceFinder.deep(big, thorough: true) : whole
        }.value
    }

    /// 找脸用的大图（最长 4096）。
    private func faceSource() async -> CGImage? {
        guard let proxy else { return baseUIImage?.cgImage }
        let ops = self.ops
        return await Task.detached(priority: .userInitiated) {
            Renderer.shared.rasterize(EditOp.apply(ops, to: proxy), maxDimension: 4096)?.cg
        }.value
    }

    /// 这个工具现在没有脸可用。
    var lacksFace: Bool {
        switch tool {
        case .beauty: return faces.isEmpty && !detectingFaces
        case .reshape: return !reshapeState.detecting && !reshapeState.usable.contains(true)
        case .makeup: return !makeupState.detecting && makeupState.faces.isEmpty && makeupState.category.isLocal
        case .skin: return !skinState.detecting && skinState.params.faces.isEmpty && !skinState.wantsStrokes
        default: return false
        }
    }

    /// 找不到脸时点了画面：就当脸在那儿。返回 true = 处理了这次点击。
    func rescueFace(at point: CGPoint) -> Bool {
        guard lacksFace, !faceRescuing else { return false }
        faceRescuing = true
        faceRescueError = nil
        Task {
            if let big = await faceSource() {
                let face = await Task.detached(priority: .userInitiated) { FaceFinder.at(point, in: big) }.value
                useForced([face])
            }
            faceRescuing = false
        }
        return true
    }

    /// 让能看图的 AI 指出脸在哪儿。
    func aiFindFaces() {
        guard !faceRescuing else { return }
        guard let endpoint = AISettings.shared.endpoint() else {
            faceRescueError = "还没有设置 \(AISettings.shared.active.shortTitle) 的 API Key。"
            return
        }
        faceRescuing = true
        faceRescueError = nil
        let started = tool
        Task {
            defer { faceRescuing = false }
            do {
                guard let big = await faceSource() else { throw AIError(text: "图片读不出来。") }
                let jpeg = await Task.detached(priority: .userInitiated) {
                    AIOneShot.prepared(UIImage(cgImage: big), maxSide: 2048).jpegData(compressionQuality: 0.88)
                }.value
                guard let jpeg else { throw AIError(text: "图片编码失败。") }
                let text = try await AIClient.look(endpoint, prompt: FaceFinder.prompt, jpeg: jpeg)
                let boxes = SmartCrop.boxes(text, key: "faces")
                guard !boxes.isEmpty else { throw AIError(text: "AI 也没有找到人脸，可以直接点一下脸的位置。") }
                let found = await Task.detached(priority: .userInitiated) { boxes.map { FaceFinder.refine($0, in: big) } }.value
                guard tool == started else { return }
                useForced(found.sorted { $0.box.width * $0.box.height > $1.box.width * $1.box.height })
            } catch {
                faceRescueError = error.localizedDescription
            }
        }
    }

    private func useForced(_ faces: [FaceInfo]) {
        forcedFaces = faces
        forcedFacesSize = basePreview?.extent.size
        switch tool {
        case .beauty: detectFaces()
        case .reshape: beginReshape()
        case .makeup: beginMakeup()
        case .skin: beginSkin()
        default: break
        }
    }
}

/// 没找到脸时面板里显示的：原因，加"AI 找脸"。画面上点一下脸的位置也可以。
struct FaceRescue: View {
    let model: EditorModel
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            if model.faceRescuing {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在找人脸…").font(.system(size: 14))
                }
            } else {
                Text(model.faceRescueError ?? message + "，可以点一下脸的位置，或者让 AI 找")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.aiFindFaces() } label: {
                    Label("AI 找脸", systemImage: "face.dashed")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 26)
                        .frame(height: 40)
                        .background(Theme.accent, in: Theme.buttonShape)
                        .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: 4, y: -5) }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}
