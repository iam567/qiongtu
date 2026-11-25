import CoreImage
import CoreGraphics
import Foundation
import simd

/// 身体提亮的各项。
enum BodyToneKey: String, CaseIterable, Identifiable, Hashable {
    case bright, match, even, warm, rosy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bright: return "提亮"
        case .match: return "匹配脸色"
        case .even: return "匀肤色"
        case .warm: return "冷暖"
        case .rosy: return "红润"
        }
    }

    var symbol: String {
        switch self {
        case .bright: return "sun.max"
        case .match: return "face.smiling"
        case .even: return "circle.lefthalf.filled"
        case .warm: return "thermometer.medium"
        case .rosy: return "heart"
        }
    }

    /// 能往两边调的。
    var signed: Bool { self == .bright || self == .warm || self == .rosy }
}

/// 身体提亮：只动身体的皮肤，脸不动。范围 = 人身上和"身体颜色"相近的地方（去掉脸）+ 涂上的 − 擦掉的。
struct BodyToneParams {
    var values: [BodyToneKey: CGFloat] = [:]
    /// 身体的肤色（点选的，或者自动找的），sRGB 0...1。
    var tone = SIMD3<Float>(0.75, 0.58, 0.5)
    /// 颜色差多少以内算身体（0...1，越大范围越宽）。
    var range: CGFloat = 0.45
    /// 没有身体可选时只用涂的。
    var useColor = true
    /// 人像蒙版；nil = 没认出人，整张按颜色选。
    var person: CGImage?
    /// 脸的蒙版（白 = 脸，不动）。
    var face: CGImage?
    var strokes: [MosaicStroke] = []
    /// 脸和身体的平均颜色（算"匹配脸色""匀肤色"用）。
    var faceMean: SIMD3<Float>?
    var bodyMean = SIMD3<Float>(0.6, 0.5, 0.45)

    subscript(_ key: BodyToneKey) -> CGFloat { values[key] ?? 0 }

    var isIdentity: Bool { values.values.allSatisfy { $0 == 0 } }

    private static let library = """
    vec3 btYCC(vec3 c) {
        float y = dot(c, vec3(0.299, 0.587, 0.114));
        return vec3(y, (c.b - y) * 0.564, (c.r - y) * 0.713);
    }
    """

    /// 和身体颜色像不像：看色度，明暗放得很宽（阴影里的皮肤也算）。
    private static let pickKernel = CIColorKernel(source: library + """
    kernel vec4 bodyPick(__sample s, vec3 tone, float range) {
        vec3 a = btYCC(clamp(s.rgb, 0.0, 1.0)), b = btYCC(tone);
        // 暗处色度会缩小：按亮度比折算后再比。
        float k = clamp(b.x / max(a.x, 0.06), 0.6, 2.2);
        vec2 d = a.yz * k - b.yz;
        float dist = length(d * vec2(1.0, 1.15));
        float limit = mix(0.02, 0.11, range);
        float chroma = 1.0 - smoothstep(limit * 0.6, limit * 1.35, dist);
        float light = smoothstep(0.05, 0.14, a.x) * (1.0 - smoothstep(0.94, 1.0, a.x) * 0.3);
        float near = 1.0 - smoothstep(0.35, 0.75, abs(a.x - b.x) * mix(1.5, 0.7, range));
        float m = chroma * light * near;
        return vec4(m, m, m, 1.0);
    }
    """)

    private static let toneKernel = CIColorKernel(source: library + """
    kernel vec4 bodyTone(__sample s, __sample mid, __sample m, vec4 p, float rosy, vec3 gain, float mean) {
        vec3 c = clamp(s.rgb, 0.0, 1.0);
        // 匀肤色：把大块的明暗不均往平均亮度拉。
        float y = dot(mid.rgb, vec3(0.299, 0.587, 0.114));
        float level = clamp(mean / max(y, 0.05), 0.65, 1.6);
        float e = mix(1.0, level, p.z * 0.6);
        // 匹配脸色 + 匀肤色：提亮不溢出。
        vec3 g = mix(vec3(1.0), gain, p.y) * e;
        c = c * g / (vec3(1.0) + c * max(g - vec3(1.0), vec3(0.0)));
        // 提亮 / 压暗：中间调动得多，黑和白不动。
        float b = p.x;
        c = b >= 0.0 ? c + b * 0.9 * c * (vec3(1.0) - c) : c + b * 0.7 * c * (vec3(1.0) - c * 0.6);
        float l = dot(c, vec3(0.299, 0.587, 0.114));
        c += vec3(0.045, 0.006, -0.05) * p.w * l * 2.0 * (1.0 - l * 0.5);
        c += vec3(0.045, -0.018, -0.004) * rosy * l * 2.0 * (1.0 - l * 0.5);
        return vec4(mix(s.rgb, clamp(c, 0.0, 1.0), m.r), s.a);
    }
    """)

    /// 选中的范围（白 = 要调的地方）。
    func mask(for image: CIImage) -> CIImage {
        let e = image.extent
        let long = max(e.width, e.height)
        func scaled(_ cg: CGImage) -> CIImage { AIRegion.scaled(mask: cg, to: e, feather: false) }
        var m = CIImage(color: .black).cropped(to: e)
        if useColor {
            // 先轻轻模糊再比颜色，毛孔和噪点不会把范围打碎。
            let smooth = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: long * 0.0015]).cropped(to: e)
            if let picked = Self.pickKernel?.apply(extent: e, arguments: [smooth, CIVector(x: CGFloat(tone.x), y: CGFloat(tone.y), z: CGFloat(tone.z)), range]) {
                m = picked
                if let person { m = Self.times(m, scaled(person)).cropped(to: e) }
                m = m.clampedToExtent()
                    .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: long * 0.0008])
                    .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: long * 0.0016])
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: long * 0.0022])
                    .cropped(to: e)
            }
        }
        let adds = strokes.filter { !$0.erase }
        // 一笔一笔按先后来：后擦的擦掉先涂的，也擦掉自动选的。
        if !strokes.isEmpty, let painted = AIRegion.mask(strokes: adds.isEmpty ? [] : strokes, extent: e, feather: true) {
            m = painted.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: m]).cropped(to: e)
        }
        let erased = strokes.filter(\.erase).map { s -> MosaicStroke in
            var s = s
            s.erase = false
            return s
        }
        if !erased.isEmpty, let hole = AIRegion.mask(strokes: Self.lastErases(strokes) ?? erased, extent: e, feather: true) {
            m = Self.times(m, hole.applyingFilter("CIColorInvert")).cropped(to: e)
        }
        // 脸不动。涂上去的地方除外：用户自己涂到脸上就听用户的。
        if let face {
            var keep = scaled(face).applyingFilter("CIColorInvert")
            if !adds.isEmpty, let painted = AIRegion.mask(strokes: strokes, extent: e, feather: true) {
                keep = painted.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: keep]).cropped(to: e)
            }
            m = Self.times(m, keep).cropped(to: e)
        }
        return m
    }

    /// 擦除的范围要减掉"擦完以后又涂回来"的：把笔画反过来画一遍就是。
    private static func lastErases(_ strokes: [MosaicStroke]) -> [MosaicStroke]? {
        strokes.map { s -> MosaicStroke in
            var s = s
            s.erase.toggle()
            return s
        }
    }

    private static func times(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    func apply(to image: CIImage) -> CIImage {
        guard !isIdentity, let kernel = Self.toneKernel else { return image }
        let e = image.extent
        let long = max(e.width, e.height)
        let mid = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: long * 0.018]).cropped(to: e)
        var gain = SIMD3<Float>(repeating: 1)
        if let faceMean {
            // 着色器里的提亮是 c·g / (1 + c·(g−1))，按它反推出正好到脸色的倍数。
            for i in 0..<3 {
                let c = min(max(bodyMean[i], 0.05), 0.95), t = min(max(faceMean[i], 0.05), 0.95)
                gain[i] = t > c ? t * (1 - c) / (c * (1 - t)) : t / c
            }
            gain = simd_clamp(gain, SIMD3(repeating: 0.6), SIMD3(repeating: 5))
        }
        let mean = bodyMean.x * 0.299 + bodyMean.y * 0.587 + bodyMean.z * 0.114
        let p = CIVector(x: self[.bright], y: self[.match], z: self[.even], w: self[.warm])
        return kernel.apply(extent: e, arguments: [image, mid, mask(for: image), p, self[.rosy],
                                                   CIVector(x: CGFloat(gain.x), y: CGFloat(gain.y), z: CGFloat(gain.z)), mean]) ?? image
    }
}

/// 进工具时在本机做的识别：人像、脸，以及身体的肤色。
enum BodyToneDetector {
    struct Found {
        var person: CGImage?
        var face: CGImage?
        var faceMean: SIMD3<Float>?
        var tone: SIMD3<Float>?
    }

    static func detect(in image: CGImage) -> Found {
        var found = Found()
        found.person = PersonSegmenter.mask(for: image)
        let faces = FaceDetector.detect(in: image)
        if !faces.isEmpty { found.face = faceMask(faces, width: image.width, height: image.height) }
        if let main = faces.max(by: { $0.box.width < $1.box.width }) {
            // 脸颊中间那一块的平均色。
            let b = main.box
            let cheek = CGRect(x: b.minX + b.width * 0.25, y: b.minY + b.height * 0.45, width: b.width * 0.5, height: b.height * 0.3)
            found.faceMean = mean(image, cheek)
            found.tone = found.faceMean
        }
        return found
    }

    static func mean(_ image: CGImage, _ rect: CGRect) -> SIMD3<Float>? {
        let r = CGRect(x: rect.minX * CGFloat(image.width), y: rect.minY * CGFloat(image.height),
                       width: rect.width * CGFloat(image.width), height: rect.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1, let piece = image.cropping(to: r) else { return nil }
        var px = [UInt8](repeating: 0, count: 8 * 8 * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(piece, in: CGRect(x: 0, y: 0, width: 8, height: 8))
            return true
        }
        guard ok else { return nil }
        var sum = SIMD3<Float>(repeating: 0)
        for i in stride(from: 0, to: px.count, by: 4) { sum += SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2])) }
        return sum / Float(64 * 255)
    }

    /// 范围里的平均颜色（按蒙版加权）。
    static func mean(_ image: CIImage, mask: CIImage) -> SIMD3<Float>? {
        let e = image.extent
        let k = 160 / max(e.width, e.height)
        let w = max(1, Int(e.width * k)), h = max(1, Int(e.height * k))
        func pixels(_ i: CIImage, _ space: CGColorSpace?) -> [UInt8] {
            let s = i.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: k, y: k))
            var out = [UInt8](repeating: 0, count: w * h * 4)
            Renderer.shared.context.render(s, toBitmap: &out, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                                           format: .RGBA8, colorSpace: space)
            return out
        }
        let a = pixels(image, CGColorSpace(name: CGColorSpace.sRGB)), m = pixels(mask, nil)
        var sum = SIMD3<Double>(repeating: 0), weight = 0.0
        for i in stride(from: 0, to: a.count, by: 4) {
            let t = Double(m[i]) / 255
            sum += SIMD3(Double(a[i]), Double(a[i + 1]), Double(a[i + 2])) * t
            weight += t
        }
        guard weight > 12 else { return nil }
        let r = sum / (weight * 255)
        return SIMD3(Float(r.x), Float(r.y), Float(r.z))
    }

    private static func faceMask(_ faces: [FaceInfo], width: Int, height: Int) -> CGImage? {
        let k = 900 / CGFloat(max(width, height))
        let w = max(1, Int(CGFloat(width) * k)), h = max(1, Int(CGFloat(height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        var feather: CGFloat = 3
        for f in faces {
            func p(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x * CGFloat(w), y: (1 - q.y) * CGFloat(h)) }
            let b = f.box
            feather = max(feather, b.width * CGFloat(w) * 0.035)
            if f.hasReliableLandmarks {
                // 下颌线 + 往上到发际线。
                let eyes = f.leftEye + f.rightEye
                let ey = eyes.map(\.y).reduce(0, +) / CGFloat(eyes.count)
                let chin = f.contour.map(\.y).max() ?? b.maxY
                let top = ey - (chin - ey) * 0.75
                var line = f.contour
                let first = f.contour[0], last = f.contour[f.contour.count - 1]
                line.append(CGPoint(x: last.x + (first.x - last.x) * 0.06, y: top + (ey - top) * 0.35))
                line.append(CGPoint(x: last.x + (first.x - last.x) * 0.25, y: top))
                line.append(CGPoint(x: last.x + (first.x - last.x) * 0.75, y: top))
                line.append(CGPoint(x: first.x + (last.x - first.x) * 0.06, y: top + (ey - top) * 0.35))
                ctx.addLines(between: line.map(p))
                ctx.closePath()
                ctx.fillPath()
            } else {
                let r = CGRect(x: b.minX * CGFloat(w), y: (1 - b.maxY) * CGFloat(h), width: b.width * CGFloat(w), height: b.height * CGFloat(h) * 1.15)
                ctx.fillEllipse(in: r)
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        let m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let soft = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather]).cropped(to: m.extent)
        return Renderer.shared.context.createCGImage(soft, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
