import CoreGraphics
import CoreImage

/// 换衣服时算哪里用 AI 的、哪里用原图。
enum OutfitMask {
    /// 人在画面里的范围（归一化，左上原点），四周留出放裙摆和看清环境的余量。认不出人返回 nil。
    static func crop(_ image: CGImage) -> CGRect? {
        guard let person = PersonSegmenter.main(PersonSegmenter.mask(for: image)) else { return nil }
        let w = 128, h = 128
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(person, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var x0 = w, x1 = -1, y0 = h, y1 = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] > 128 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        guard x1 > x0, y1 > y0 else { return nil }
        let box = CGRect(x: CGFloat(x0) / 128, y: CGFloat(y0) / 128, width: CGFloat(x1 - x0 + 1) / 128, height: CGFloat(y1 - y0 + 1) / 128)
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        // 裙子会比原来的衣服宽：左右多留。
        let side = max(box.width * 0.45, box.height * ih / iw * 0.22)
        var r = CGRect(x: box.minX - side, y: box.minY - box.height * 0.08, width: box.width + side * 2, height: box.height * 1.2)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // 太瘦长的补宽，接口对比例有限制。
        if r.height * ih > r.width * iw * 2.2 {
            let want = r.height * ih / 2.2 / iw
            r = CGRect(x: r.midX - want / 2, y: r.minY, width: want, height: r.height).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        // 几乎就是整张图时不裁。
        return r.width * r.height > 0.72 ? nil : r
    }

    /// 换发型要发出去的范围：头顶往上留一些，往下到膝盖上面，两边把飘开的头发也包进来。认不出人就发整张。
    static func hairCrop(_ image: CGImage) -> CGRect? {
        guard let person = crop(image) ?? (PersonSegmenter.mask(for: image) == nil ? nil : CGRect(x: 0, y: 0, width: 1, height: 1)) else { return nil }
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        guard let f = FaceDetector.detect(in: image).max(by: { $0.box.width < $1.box.width }) else {
            return person.width * person.height > 0.72 ? nil : person
        }
        let h = max(f.box.height, f.box.width * iw / ih)
        let top = f.box.minY - h * 1.6, bottom = f.box.maxY + h * 6
        let half = max(h * ih / iw * 4, f.box.width * 4)
        var r = CGRect(x: f.box.midX - half, y: top, width: half * 2, height: bottom - top).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        if r.height * ih > r.width * iw * 2.2 { r = r.insetBy(dx: -(r.height * ih / 2.2 / iw - r.width) / 2, dy: 0).intersection(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return r.width * r.height > 0.72 ? nil : r
    }

    /// 换发型允许换的范围：人和周围一大圈（飘开的发丝），不出发出去的那一块，也只到腰下。
    static func hairArea(original: CGImage, ai: CGImage, crop: CGRect?) -> CGImage? {
        let size = CGSize(width: original.width, height: original.height)
        let a = PersonSegmenter.main(PersonSegmenter.mask(for: original)), b = PersonSegmenter.main(PersonSegmenter.mask(for: ai))
        let face = FaceDetector.detect(in: original).max { $0.box.width < $1.box.width }
        // 往外扩多少跟着脸的大小走：发丝能飘出去一个多头宽。
        let unit = face.map { max($0.box.width * size.width, $0.box.height * size.height) / max(size.width, size.height) * 640 } ?? 40
        guard let near = ChangeKeep.personArea(a, b, size: size, grow: min(max(unit * 1.2, 24), 90), blur: 6) else { return nil }
        let w = near.width, h = near.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return near }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        // 离发出去那一块的边近的不用，接缝不露。
        let c = crop ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let inset = crop == nil ? 0 : CGFloat(w) * 0.015
        // 贴着照片边的那一边不用缩。
        let x0 = c.minX * CGFloat(w) + (c.minX > 0.002 ? inset : 0), x1 = c.maxX * CGFloat(w) - (c.maxX < 0.998 ? inset : 0)
        let y0 = (1 - c.maxY) * CGFloat(h) + (c.maxY < 0.998 ? inset : 0), y1 = (1 - c.minY) * CGFloat(h) - (c.minY > 0.002 ? inset : 0)
        ctx.fill(CGRect(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1)))
        guard let gate = ctx.makeImage() else { return near }
        let m = CIImage(cgImage: gate, options: [.colorSpace: NSNull()])
        let soft = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(inset * 0.6, 1)]).cropped(to: m.extent)
        guard let g = Renderer.shared.context.createCGImage(soft, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return near }
        return ChangeKeep.intersect(near, g)
    }

    /// 把裁出来那一块的结果拼回整张图（按结果的清晰度，长边最多 5120）。
    static func paste(_ piece: CGImage, crop: CGRect, over base: CIImage) -> CGImage? {
        let e = base.extent
        let k = min(CGFloat(piece.width) / (crop.width * e.width), 5120 / max(e.width, e.height))
        let w = (e.width * k).rounded(), h = (e.height * k).rounded()
        let back = base.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: w / e.width, y: h / e.height))
        let target = CGRect(x: crop.minX * w, y: (1 - crop.maxY) * h, width: crop.width * w, height: crop.height * h)
        var p = CIImage(cgImage: piece)
        p = p.transformed(by: CGAffineTransform(scaleX: target.width / p.extent.width, y: target.height / p.extent.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
        let out = p.composited(over: back).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        return Renderer.shared.context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// area = 允许换的范围（新旧两个人合起来扩一圈；裙摆溢出画面时，胸口以下整片都允许）；
    /// core = 一定用 AI 的（新的人身上、下巴以下）。
    static func masks(original: CGImage, ai: CGImage, overflow: Bool, keepHead: Bool) -> (area: CGImage?, core: CGImage?) {
        let before = PersonSegmenter.main(PersonSegmenter.mask(for: original)), after = PersonSegmenter.main(PersonSegmenter.mask(for: ai))
        let size = CGSize(width: original.width, height: original.height)
        guard var area = ChangeKeep.personArea(before, after, size: size, grow: 12, blur: 5) else { return (nil, nil) }
        let faces = FaceDetector.detect(in: ai)
        let w = area.width, h = area.height
        func draw(_ body: (CGContext) -> Void, blur: CGFloat) -> CGImage? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            body(ctx)
            guard let cg = ctx.makeImage() else { return nil }
            let m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            let soft = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: m.extent)
            return Renderer.shared.context.createCGImage(soft, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        if overflow {
            let top = faces.max { $0.box.width < $1.box.width }.map { $0.box.maxY + $0.box.height * 0.8 } ?? 0.5
            if let widened = draw({ ctx in
                ctx.draw(area, in: rect)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: (1 - min(max(top, 0.2), 0.85)) * CGFloat(h)))
            }, blur: 5) { area = widened }
        }
        // 头没挪：从头顶到下巴强制用原图。
        func head(_ ctx: CGContext) {
            for f in faces {
                let b = f.box
                let chin = f.contour.map(\.y).max() ?? b.maxY
                let top = b.minY - b.height * 1.1
                ctx.fill(CGRect(x: (b.midX - b.width * 0.95) * CGFloat(w), y: (1 - chin) * CGFloat(h),
                                width: b.width * 1.9 * CGFloat(w), height: (chin - top) * CGFloat(h)))
            }
        }
        if keepHead, let kept = draw({ ctx in
            ctx.draw(area, in: rect)
            ctx.setFillColor(gray: 0, alpha: 1)
            head(ctx)
        }, blur: 1.5) { area = kept }
        guard let after else { return (area, nil) }
        let core = draw({ ctx in
            ctx.draw(after, in: rect)
            ctx.setFillColor(gray: 0, alpha: 1)
            head(ctx)
        }, blur: 2.5)
        return (area, core)
    }
}
