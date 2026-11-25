import CoreImage
import CoreGraphics
import Foundation

/// 比较"原图"和"AI 调过色的图"，算出一张整图通用的颜色对照表，再套回原图。
/// 整张照片同一种颜色永远变成同一种颜色，像换了一卷胶片：没有局部光晕，清晰度和纹理全是原图的。
enum StyleLUT {
    static let size = 25
    private static let space = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    /// 两张图要对齐（同样的构图）；大小可以不一样。
    static func fit(original: CGImage, graded: CGImage) -> Data? {
        let k = 420 / CGFloat(max(original.width, original.height))
        let w = max(8, Int(CGFloat(original.width) * k)), h = max(8, Int(CGFloat(original.height) * k))
        guard let a = pixels(original, w, h), let b = pixels(graded, w, h) else { return nil }
        let n = size
        let count = n * n * n
        var delta = [SIMD3<Float>](repeating: .zero, count: count)
        var weight = [Float](repeating: 0, count: count)
        func index(_ r: Int, _ g: Int, _ b: Int) -> Int { (b * n + g) * n + r }

        // 局部起伏大的地方（边缘、树叶）AI 图容易对不齐，权重放低。
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = (y * w + x) * 4
                let c = SIMD3<Float>(a[i], a[i + 1], a[i + 2])
                let d = SIMD3<Float>(b[i], b[i + 1], b[i + 2]) - c
                var edge: Float = 0
                for j in [i - 4, i + 4, i - w * 4, i + w * 4] {
                    edge = max(edge, abs(a[j] - c.x), abs(a[j + 1] - c.y), abs(a[j + 2] - c.z))
                }
                let trust = 1 / (1 + edge * edge * 160)
                let p = c * Float(n - 1)
                let r0 = min(Int(p.x), n - 2), g0 = min(Int(p.y), n - 2), b0 = min(Int(p.z), n - 2)
                let f = p - SIMD3(Float(r0), Float(g0), Float(b0))
                for corner in 0..<8 {
                    let dr = corner & 1, dg = (corner >> 1) & 1, db = corner >> 2
                    let t = (dr == 1 ? f.x : 1 - f.x) * (dg == 1 ? f.y : 1 - f.y) * (db == 1 ? f.z : 1 - f.z) * trust
                    let at = index(r0 + dr, g0 + dg, b0 + db)
                    delta[at] += d * t
                    weight[at] += t
                }
            }
        }
        for i in 0..<count where weight[i] > 0 { delta[i] /= weight[i] }

        // 照片里没有的颜色跟着最接近的颜色走；有的颜色也稍微和邻居拉平，过渡才顺。
        var out = delta
        var known = weight.map { $0 / ($0 + 3) }
        // 完全没数据的格子先从最近的有数据格子往外填。
        var filled = weight.map { $0 > 0.05 }
        if !filled.contains(true) { return nil }
        while filled.contains(false) {
            var next = filled
            for b0 in 0..<n { for g0 in 0..<n { for r0 in 0..<n {
                let i = index(r0, g0, b0)
                if filled[i] { continue }
                var sum = SIMD3<Float>.zero, c: Float = 0
                for (dr, dg, db) in neighbors {
                    let r = r0 + dr, g = g0 + dg, b = b0 + db
                    guard r >= 0, g >= 0, b >= 0, r < n, g < n, b < n else { continue }
                    let j = index(r, g, b)
                    if filled[j] { sum += out[j]; c += 1 }
                }
                if c > 0 {
                    out[i] = sum / c
                    next[i] = true
                    known[i] = 0
                }
            } } }
            filled = next
        }
        let anchor = out
        for _ in 0..<40 {
            var next = out
            for b0 in 0..<n { for g0 in 0..<n { for r0 in 0..<n {
                let i = index(r0, g0, b0)
                var sum = SIMD3<Float>.zero, c: Float = 0
                for (dr, dg, db) in neighbors {
                    let r = r0 + dr, g = g0 + dg, b = b0 + db
                    guard r >= 0, g >= 0, b >= 0, r < n, g < n, b < n else { continue }
                    sum += out[index(r, g, b)]
                    c += 1
                }
                next[i] = anchor[i] * known[i] + (sum / c) * (1 - known[i])
            } } }
            out = next
        }
        // 有数据的格子再轻轻抹一遍，去掉个别颜色跳动。
        for _ in 0..<2 {
            var next = out
            for b0 in 0..<n { for g0 in 0..<n { for r0 in 0..<n {
                var sum = out[index(r0, g0, b0)] * 2, c: Float = 2
                for (dr, dg, db) in neighbors {
                    let r = r0 + dr, g = g0 + dg, b = b0 + db
                    guard r >= 0, g >= 0, b >= 0, r < n, g < n, b < n else { continue }
                    sum += out[index(r, g, b)] * 0.5
                    c += 0.5
                }
                next[index(r0, g0, b0)] = sum / c
            } } }
            out = next
        }

        var data = Data(count: count * 16)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            let inv = 1 / Float(n - 1)
            for b0 in 0..<n { for g0 in 0..<n { for r0 in 0..<n {
                let i = index(r0, g0, b0)
                let base = SIMD3<Float>(Float(r0), Float(g0), Float(b0)) * inv
                let v = (base + out[i]).clamped(lowerBound: .zero, upperBound: SIMD3(repeating: 1))
                p[i * 4] = v.x
                p[i * 4 + 1] = v.y
                p[i * 4 + 2] = v.z
                p[i * 4 + 3] = 1
            } } }
        }
        return data
    }

    private static let neighbors = [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)]

    static func apply(_ cube: Data, to image: CIImage, strength: CGFloat) -> CIImage {
        guard strength > 0.005 else { return image }
        let out = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": size, "inputCubeData": cube, "inputColorSpace": space,
        ])
        return strength >= 0.995 ? out : FX.mix(image, out, t: strength)
    }

    private static func pixels(_ image: CGImage, _ w: Int, _ h: Int) -> [Float]? {
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px.map { Float($0) / 255 } : nil
    }
}
