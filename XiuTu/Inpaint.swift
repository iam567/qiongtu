import CoreGraphics
import Foundation

/// 本机的智能消除：用周围的纹理把涂掉的地方补上（PatchMatch，多尺度）。
enum Inpaint {
    /// 一张浮点图。
    private final class Plane {
        let w: Int, h: Int
        var rgb: [Float]
        var hole: [Bool]

        init(w: Int, h: Int) {
            self.w = w
            self.h = h
            rgb = [Float](repeating: 0, count: w * h * 3)
            hole = [Bool](repeating: false, count: w * h)
        }

        func half() -> Plane {
            let out = Plane(w: max(1, w / 2), h: max(1, h / 2))
            for y in 0..<out.h { for x in 0..<out.w {
                var sum = (Float(0), Float(0), Float(0)), n: Float = 0, holes = 0
                for dy in 0..<2 { for dx in 0..<2 {
                    let i = min(y * 2 + dy, h - 1) * w + min(x * 2 + dx, w - 1)
                    if hole[i] { holes += 1; continue }
                    sum.0 += rgb[i * 3]; sum.1 += rgb[i * 3 + 1]; sum.2 += rgb[i * 3 + 2]
                    n += 1
                } }
                let o = y * out.w + x
                out.hole[o] = holes > 0
                if n > 0 {
                    out.rgb[o * 3] = sum.0 / n
                    out.rgb[o * 3 + 1] = sum.1 / n
                    out.rgb[o * 3 + 2] = sum.2 / n
                }
            } }
            return out
        }
    }

    private static let r = 3

    /// image 和 mask 一样大；mask 白 = 要补的。返回补好的整块。补不了（到处都涂了）返回 nil。
    static func fill(_ image: CGImage, mask: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let px = bytes(image, w, h), let mk = gray(mask, w, h) else { return nil }
        let full = Plane(w: w, h: h)
        var holes = 0
        for i in 0..<(w * h) {
            full.hole[i] = mk[i] > 40
            if full.hole[i] { holes += 1 }
            for c in 0..<3 { full.rgb[i * 3 + c] = Float(px[i * 4 + c]) / 255 }
        }
        guard holes > 0 else { return image }
        guard holes * 10 < w * h * 9 else { return nil }
        var levels = [full]
        while min(levels.last!.w, levels.last!.h) > 110, levels.count < 7, thickness(levels.last!) > 4 { levels.append(levels.last!.half()) }

        // 最粗一层：从边上一块块往里补（先补纹理和线条最明确的），当作起点。
        exemplar(levels.last!)
        var field: [Int32] = []
        for l in stride(from: levels.count - 1, through: 0, by: -1) {
            let p = levels[l]
            guard let next = solve(p, coarse: l == levels.count - 1 ? nil : (levels[l + 1], field), passes: l == levels.count - 1 ? 4 : (l == 0 ? 4 : 8)) else { return nil }
            field = next
            if l > 0 { upsample(p, into: levels[l - 1]) }
        }
        var out = px
        for i in 0..<(w * h) where full.hole[i] {
            for c in 0..<3 { out[i * 4 + c] = UInt8(min(max(full.rgb[i * 3 + c], 0), 1) * 255 + 0.5) }
        }
        return out.withUnsafeMutableBytes { raw -> CGImage? in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    /// 每个洞里的点离洞外多远。
    private static func distances(_ p: Plane) -> [Int] {
        var dist = [Int](repeating: 1 << 20, count: p.w * p.h)
        for y in 0..<p.h { for x in 0..<p.w {
            let i = y * p.w + x
            if !p.hole[i] { dist[i] = 0; continue }
            if x > 0 { dist[i] = min(dist[i], dist[i - 1] + 1) }
            if y > 0 { dist[i] = min(dist[i], dist[i - p.w] + 1) }
        } }
        for y in stride(from: p.h - 1, through: 0, by: -1) { for x in stride(from: p.w - 1, through: 0, by: -1) {
            let i = y * p.w + x
            if x + 1 < p.w { dist[i] = min(dist[i], dist[i + 1] + 1) }
            if y + 1 < p.h { dist[i] = min(dist[i], dist[i + p.w] + 1) }
        } }
        return dist
    }

    private static func thickness(_ p: Plane) -> Int { distances(p).filter { $0 < 1 << 19 }.max() ?? 0 }

    /// 从洞的边上往里补：每次挑已知最多、结构最强的小块，整块照着洞外最像的抄。
    private static func exemplar(_ p: Plane) {
        let w = p.w, h = p.h, r = min(4, (min(p.w, p.h) - 3) / 2)
        guard r >= 2 else { return seed(p) }
        var open = p.hole
        var conf = p.hole.map { $0 ? Float(0) : Float(1) }
        // 能抄的：整块都在原来的洞外。
        var sources: [Int] = []
        for y in r..<(h - r) { for x in r..<(w - r) {
            var ok = true
            check: for dy in -r...r { for dx in -r...r where p.hole[(y + dy) * w + x + dx] { ok = false; break check } }
            if ok { sources.append(y * w + x) }
        } }
        guard !sources.isEmpty else { return seed(p) }
        func luma(_ i: Int) -> Float { p.rgb[i * 3] * 0.3 + p.rgb[i * 3 + 1] * 0.59 + p.rgb[i * 3 + 2] * 0.11 }
        let diag = Float(w * w + h * h)
        var remaining = open.reduce(0) { $0 + ($1 ? 1 : 0) }
        var guardCount = 0
        while remaining > 0, guardCount < w * h {
            guardCount += 1
            // 洞的边：自己没补、旁边有补好的。
            var best = -1, bestScore: Float = -1
            for y in 0..<h { for x in 0..<w {
                let i = y * w + x
                guard open[i] else { continue }
                let edge = (x > 0 && !open[i - 1]) || (x + 1 < w && !open[i + 1]) || (y > 0 && !open[i - w]) || (y + 1 < h && !open[i + w])
                guard edge else { continue }
                var c: Float = 0, n: Float = 0, g: Float = 0
                for dy in -r...r { for dx in -r...r {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    n += 1
                    let j = ny * w + nx
                    c += conf[j]
                    if !open[j], nx + 1 < w, ny + 1 < h, !open[j + 1], !open[j + w] {
                        g = max(g, abs(luma(j + 1) - luma(j)) + abs(luma(j + w) - luma(j)))
                    }
                } }
                let score = c / n * (0.15 + min(g, 0.6))
                if score > bestScore { bestScore = score; best = i }
            } }
            guard best >= 0 else { break }
            let bx = best % w, by = best / w
            var pick = -1, pickCost = Float.infinity
            for s in sources {
                let sx = s % w, sy = s / w
                var d = (Float((sx - bx) * (sx - bx) + (sy - by) * (sy - by)) / diag) * 40
                for dy in -r...r { for dx in -r...r {
                    let nx = bx + dx, ny = by + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let j = ny * w + nx
                    if open[j] { continue }
                    let o = (sy + dy) * w + sx + dx
                    let a = p.rgb[j * 3] - p.rgb[o * 3], b = p.rgb[j * 3 + 1] - p.rgb[o * 3 + 1], c = p.rgb[j * 3 + 2] - p.rgb[o * 3 + 2]
                    d += a * a + b * b + c * c
                } ; if d >= pickCost { break } }
                if d < pickCost { pickCost = d; pick = s }
            }
            guard pick >= 0 else { break }
            let level = conf[best]
            for dy in -r...r { for dx in -r...r {
                let nx = bx + dx, ny = by + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let j = ny * w + nx
                guard open[j] else { continue }
                let o = (pick / w + dy) * w + pick % w + dx
                for k in 0..<3 { p.rgb[j * 3 + k] = p.rgb[o * 3 + k] }
                open[j] = false
                conf[j] = max(level, 0.6) * 0.8
                remaining -= 1
            } }
        }
        if remaining > 0 {
            let keep = p.hole
            p.hole = open
            seed(p)
            p.hole = keep
        }
    }

    private static func seed(_ p: Plane) {
        var known = p.hole.map { !$0 }
        var left = known.contains(false)
        while left {
            left = false
            var next = known
            var moved = false
            for y in 0..<p.h { for x in 0..<p.w {
                let i = y * p.w + x
                if known[i] { continue }
                var s = (Float(0), Float(0), Float(0)), n: Float = 0
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < p.w, ny < p.h else { continue }
                    let j = ny * p.w + nx
                    if known[j] { s.0 += p.rgb[j * 3]; s.1 += p.rgb[j * 3 + 1]; s.2 += p.rgb[j * 3 + 2]; n += 1 }
                } }
                if n > 0 {
                    p.rgb[i * 3] = s.0 / n; p.rgb[i * 3 + 1] = s.1 / n; p.rgb[i * 3 + 2] = s.2 / n
                    next[i] = true
                    moved = true
                } else {
                    left = true
                }
            } }
            known = next
            if !moved { break }
        }
    }

    /// 粗的一层补好的颜色放大到细的一层的洞里。
    private static func upsample(_ a: Plane, into b: Plane) {
        for y in 0..<b.h { for x in 0..<b.w {
            let i = y * b.w + x
            guard b.hole[i] else { continue }
            let j = min(y / 2, a.h - 1) * a.w + min(x / 2, a.w - 1)
            for c in 0..<3 { b.rgb[i * 3 + c] = a.rgb[j * 3 + c] }
        } }
    }

    /// 一层：找每个碰到洞的小块最像的外面小块，再投票填色，来回几次。返回每个点的最近邻（源的下标），-1 = 不用找。
    private static func solve(_ p: Plane, coarse: (Plane, [Int32])?, passes: Int) -> [Int32]? {
        let w = p.w, h = p.h, r = Self.r
        guard w > r * 2 + 2, h > r * 2 + 2 else { return [Int32](repeating: -1, count: w * h) }
        // 能当源的：整块都在洞外。能当目标的：碰到洞。
        var isSource = [Bool](repeating: false, count: w * h)
        var sources: [Int32] = [], targets: [Int32] = []
        // 积分图快速数洞。
        var sum = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h { for x in 0..<w {
            sum[(y + 1) * (w + 1) + x + 1] = (p.hole[y * w + x] ? 1 : 0) + sum[y * (w + 1) + x + 1] + sum[(y + 1) * (w + 1) + x] - sum[y * (w + 1) + x]
        } }
        for y in r..<(h - r) { for x in r..<(w - r) {
            let n = sum[(y + r + 1) * (w + 1) + x + r + 1] - sum[(y - r) * (w + 1) + x + r + 1] - sum[(y + r + 1) * (w + 1) + x - r] + sum[(y - r) * (w + 1) + x - r]
            let i = y * w + x
            if n == 0 {
                isSource[i] = true
                sources.append(Int32(i))
            } else {
                targets.append(Int32(i))
            }
        } }
        guard !sources.isEmpty, !targets.isEmpty else { return nil }
        // 信任度：洞外是 1，洞里越深越低。
        let conf: [Float] = distances(p).map { $0 == 0 ? 1 : pow(1.3, -Float(min($0, 60))) }
        // 优先用近处的纹理。
        let far = 0.5 / Float(w * w + h * h) * Float((2 * r + 1) * (2 * r + 1))
        var field = [Int32](repeating: -1, count: w * h)
        var cost = [Float](repeating: .infinity, count: w * h)
        var seedValue: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random(_ n: Int) -> Int {
            seedValue ^= seedValue << 13
            seedValue ^= seedValue >> 7
            seedValue ^= seedValue << 17
            return Int(seedValue % UInt64(max(n, 1)))
        }
        for t in targets {
            let i = Int(t)
            if let (c, f) = coarse {
                let x = i % w, y = i / w
                let j = min(y / 2, c.h - 1) * c.w + min(x / 2, c.w - 1)
                if f[j] >= 0 {
                    let sx = min(max(Int(f[j]) % c.w * 2 + (x & 1), r), w - r - 1), sy = min(max(Int(f[j]) / c.w * 2 + (y & 1), r), h - r - 1)
                    if isSource[sy * w + sx] { field[i] = Int32(sy * w + sx) }
                }
            }
            if field[i] < 0 { field[i] = sources[random(sources.count)] }
        }

        conf.withUnsafeBufferPointer { trust in
        p.rgb.withUnsafeMutableBufferPointer { rgb in
            func distance(_ a: Int, _ b: Int, _ limit: Float) -> Float {
                let dx = Float(a % w - b % w), dy0 = Float(a / w - b / w)
                // 优先用近处的。
                var d: Float = (dx * dx + dy0 * dy0) * far 
                for dy in -r...r {
                    var qa = a + dy * w - r
                    var ia = qa * 3, ib = (b + dy * w - r) * 3
                    for _ in 0..<(2 * r + 1) {
                        let x = rgb[ia] - rgb[ib], y = rgb[ia + 1] - rgb[ib + 1], z = rgb[ia + 2] - rgb[ib + 2]
                        d += (x * x + y * y + z * z) * (trust[qa] < 1 ? max(trust[qa], 0.5) * 0.15 : 1)
                        qa += 1
                        ia += 3
                        ib += 3
                    }
                    if d > limit { return d }
                }
                return d
            }
            for pass in 0..<passes {
                for t in targets { cost[Int(t)] = distance(Int(t), Int(field[Int(t)]), .infinity) }
                for iteration in 0..<3 {
                    let forward = (pass + iteration) % 2 == 0
                    let step = forward ? 1 : -1
                    for k in 0..<targets.count {
                        let i = Int(targets[forward ? k : targets.count - 1 - k])
                        func attempt(_ s: Int) {
                            guard s >= 0, s < w * h, isSource[s] else { return }
                            let d = distance(i, s, cost[i])
                            if d < cost[i] {
                                cost[i] = d
                                field[i] = Int32(s)
                            }
                        }
                        // 传播：邻居的匹配挪一格。
                        let a = i - step, b = i - step * w
                        if a >= 0, a < w * h, field[a] >= 0 { attempt(Int(field[a]) + step) }
                        if b >= 0, b < w * h, field[b] >= 0 { attempt(Int(field[b]) + step * w) }
                        // 随机找。
                        var radius = max(w, h)
                        while radius >= 1 {
                            let f = Int(field[i])
                            let sx = f % w + random(radius * 2 + 1) - radius, sy = f / w + random(radius * 2 + 1) - radius
                            if sx >= r, sy >= r, sx < w - r, sy < h - r { attempt(sy * w + sx) }
                            radius /= 2
                        }
                    }
                }
                // 投票：越像的小块说话越算数。
                var acc = [Float](repeating: 0, count: w * h * 3), weight = [Float](repeating: 0, count: w * h)
                let sorted = targets.map { cost[Int($0)] }.sorted()
                let sigma: Float = max(sorted[sorted.count / 2], 1e-4) * 0.12
                let last = pass == passes - 1
                for t in targets {
                    let i = Int(t), s = Int(field[i])
                    let v = max(exp(-cost[i] / sigma), 1e-6) * trust[i]
                    for dy in -r...r { for dx in -r...r {
                        let q = i + dy * w + dx
                        guard p.hole[q] else { continue }
                        // 最后一遍只听离得近的，细节不会被平均糊掉。
                        let near: Float = exp(-Float(dx * dx + dy * dy) / (last ? 1.6 : 6))
                        let m = v * near
                        let o = (s + dy * w + dx) * 3
                        acc[q * 3] += rgb[o] * m
                        acc[q * 3 + 1] += rgb[o + 1] * m
                        acc[q * 3 + 2] += rgb[o + 2] * m
                        weight[q] += m
                    } }
                }
                for q in 0..<(w * h) where p.hole[q] && weight[q] > 0 {
                    rgb[q * 3] = acc[q * 3] / weight[q]
                    rgb[q * 3 + 1] = acc[q * 3 + 1] / weight[q]
                    rgb[q * 3 + 2] = acc[q * 3 + 2] / weight[q]
                }
            }
        }
        }
        return field
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    private static func bytes(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }

    private static func gray(_ image: CGImage, _ w: Int, _ h: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? px : nil
    }
}
