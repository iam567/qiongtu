import CoreImage
import Vision

/// AI 改完的图，只在真正变了的地方用 AI 的像素，其余用原图的：
/// 没动的地方保持原来的清晰度和质感，不会整张都是 AI 重画出来的涂抹感。
enum ChangeKeep {
    private static let diffKernel = CIColorKernel(source: """
    kernel vec4 changed(__sample a, __sample b) {
        vec3 d = abs(a.rgb - b.rgb);
        float v = max(d.r, max(d.g, d.b));
        float m = smoothstep(0.045, 0.12, v);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// 看得更细：一两根飘着的发丝也算变了。
    private static let fineKernel = CIColorKernel(source: """
    kernel vec4 changedFine(__sample a, __sample b) {
        vec3 d = abs(linear_to_srgb(clamp(a.rgb, 0.0, 1.0)) - linear_to_srgb(clamp(b.rgb, 0.0, 1.0)));
        float v = max(d.r, max(d.g, d.b));
        float m = smoothstep(0.03, 0.08, v);
        return vec4(m, m, m, 1.0);
    }
    """)

    private static let outsideKernel = CIColorKernel(source: """
    kernel vec4 outsideGain(__sample s, __sample o, __sample a) {
        vec3 e = vec3(0.004);
        vec3 g = clamp((o.rgb + e) / (a.rgb + e), vec3(0.6), vec3(1.7));
        return vec4(s.rgb * g, s.a);
    }
    """)

    /// 只看 area 外面（背景）的色差来校正 AI 图：换衣服时人身上的颜色本来就要变，不能拿来比。
    private static func tonedByOutside(_ ai: CIImage, _ original: CIImage, _ area: CIImage, _ soft: (CIImage, CGFloat) -> CIImage, _ radius: CGFloat) -> CIImage {
        let outside = area.applyingFilter("CIColorInvert")
        func weighted(_ image: CIImage) -> CIImage {
            soft(image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: outside]).cropped(to: ai.extent), radius)
        }
        return outsideKernel?.apply(extent: ai.extent, arguments: [ai, weighted(original), weighted(ai)]) ?? ai
    }

    /// area：只允许在这一块里换（白 = 允许），不给就整张都可以。core：这一块一定用 AI 的（换衣服）。
    static func apply(original: CIImage, ai: CIImage, area: CIImage?, core: CIImage? = nil, fine: Bool = false) -> CIImage {
        let extent = original.extent
        let long = max(extent.width, extent.height)
        func soft(_ image: CIImage, _ radius: CGFloat) -> CIImage {
            image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        // AI 常把整张的明暗颜色带偏一点：先按大范围拉回原图的样子，再比较、再贴。
        let toned: CIImage
        if core != nil || fine, let area {
            toned = tonedByOutside(ai, original, area, soft, long * 0.12)
        } else {
            toned = ToneTransfer.apply(original: ai, graded: original, radius: long * 0.05)
        }
        let sigma = long * (fine ? 0.0016 : 0.0028)
        guard let diff = (fine ? fineKernel : diffKernel)?.apply(extent: extent, arguments: [soft(original, sigma), soft(toned, sigma)]) else { return ai }
        // 去掉零星的小点，再往外扩一点、羽化，接缝落在没变的地方。
        var mask = diff
            .clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: fine ? 0 : long * 0.0012])
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: long * 0.009])
            .cropped(to: extent)
        mask = soft(mask, long * 0.005)
        if let core {
            mask = core.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: mask]).cropped(to: extent)
        }
        if let area {
            mask = mask.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: area]).cropped(to: extent)
        }
        return toned.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: original,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    /// AI 图相对原图整体偏了多少（占宽高的比例）。偏得太多就不管（说明不是简单的平移）。
    static func shift(original: CGImage, ai: CGImage) -> CGVector {
        func small(_ image: CGImage) -> CGImage? {
            let k = 768 / CGFloat(max(original.width, original.height))
            let w = max(1, Int(CGFloat(original.width) * k)), h = max(1, Int(CGFloat(original.height) * k))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return ctx.makeImage()
        }
        guard let a = small(original), let b = small(ai) else { return .zero }
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: b)
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        guard (try? VNImageRequestHandler(cgImage: a, options: [:]).perform([request])) != nil,
              let t = (request.results?.first as? VNImageTranslationAlignmentObservation)?.alignmentTransform else { return .zero }
        // alignmentTransform 把 b 移到和 a 对齐（左下原点）。
        let dx = t.tx / CGFloat(a.width), dy = -t.ty / CGFloat(a.height)
        return abs(dx) < 0.02 && abs(dy) < 0.02 ? CGVector(dx: dx, dy: dy) : .zero
    }

    static func intersect(_ a: CGImage?, _ b: CGImage) -> CGImage? {
        guard let a else { return b }
        let x = CIImage(cgImage: a, options: [.colorSpace: NSNull()])
        let y = CIImage(cgImage: b, options: [.colorSpace: NSNull()])
        let fitted = y.transformed(by: CGAffineTransform(scaleX: x.extent.width / y.extent.width, y: x.extent.height / y.extent.height))
        let out = x.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: fitted]).cropped(to: x.extent)
        return Renderer.shared.context.createCGImage(out, from: x.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 人和人周围一圈（原图里的人和 AI 图里的人合起来，往外扩一点）。
    static func personArea(_ a: CGImage?, _ b: CGImage?, size: CGSize, grow: CGFloat = 22, blur: CGFloat = 8) -> CGImage? {
        let masks = [a, b].compactMap { $0 }
        guard !masks.isEmpty else { return nil }
        let k = 640 / max(size.width, size.height)
        let w = max(1, Int(size.width * k)), h = max(1, Int(size.height * k))
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        var out: CIImage = CIImage(color: .black).cropped(to: rect)
        for m in masks {
            let c = CIImage(cgImage: m, options: [.colorSpace: NSNull()])
            let s = c.transformed(by: CGAffineTransform(scaleX: rect.width / c.extent.width, y: rect.height / c.extent.height))
            out = s.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: out]).cropped(to: rect)
        }
        out = out.clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: grow])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur])
            .cropped(to: rect)
        return Renderer.shared.context.createCGImage(out, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}
