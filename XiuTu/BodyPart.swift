import CoreGraphics
import CoreImage

/// AI 美体只该动的那一块。别处（比如丰胸时的肚子）就算 AI 改了也不采用。
enum BodyPart: String {
    case chest, waist, hip, neck, legs

    /// 这一块在图里的大致范围（白 = 允许），和照片同比例的小图。认不出人体也认不出脸时返回 nil（不限制）。
    func area(in image: CGImage) -> CGImage? {
        let long = CGFloat(max(image.width, image.height))
        // 都按长边 = 1、左上原点。
        var shoulder: CGPoint?, width: CGFloat = 0, down = CGVector(dx: 0, dy: 1)
        if let body = ShapeBodyDetector.detect(in: image).first, let l = body.left.shoulder, let r = body.right.shoulder {
            shoulder = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            width = hypot(l.x - r.x, l.y - r.y)
            if let a = body.left.hip, let b = body.right.hip, let s = shoulder {
                let d = CGVector(dx: (a.x + b.x) / 2 - s.x, dy: (a.y + b.y) / 2 - s.y)
                let len = hypot(d.dx, d.dy)
                if len > 0.01 {
                    down = CGVector(dx: d.dx / len, dy: d.dy / len)
                    // 侧身时肩膀看起来很窄，用躯干长度兜底。
                    width = max(width, len * 0.6)
                }
            }
        } else if let face = FaceDetector.detect(in: image).max(by: { $0.box.width < $1.box.width }) {
            let w = face.box.width * CGFloat(image.width) / long, h = face.box.height * CGFloat(image.height) / long
            let c = CGPoint(x: face.box.midX * CGFloat(image.width) / long, y: face.box.midY * CGFloat(image.height) / long)
            width = max(w, h) * 2.3
            shoulder = CGPoint(x: c.x, y: c.y + max(w, h) * 1.35)
        }
        guard let s = shoulder, width > 0.01 else { return nil }
        let center: CGFloat, halfW: CGFloat, halfH: CGFloat
        switch self {
        case .neck: (center, halfW, halfH) = (-0.1, 1.05, 0.65)
        case .chest: (center, halfW, halfH) = (0.4, 0.8, 0.36)
        case .waist: (center, halfW, halfH) = (1.1, 0.9, 0.62)
        case .hip: (center, halfW, halfH) = (1.65, 1.1, 0.8)
        case .legs: (center, halfW, halfH) = (3.2, 1.6, 1.75)
        }
        let k = 640 / long
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        // 左上原点 → 位图（左下原点）。
        let cx = (s.x + down.dx * center * width) * 640, cy = CGFloat(h) - (s.y + down.dy * center * width) * 640
        ctx.translateBy(x: cx, y: cy)
        ctx.rotate(by: atan2(down.dx, down.dy))
        let box = CGRect(x: -halfW * width * 640, y: -halfH * width * 640, width: halfW * width * 1280, height: halfH * width * 1280)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: min(box.width, box.height) * 0.35,
                           cornerHeight: min(box.width, box.height) * 0.35, transform: nil))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        let m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        let soft = m.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(width * 640 * 0.06, 2)])
            .cropped(to: m.extent)
        return Renderer.shared.context.createCGImage(soft, from: m.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }
}

extension ShapeItem {
    /// AI 版只该动的那一块；手臂、全身、体态这些范围散的不限制（仍然只在人身上）。
    var part: BodyPart? {
        switch self {
        case .aiChest, .aiChestNatural, .aiChestLift: return .chest
        case .aiWaist, .aiBelly, .aiTummy: return .waist
        case .aiHips, .aiWaistHip, .aiFullHip, .aiLiftHip: return .hip
        case .aiSwanNeck, .aiSquareShoulder, .aiThinNeck, .aiLongNeck, .aiTrapezius, .aiWideShoulder, .aiNarrowShoulder: return .neck
        case .aiLeg, .aiThigh, .aiCalf, .aiStraightLeg: return .legs
        default: return nil
        }
    }
}
