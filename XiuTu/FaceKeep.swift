import CoreImage
import CoreGraphics
import simd

/// AI 整张重画以后，把原图里的脸按五官位置对齐、贴回到 AI 的结果上：
/// 皮肤纹理和五官用原图的，明暗和颜色跟着 AI 图走。脸上就没有涂抹感，也不会换了个人。
/// 坐标都以各自图的长边为 1，原点左上角。
struct FaceKeep: Equatable {
    /// 原图 → 结果图的相似变换：x' = a·x − b·y + tx，y' = b·x + a·y + ty。
    var a: Double
    var b: Double
    var tx: Double
    var ty: Double
    /// 结果图上脸的范围（闭合多边形）。
    var outline: [CGPoint]
    /// 结果图上脸的宽度。
    var width: CGFloat

    // MARK: 找对应

    /// original：发给 AI 之前的照片；result：AI 的结果。对不上的脸（转了头、换了表情、太小）不贴。
    /// forehead = false：额头不贴（换发型时刘海会变）。
    static func match(original: CGImage, result: CGImage, forehead: Bool = true) -> [FaceKeep] {
        let from = FaceDetector.detect(in: original).filter { $0.hasReliableLandmarks }
        let to = FaceDetector.detect(in: result).filter { $0.hasReliableLandmarks }
        guard !from.isEmpty, !to.isEmpty else { return [] }
        var used = Set<Int>()
        var out: [FaceKeep] = []
        // 大的脸先配。
        for face in to.sorted(by: { $0.box.width > $1.box.width }).prefix(4) {
            var best: (index: Int, keep: FaceKeep, error: Double)?
            for (i, source) in from.enumerated() where !used.contains(i) {
                guard CGFloat(original.width) * source.box.width >= 50,
                      let (keep, error) = fit(source, unit(original), face, unit(result), forehead) else { continue }
                if best == nil || error < best!.error { best = (i, keep, error) }
            }
            if let best {
                used.insert(best.index)
                out.append(best.keep)
            }
        }
        return out
    }

    /// 归一化坐标 → 长边为 1 的坐标。
    private static func unit(_ image: CGImage) -> CGSize {
        let long = CGFloat(max(image.width, image.height))
        return CGSize(width: CGFloat(image.width) / long, height: CGFloat(image.height) / long)
    }

    private static func fit(_ s: FaceInfo, _ su: CGSize, _ d: FaceInfo, _ du: CGSize, _ forehead: Bool) -> (FaceKeep, Double)? {
        func scaled(_ p: [CGPoint], _ u: CGSize) -> [CGPoint] { p.map { CGPoint(x: $0.x * u.width, y: $0.y * u.height) } }
        var from: [CGPoint] = [], to: [CGPoint] = []
        for (x, y) in [(s.leftEye, d.leftEye), (s.rightEye, d.rightEye), (s.nose, d.nose), (s.outerLips, d.outerLips)]
        where !x.isEmpty && x.count == y.count {
            from += scaled(x, su)
            to += scaled(y, du)
        }
        guard from.count >= 12 else { return nil }
        let n = Double(from.count)
        let mx = from.reduce(0) { $0 + Double($1.x) } / n, my = from.reduce(0) { $0 + Double($1.y) } / n
        let ux = to.reduce(0) { $0 + Double($1.x) } / n, uy = to.reduce(0) { $0 + Double($1.y) } / n
        var sa = 0.0, sb = 0.0, ss = 0.0
        for (p, q) in zip(from, to) {
            let px = Double(p.x) - mx, py = Double(p.y) - my, qx = Double(q.x) - ux, qy = Double(q.y) - uy
            sa += px * qx + py * qy
            sb += px * qy - py * qx
            ss += px * px + py * py
        }
        guard ss > 1e-9 else { return nil }
        let a = sa / ss, b = sb / ss
        let tx = ux - a * mx + b * my, ty = uy - b * mx - a * my
        let width = d.box.width * du.width
        var sum = 0.0
        for (p, q) in zip(from, to) {
            let x = a * Double(p.x) - b * Double(p.y) + tx, y = b * Double(p.x) + a * Double(p.y) + ty
            sum += pow(x - Double(q.x), 2) + pow(y - Double(q.y), 2)
        }
        // 五官位置的平均误差：超过脸宽的 4.5% 说明表情或角度变了。
        let error = (sum / n).squareRoot() / Double(width)
        guard error < 0.045, a > 0 else { return nil }
        guard let outline = outline(d, du, forehead) else { return nil }
        return (FaceKeep(a: a, b: b, tx: tx, ty: ty, outline: outline, width: width), error)
    }

    /// 脸的范围：下颌线往里收一点，上面盖到眉毛上方的额头，不碰到头发和背景。
    private static func outline(_ f: FaceInfo, _ u: CGSize, _ forehead: Bool) -> [CGPoint]? {
        func scaled(_ p: [CGPoint]) -> [CGPoint] { p.map { CGPoint(x: $0.x * u.width, y: $0.y * u.height) } }
        let jaw = scaled(f.contour), eyes = scaled(f.leftEye + f.rightEye), brows = scaled(f.leftBrow + f.rightBrow), lips = scaled(f.outerLips)
        guard jaw.count >= 5, !eyes.isEmpty, !lips.isEmpty else { return nil }
        func center(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        let e = center(eyes), m = center(lips)
        let up = CGVector(dx: e.x - m.x, dy: e.y - m.y)
        // 眉毛往上推半个"眼到嘴"的距离，就是额头。
        let lift: CGFloat = forehead ? 0.32 : 0
        var top = (brows.isEmpty ? eyes : brows).map { CGPoint(x: $0.x + up.dx * lift, y: $0.y + up.dy * lift) }
        top.append(contentsOf: brows)
        let hull = convexHull(jaw + top)
        let c = center(hull)
        return hull.map { CGPoint(x: c.x + ($0.x - c.x) * (forehead ? 0.93 : 0.82), y: c.y + ($0.y - c.y) * (forehead ? 0.93 : 0.86)) }
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        func half(_ list: [CGPoint]) -> [CGPoint] {
            var out: [CGPoint] = []
            for q in list {
                while out.count >= 2, cross(out[out.count - 2], out[out.count - 1], q) <= 0 { out.removeLast() }
                out.append(q)
            }
            out.removeLast()
            return out
        }
        return half(p) + half(p.reversed())
    }

    /// 结果图整体平移了 shift（占宽高的比例）以后的位置。
    mutating func move(_ shift: CGVector, size: CGSize) {
        guard shift != .zero else { return }
        let long = max(size.width, size.height)
        let dx = shift.dx * size.width / long, dy = shift.dy * size.height / long
        tx += Double(dx)
        ty += Double(dy)
        outline = outline.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    /// 这张脸在 AI 图里基本没动。
    var isStill: Bool {
        guard let first = outline.first else { return false }
        // 反推这一点在原图的位置，看差多少。
        let n = a * a + b * b
        let dx = Double(first.x) - tx, dy = Double(first.y) - ty
        let x = (a * dx + b * dy) / n, y = (a * dy - b * dx) / n
        let moved = hypot(x - Double(first.x), y - Double(first.y))
        return moved < Double(width) * 0.12 && abs(n.squareRoot() - 1) < 0.04 && abs(atan2(b, a)) < 0.04
    }

    // MARK: 贴回

    /// out：AI 的结果（已经放大到成品大小）；original：这一步之前的画面。
    func apply(to out: CIImage, original: CIImage) -> CIImage {
        let oe = original.extent, re = out.extent
        let l0 = max(oe.width, oe.height), l1 = max(re.width, re.height)
        // 原图像素（左下原点）→ 长边为 1、左上原点 → 相似变换 → 结果图像素（左下原点）。
        let toUnit = CGAffineTransform(a: 1 / l0, b: 0, c: 0, d: -1 / l0, tx: -oe.minX / l0, ty: oe.maxY / l0)
        let similar = CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
        let toPixels = CGAffineTransform(a: l1, b: 0, c: 0, d: -l1, tx: re.minX, ty: re.maxY)
        let warped = original.transformed(by: toUnit.concatenating(similar).concatenating(toPixels))

        let face = width * l1
        let pixels = outline.map { CGPoint(x: re.minX + $0.x * l1, y: re.maxY - $0.y * l1) }
        var box = CGRect(origin: pixels[0], size: .zero)
        for p in pixels { box = box.union(CGRect(origin: p, size: .zero)) }
        let region = box.insetBy(dx: -face * 0.45, dy: -face * 0.45).intersection(re).intersection(warped.extent).integral
        guard region.width > 8, region.height > 8, let mask = mask(pixels, region: region, feather: face * 0.07) else { return out }
        // 明暗和颜色跟着 AI 图，细节用原图。
        let toned = ToneTransfer.apply(original: warped.cropped(to: region), graded: out.cropped(to: region), radius: face * 0.075)
        return toned.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: out,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: re)
    }

    private func mask(_ points: [CGPoint], region: CGRect, feather: CGFloat) -> CIImage? {
        let k = min(1, 512 / max(region.width, region.height))
        let w = max(1, Int((region.width * k).rounded())), h = max(1, Int((region.height * k).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addLines(between: points.map { CGPoint(x: ($0.x - region.minX) * k, y: ($0.y - region.minY) * k) })
        ctx.closePath()
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        // 先往里缩再羽化，羽化的边完全落在脸里面。
        let m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let soft = m.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: feather * k])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.7, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1.7, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.7, w: 0), "inputBiasVector": CIVector(x: -0.7, y: -0.7, z: -0.7, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: m.extent)
        return soft.transformed(by: CGAffineTransform(scaleX: region.width / CGFloat(w), y: region.height / CGFloat(h)))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
    }
}

/// AI 的结果是不是黑白的：只取光影时要把原图残留的颜色也去掉。
enum MonoCheck {
    static func isMono(_ image: CGImage) -> Bool {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return false }
        var colored = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let hi = max(pixels[i], pixels[i + 1], pixels[i + 2]), lo = min(pixels[i], pixels[i + 1], pixels[i + 2])
            if Int(hi) - Int(lo) > 14 { colored += 1 }
        }
        return colored * 50 < side * side
    }
}
