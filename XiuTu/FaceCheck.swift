import CoreGraphics
import Foundation

/// AI 修完的脸和原来的对不对得上：画成了别人、换了姿势的不采用。
enum FaceCheck {
    /// 两张图是同一块（发出去的和拿回来的）。
    static func matches(original: CGImage, result: CGImage) -> Bool {
        // 先比模糊以后的明暗分布：很像就是它，完全不像就不是；中间的再看五官位置。
        let like = similarity(original, result)
        if like > 0.85 { return true }
        if like < 0.6 { return false }
        let a = FaceDetector.direct(in: original).filter { $0.hasReliableLandmarks }
        let b = FaceDetector.direct(in: result).filter { $0.hasReliableLandmarks }
        guard let x = a.first, let y = b.first else { return like > 0.75 }
        // 五官位置对得上：脸的中心差不到三成脸宽，大小差不到三成，五官相对位置差不到一成。
        let w = x.box.width
        let moved = hypot(x.box.midX - y.box.midX, x.box.midY - y.box.midY)
        let scale = y.box.width / max(w, 0.001)
        return moved < w * 0.3 && scale > 0.7 && scale < 1.4 && layout(x, y) < 0.1
    }

    /// 五官相对脸框的位置差（占脸宽）。
    private static func layout(_ a: FaceInfo, _ b: FaceInfo) -> CGFloat {
        func c(_ p: [CGPoint], _ f: FaceInfo) -> CGPoint {
            let n = CGFloat(max(p.count, 1))
            let x = p.map(\.x).reduce(0, +) / n, y = p.map(\.y).reduce(0, +) / n
            return CGPoint(x: (x - f.box.minX) / f.box.width, y: (y - f.box.minY) / f.box.height)
        }
        var worst: CGFloat = 0
        for (p, q) in [(a.leftEye, b.leftEye), (a.rightEye, b.rightEye), (a.nose, b.nose), (a.outerLips, b.outerLips)] where !p.isEmpty && !q.isEmpty {
            let u = c(p, a), v = c(q, b)
            worst = max(worst, hypot(u.x - v.x, u.y - v.y))
        }
        return worst
    }

    /// 中间那一块模糊成 24×24 灰度以后的相关系数（1 = 一样）。
    static func similarity(_ a: CGImage, _ b: CGImage) -> Double {
        func gray(_ image: CGImage) -> [Double]? {
            let n = 24
            var px = [UInt8](repeating: 0, count: n * n)
            let ok = px.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
                return true
            }
            guard ok else { return nil }
            // 只看中间六成：四周是头发和背景，不算。
            var out: [Double] = []
            for y in 4..<20 { for x in 4..<20 { out.append(Double(px[y * n + x])) } }
            return out
        }
        guard let x = gray(a), let y = gray(b) else { return 1 }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in x.indices {
            sxy += (x[i] - mx) * (y[i] - my)
            sxx += (x[i] - mx) * (x[i] - mx)
            syy += (y[i] - my) * (y[i] - my)
        }
        return sxx > 1 && syy > 1 ? sxy / (sxx * syy).squareRoot() : 1
    }

    /// 脸小、糊、认不出五官时，先让能看图的 AI 说清楚原来的样子，写进指令里。
    static let describePrompt = """
    这是从照片里裁出来的一张人像小图，可能有点糊。请看清楚主角的脸：
    1. 脸的框（贴着脸，上到发际线，下到下巴），坐标用千分比：左上角 (0,0)，右下角 (1000,1000)，依次是 左、上、右、下。
    2. 用英文一句话（不超过 60 个词）客观描述，只写看得见的：头往哪边歪、脸朝哪边、眼睛睁着还是闭着或眯着、看哪里、嘴和表情、刘海和发型、发饰耳饰项链、脸型。不要猜身份。
    只输出 JSON，不要别的字：{"faces":[{"box":[左,上,右,下]}],"desc":"..."}
    """
}
