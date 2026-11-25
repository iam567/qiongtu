import CoreImage
import UIKit
import Vision

/// 用系统自带的人像分割找出画面里的人，全部在本机完成。返回灰度图：白 = 人，黑 = 背景。
enum PersonSegmenter {
    static func mask(for image: CGImage) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        #if targetEnvironment(simulator)
        request.usesCPUOnly = true
        #endif
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = Renderer.shared.context.createCGImage(ci, from: ci.extent, format: .L8,
                                                             colorSpace: CGColorSpaceCreateDeviceGray()) else { return nil }
        // 几乎没有白色就当作没找到人。
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h)
        let found: Int = pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return raw.reduce(0) { $0 + ($1 > 128 ? 1 : 0) }
        }
        return found * 200 > w * h ? cg : nil
    }

    /// 只留最大的一块和跟它差不多大的：建筑、花纹上零星误认成人的不要。
    static func main(_ mask: CGImage?) -> CGImage? {
        guard let mask else { return nil }
        let w = 192, h = 192
        var px = [UInt8](repeating: 0, count: w * h)
        let ok = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(mask, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return mask }
        var label = [Int](repeating: 0, count: w * h), sizes = [0]
        for start in 0..<(w * h) where px[start] > 70 && label[start] == 0 {
            let id = sizes.count
            sizes.append(0)
            var stack = [start]
            label[start] = id
            while let i = stack.popLast() {
                sizes[id] += 1
                let x = i % w, y = i / w
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                    let n = ny * w + nx
                    if px[n] > 70, label[n] == 0 { label[n] = id; stack.append(n) }
                }
            }
        }
        guard let biggest = sizes.max(), biggest > 0 else { return mask }
        // 往外扩两格，别把边缘的半透明切掉。
        var keep = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w {
            let l = label[y * w + x]
            guard l > 0, sizes[l] * 4 >= biggest else { continue }
            for dy in -2...2 { for dx in -2...2 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, ny >= 0, nx < w, ny < h { keep[ny * w + nx] = 255 }
            } }
        } }
        guard let provider = CGDataProvider(data: Data(keep) as CFData),
              let gate = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                 decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return mask }
        return ChangeKeep.intersect(mask, gate) ?? mask
    }
}

/// 手动美体（液化）里手指划过的一小段。坐标是归一化的图片坐标，半径以图片长边为 1。
struct LiquifySegment: Equatable {
    var from: CGPoint
    var to: CGPoint
    var radius: CGFloat
    var strength: CGFloat
    /// true = 恢复笔刷：把这一片推过的变形抹回去。
    var restore: Bool
    /// 属于第几笔，撤销时按笔撤。
    var stroke: Int
}

/// 位移场的一份快照，可以安全地交给后台线程渲染。
struct LiquifyField {
    let width: Int
    let height: Int
    let data: Data
}

/// 位移场：一张低分辨率的网格，每格记录"这里的画面要从哪边取"。
/// 位移以图片长边为单位，所以同一组笔画在预览图和原图上效果一致。
final class LiquifyGrid {
    static let longSide = 320

    let width: Int
    let height: Int
    private var values: [Float]

    init(imageSize: CGSize) {
        let m = max(imageSize.width, imageSize.height, 1)
        width = max(2, Int((imageSize.width / m * CGFloat(Self.longSide)).rounded()))
        height = max(2, Int((imageSize.height / m * CGFloat(Self.longSide)).rounded()))
        values = [Float](repeating: 0.5, count: width * height * 4)
        reset()
    }

    func reset() {
        for i in stride(from: 0, to: values.count, by: 4) {
            values[i] = 0.5
            values[i + 1] = 0.5
            values[i + 2] = 0
            values[i + 3] = 1
        }
    }

    func add(_ s: LiquifySegment) {
        let m = Float(max(width, height))
        let ax = Float(width) / m, ay = Float(height) / m
        let r = max(Float(s.radius), 2 / m)
        let k = Float(s.strength)
        if s.restore {
            stamp(cx: Float(s.to.x) * ax, cy: Float(s.to.y) * ay, vx: 0, vy: 0, r: r, k: k, restore: true)
            return
        }
        // 一次挪得太远会把画面折叠出硬边，所以拆成几小步，每步不超过笔刷半径的四分之一。
        let fx = Float(s.from.x) * ax, fy = Float(s.from.y) * ay
        let tx = Float(s.to.x) * ax, ty = Float(s.to.y) * ay
        let length = hypotf(tx - fx, ty - fy) * k
        let steps = max(1, min(24, Int((length / (r * 0.25)).rounded(.up))))
        let vx = (tx - fx) / Float(steps), vy = (ty - fy) / Float(steps)
        for i in 1...steps {
            stamp(cx: fx + vx * Float(i), cy: fy + vy * Float(i), vx: vx, vy: vy, r: r, k: k, restore: false)
        }
    }

    /// 在 (cx, cy) 处盖一个笔刷印。坐标和位移都以长边为单位，y 朝下。
    private func stamp(cx: Float, cy: Float, vx: Float, vy: Float, r: Float, k: Float, restore: Bool) {
        let m = Float(max(width, height))
        let i0 = max(0, Int((cx - r) * m)), i1 = min(width - 1, Int((cx + r) * m) + 1)
        let j0 = max(0, Int((cy - r) * m)), j1 = min(height - 1, Int((cy + r) * m) + 1)
        guard i0 <= i1, j0 <= j1 else { return }
        let old = restore ? [] : values
        // 从旧的位移场里取样（双线性），返回 (R-0.5, G-0.5)。
        func sample(_ x: Float, _ y: Float) -> (Float, Float) {
            let px = min(max(x, 0), Float(width - 1)), py = min(max(y, 0), Float(height - 1))
            let x0 = Int(px), y0 = Int(py)
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = px - Float(x0), fy = py - Float(y0)
            func at(_ i: Int, _ j: Int) -> (Float, Float) {
                let p = (j * width + i) * 4
                return (old[p] - 0.5, old[p + 1] - 0.5)
            }
            let a = at(x0, y0), b = at(x1, y0), c = at(x0, y1), d = at(x1, y1)
            let top = (a.0 + (b.0 - a.0) * fx, a.1 + (b.1 - a.1) * fx)
            let bottom = (c.0 + (d.0 - c.0) * fx, c.1 + (d.1 - c.1) * fx)
            return (top.0 + (bottom.0 - top.0) * fy, top.1 + (bottom.1 - top.1) * fy)
        }
        for j in j0...j1 {
            let dy = (Float(j) + 0.5) / m - cy
            for i in i0...i1 {
                let dx = (Float(i) + 0.5) / m - cx
                let d2 = (dx * dx + dy * dy) / (r * r)
                guard d2 < 1 else { continue }
                // 中间平、边缘缓的钟形衰减，推出来的轮廓是一条顺的弧线。
                let w = (1 - d2) * (1 - d2) * (1 - d2) * k
                let p = (j * width + i) * 4
                if restore {
                    values[p] = 0.5 + (values[p] - 0.5) * (1 - w)
                    values[p + 1] = 0.5 + (values[p + 1] - 0.5) * (1 - w)
                } else {
                    // 这一格的内容来自手指来的方向；之前推过的变形也跟着一起带过来，叠加多次也不会起皱。
                    // Core Image 的 y 轴朝上，所以 G 通道存的是取反后的 y。
                    let o = sample(Float(i) - vx * w * m, Float(j) - vy * w * m)
                    values[p] = 0.5 + o.0 - vx * w
                    values[p + 1] = 0.5 + o.1 + vy * w
                }
            }
        }
    }

    func replay(_ segments: [LiquifySegment]) {
        reset()
        for s in segments { add(s) }
    }

    func snapshot() -> LiquifyField {
        LiquifyField(width: width, height: height,
                     data: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// 按位移图取样的内核。系统自带的位移滤镜不按这种方式工作，所以自己写。
    /// 位移图 R、G 通道以 0.5 为零点，单位是图片长边。
    private static let kernel = CIKernel(source: """
    kernel vec4 liquify(sampler image, sampler map, float scale) {
        vec2 d = destCoord();
        vec4 m = sample(map, samplerTransform(map, d));
        vec2 p = d + (m.rg - vec2(0.5)) * scale;
        return sample(image, samplerTransform(image, p));
    }
    """)

    private static func personImage(_ lock: CGImage, extent: CGRect) -> CIImage {
        CIImage(cgImage: lock, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(lock.width),
                                               y: extent.height / CGFloat(lock.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }

    /// "没有人的背景"：把人所在的位置用周围的背景颜色由外向里填上。
    /// 人被推走后露出来的地方就显示这张图，而不是被拉花的画面。
    static func backgroundPlate(_ image: CIImage, lock: CGImage) -> CIImage {
        let extent = image.extent
        let long = max(extent.width, extent.height)
        // 人像蒙版往外扩一点，避免人边缘的颜色混进背景。
        let grown = personImage(lock, extent: extent).clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: long * 0.006])
            .cropped(to: extent)
        let background = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: extent),
            kCIInputMaskImageKey: grown.applyingFilter("CIColorInvert"),
        ]).cropped(to: extent)
        // 每一层：把周围的背景颜色向人的位置里晕开（只统计背景像素，不掺人的颜色）。
        // 半径小的层细节多但伸不远，半径大的层伸得远但更糊。离背景近的地方用细的，深处才用粗的。
        func level(_ radius: CGFloat) -> (color: CIImage, weight: CIImage) {
            let blurred = background.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: long * radius])
                .cropped(to: extent)
            let color = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ])
            // 这一层在这个位置有多可信：周围背景像素占比越高越可信。
            let weight = blurred.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 5),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            ]).applyingFilter("CIColorClamp")
            return (color, weight)
        }
        var plate = level(0.2).color
        for radius in [0.07, 0.025, 0.008] as [CGFloat] {
            let l = level(radius)
            plate = l.color.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: plate,
                kCIInputMaskImageKey: l.weight,
            ])
        }
        return background.composited(over: plate).cropped(to: extent)
    }

    /// lock 不为空时"固定背景"：人单独变形，背景保持原图；人让出来的地方用补好的背景填。
    /// plate 是提前算好的背景图（实时预览用），不传就现算。
    static func warp(_ image: CIImage, field: LiquifyField, lock: CGImage? = nil, plate: CGImage? = nil) -> CIImage {
        let extent = image.extent
        guard let provider = CGDataProvider(data: field.data as CFData),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let cg = CGImage(width: field.width, height: field.height, bitsPerComponent: 32, bitsPerPixel: 128,
                               bytesPerRow: field.width * 16, space: space,
                               bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
                                                        | CGBitmapInfo.byteOrder32Little.rawValue
                                                        | CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            return image
        }
        let scale = max(extent.width, extent.height)
        // 网格比图片粗得多，放大后再抹平一格左右，否则直线边缘会被推成一段一段的折线。
        let cell = scale / CGFloat(max(field.width, field.height))
        let map = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(field.width),
                                               y: extent.height / CGFloat(field.height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: cell * 0.8])
        func displaced(_ source: CIImage) -> CIImage {
            guard let kernel = Self.kernel,
                  let out = kernel.apply(extent: extent, roiCallback: { index, rect in
                      // 取样点最多偏离这么远；位移图本身只需要对应位置。
                      index == 0 ? rect.insetBy(dx: -scale * 0.3, dy: -scale * 0.3) : rect
                  }, arguments: [source.clampedToExtent(), map, scale]) else { return source }
            return out.cropped(to: extent)
        }
        let warped = displaced(image)
        guard let lock else { return warped }

        let person = personImage(lock, extent: extent)
        let moved = displaced(person)
        let background: CIImage
        if let plate {
            background = CIImage(cgImage: plate)
                .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(plate.width),
                                                   y: extent.height / CGFloat(plate.height)))
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .cropped(to: extent)
        } else {
            background = backgroundPlate(image, lock: lock)
        }
        // 只有人的轮廓真的动过的地方才换成补好的背景，其余地方一个像素都不动。
        let changed = person
            .applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: moved])
            .clampedToExtent()
            .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: scale * 0.01])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: scale * 0.005])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 2.5, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 2.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 2.5, w: 0),
            ])
            .applyingFilter("CIColorClamp")
            .cropped(to: extent)
        let behind = background.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: changed,
        ]).cropped(to: extent)
        return warped.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: behind,
            kCIInputMaskImageKey: moved,
        ]).cropped(to: extent)
    }
}

struct LiquifyParams: Equatable {
    var segments: [LiquifySegment] = []
    /// 固定背景用的人像蒙版；nil = 不固定。
    var lockMask: CGImage? = nil

    static func == (a: LiquifyParams, b: LiquifyParams) -> Bool {
        a.segments == b.segments && a.lockMask === b.lockMask
    }

    var isIdentity: Bool { !segments.contains { !$0.restore } }

    func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        let grid = LiquifyGrid(imageSize: image.extent.size)
        grid.replay(segments)
        return LiquifyGrid.warp(image, field: grid.snapshot(), lock: lockMask)
    }
}
