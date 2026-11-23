import Accelerate
import CoreGraphics
import CoreText
import Foundation

/// 文字 / 贴纸的实际绘制。只用 Core Graphics、Core Text 和 vImage，不依赖 UIKit，可以放心在后台线程跑。
/// 坐标系是 Core Graphics 原生的：原点左下角，y 向上。
enum OverlayDrawing {
    /// 排好版、还没画的一项。
    struct Layout {
        fileprivate let item: OverlayItem
        fileprivate let fontSize: CGFloat
        /// 位图大小（像素）。
        let size: CGSize
        /// 文字排版框 / 图片所在的位置。
        fileprivate let content: CGRect
        fileprivate let font: CTFont?
        fileprivate let fakeBold: Bool
        fileprivate let boxPath: CGPath?
        fileprivate let boxEvenOdd: Bool
        /// 文字实际占的大小（不算描边、阴影留的边）。
        var contentSize: CGSize { content.size }
    }

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // MARK: 各种效果的实际大小（都按字号折算）

    private static func strokeLine(_ item: OverlayItem, _ fs: CGFloat) -> CGFloat {
        item.strokeOn ? fs * 0.3 * min(max(item.strokeWidth, 0), 1) : 0
    }

    private static func shadowOffset(_ item: OverlayItem, _ fs: CGFloat, unit: CGFloat = 0.5) -> CGSize {
        let d = fs * unit * min(max(item.shadowDistance, 0), 1)
        let a = item.shadowAngle * .pi / 180
        // 屏幕上 90° 是向下；这里 y 向上，所以取反。
        return CGSize(width: d * cos(a), height: -d * sin(a))
    }

    private static func shadowBlur(_ item: OverlayItem, _ fs: CGFloat, unit: CGFloat = 0.35) -> CGFloat {
        fs * unit * min(max(item.shadowBlur, 0), 1)
    }

    private static func glowBlur(_ item: OverlayItem, _ fs: CGFloat) -> CGFloat {
        fs * (0.08 + 0.42 * min(max(item.glowSize, 0), 1))
    }

    // MARK: 排版

    /// 竖排时排版框的设置：一列一列从右往左排。
    private static func frameAttributes(_ item: OverlayItem) -> CFDictionary? {
        guard item.vertical, !item.isSticker else { return nil }
        return [kCTFrameProgressionAttributeName: NSNumber(value: CTFrameProgression.rightToLeft.rawValue)] as CFDictionary
    }

    static func layout(_ item: OverlayItem, fontSize fs: CGFloat) -> Layout? {
        guard fs >= 1 else { return nil }
        if let image = item.image { return imageLayout(item, image: image.cg, width: fs) }
        if let graphic = item.graphic { return graphicLayout(item, graphic, width: fs) }
        guard !item.text.isEmpty else { return nil }

        var fakeBold = false
        let font: CTFont
        if item.isSticker {
            font = OverlayFonts.ctFont(id: OverlayItem.defaultFontID, size: fs)
        } else {
            font = styled(OverlayFonts.ctFont(id: item.fontID, size: fs), item: item, size: fs, fakeBold: &fakeBold)
        }
        let probe = attributed(item, font: font, fontSize: fs, color: OverlayColor.white.cgColor(), stroke: 0)
        let setter = CTFramesetterCreateWithAttributedString(probe)
        var limit = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // 拉过文字框的边：这个方向上框就是这么长，字排满了自动换行（竖排换列），对齐按这个框来。
        let wrap = !item.isSticker && item.wrap > 0 ? max(item.wrap, 1.05) * fs : 0
        if wrap > 0 {
            if item.vertical { limit.height = wrap } else { limit.width = wrap }
        }
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0),
                                                               frameAttributes(item), limit, nil)
        var text = CGRect(x: 0, y: 0, width: ceil(fit.width) + 2, height: ceil(fit.height) + 2)
        if wrap > 0 {
            if item.vertical { text.size.height = max(text.height, ceil(wrap)) } else { text.size.width = max(text.width, ceil(wrap)) }
        }

        var box: CGPath?
        var evenOdd = false
        var anchor = text
        // 字形可能比排版框大一圈（斜体、花体的笔画），四周至少留这么多。
        var margin = fs * (item.isSticker ? 0.06 : 0.25)
        if !item.isSticker {
            let line = strokeLine(item, fs) / 2 + (fakeBold ? fs * 0.03 : 0)
            margin = max(margin, line + fs * 0.06)
            if item.glowOn { margin = max(margin, glowBlur(item, fs) * 1.7 + line) }
            if item.shadowOn {
                let o = shadowOffset(item, fs)
                margin = max(margin, max(abs(o.width), abs(o.height)) + shadowBlur(item, fs) * 1.7 + line)
            }
            if item.boxOn {
                // 竖排时底色按整块文字画（按行的荧光笔效果只对横排）。
                let lines = item.vertical ? [text] : lineRects(setter: setter, in: text)
                let shape = boxShape(item, text: text, lines: lines, fs: fs)
                box = shape.path
                evenOdd = shape.evenOdd
                anchor = shape.path.boundingBoxOfPath
            }
        }
        var union = text.insetBy(dx: -margin, dy: -margin)
        if box != nil { union = union.union(anchor.insetBy(dx: -1, dy: -1)) }
        // 以"底色形状（没有就是文字）"的中心为中心，上下左右对称地留边：
        // 这样调阴影方向、发光大小时，字在画面上的位置不会跟着跳。
        let c = CGPoint(x: anchor.midX, y: anchor.midY)
        let halfW = ceil(max(c.x - union.minX, union.maxX - c.x))
        let halfH = ceil(max(c.y - union.minY, union.maxY - c.y))
        let shift = CGAffineTransform(translationX: halfW - c.x, y: halfH - c.y)
        var t = shift
        return Layout(item: item, fontSize: fs, size: CGSize(width: halfW * 2, height: halfH * 2),
                      content: text.applying(shift), font: font, fakeBold: fakeBold,
                      boxPath: box?.copy(using: &t), boxEvenOdd: evenOdd)
    }

    private static func imageLayout(_ item: OverlayItem, image: CGImage, width: CGFloat) -> Layout? {
        guard image.width > 0, image.height > 0 else { return nil }
        let w = max(1, width.rounded())
        let h = max(1, (w * CGFloat(image.height) / CGFloat(image.width)).rounded())
        var margin: CGFloat = 1
        let line = item.strokeOn ? imageOutline(item, w) : 0
        margin += line * 1.3
        if item.shadowOn {
            let o = shadowOffset(item, w, unit: 0.12)
            margin = max(margin, max(abs(o.width), abs(o.height)) + shadowBlur(item, w, unit: 0.08) * 1.7 + line * 1.3 + 1)
        }
        margin = ceil(margin)
        return Layout(item: item, fontSize: w, size: CGSize(width: w + margin * 2, height: h + margin * 2),
                      content: CGRect(x: margin, y: margin, width: w, height: h), font: nil, fakeBold: false,
                      boxPath: nil, boxEvenOdd: false)
    }

    /// 图片贴纸的白边宽度（像素）。
    private static func imageOutline(_ item: OverlayItem, _ width: CGFloat) -> CGFloat {
        width * 0.06 * min(max(item.strokeWidth, 0.05), 1)
    }

    /// 加粗、斜体。字体本身没有对应的字重时，加粗用描一圈同色的边来模拟，斜体用倾斜来模拟。
    private static func styled(_ base: CTFont, item: OverlayItem, size: CGFloat, fakeBold: inout Bool) -> CTFont {
        var font = base
        if item.bold {
            if let b = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold),
               CTFontGetSymbolicTraits(b).contains(.traitBold), !CTFontGetSymbolicTraits(base).contains(.traitBold) {
                font = b
            } else {
                fakeBold = true
            }
        }
        if item.italic {
            if let i = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitItalic, .traitItalic),
               CTFontGetSymbolicTraits(i).contains(.traitItalic) {
                font = i
            } else {
                var skew = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)
                font = CTFontCreateCopyWithAttributes(font, size, &skew, nil)
            }
        }
        return font
    }

    /// stroke > 0：只画这么粗的描边（像素）；stroke < 0：填充并且加一圈同色的边（模拟加粗）；0：只填充。
    private static func attributed(_ item: OverlayItem, font: CTFont, fontSize fs: CGFloat,
                                   color: CGColor, stroke: CGFloat) -> CFAttributedString {
        var alignment: CTTextAlignment
        switch item.align {
        case .left: alignment = .left
        case .center: alignment = .center
        case .right: alignment = .right
        }
        if item.isSticker { alignment = .center }
        var spacing = item.isSticker ? 0 : fs * min(max(item.lineSpacing, -0.3), 2)
        // 竖排时 Core Text 按字体的横排行高算列宽，系统字体（中文靠后备字体）会算得很宽，行距也会被放大好几倍；
        // 所以竖排直接把每列宽度定死：字号 ×（1.25 + 行距）。
        let vertical = !item.isSticker && item.vertical
        var column = max(fs * 0.8, fs * 1.25 + spacing)
        if vertical { spacing = 0 }
        let paragraph: CTParagraphStyle = withUnsafePointer(to: &alignment) { a in
            withUnsafePointer(to: &spacing) { s in
                withUnsafePointer(to: &column) { h in
                    var settings = [
                        CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                        CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: s),
                    ]
                    if vertical {
                        settings.append(CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: h))
                        settings.append(CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: h))
                    }
                    return CTParagraphStyleCreate(settings, settings.count)
                }
            }
        }
        var attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
            kCTParagraphStyleAttributeName: paragraph,
        ]
        if !item.isSticker, item.letterSpacing != 0 {
            attrs[kCTKernAttributeName] = fs * min(max(item.letterSpacing, -0.2), 2) as NSNumber
        }
        if !item.isSticker, item.vertical {
            // 竖排：中文直立，标点换成竖排的写法，英文和数字横躺着跟着走。
            attrs[kCTVerticalFormsAttributeName] = kCFBooleanTrue
        }
        if stroke != 0 {
            // Core Text 的描边宽度是"字号的百分之几"。
            attrs[kCTStrokeWidthAttributeName] = stroke / fs * 100 as NSNumber
            attrs[kCTStrokeColorAttributeName] = color
        }
        return CFAttributedStringCreate(nil, item.text as CFString, attrs as CFDictionary)
    }

    /// 每一行文字占的位置（荧光笔底色按行画）。
    private static func lineRects(setter: CTFramesetter, in rect: CGRect) -> [CGRect] {
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        guard let lines = CTFrameGetLines(frame) as? [CTLine], !lines.isEmpty else { return [] }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var out: [CGRect] = []
        for (line, origin) in zip(lines, origins) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let trailing = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            guard width - trailing > 0.5 else { continue }
            out.append(CGRect(x: rect.minX + origin.x, y: rect.minY + origin.y - descent,
                              width: width - trailing, height: ascent + descent))
        }
        return out
    }

    // MARK: 底色形状

    private static func boxShape(_ item: OverlayItem, text t: CGRect, lines: [CGRect], fs: CGFloat) -> (path: CGPath, evenOdd: Bool) {
        let pad = fs * (0.06 + 0.5 * min(max(item.boxPadding, 0), 1))
        let px = pad, py = pad * 0.55
        let body = t.insetBy(dx: -px, dy: -py)
        let path = CGMutablePath()
        switch item.boxShape {
        case .rect:
            path.addRect(body)
        case .rounded:
            let r = min(fs * 0.28, body.height / 2, body.width / 2)
            path.addRoundedRect(in: body, cornerWidth: r, cornerHeight: r)
        case .capsule:
            let b = body.insetBy(dx: -body.height * 0.18, dy: 0)
            let r = min(b.height, b.width) / 2
            path.addRoundedRect(in: b, cornerWidth: r, cornerHeight: r)
        case .ellipse:
            let a = (t.width / 2 + px * 0.4) * 1.36
            let b = (t.height / 2 + py * 0.6) * 1.42
            path.addEllipse(in: CGRect(x: t.midX - a, y: t.midY - b, width: a * 2, height: b * 2))
        case .bubble:
            let r = min(fs * 0.34, body.height / 2, body.width / 2)
            path.addRoundedRect(in: body, cornerWidth: r, cornerHeight: r)
            // 左下角的小尾巴。
            let x0 = body.minX + min(r + fs * 0.1, body.width * 0.3)
            let w = min(fs * 0.5, body.width * 0.35)
            path.move(to: CGPoint(x: x0, y: body.minY + 1))
            path.addLine(to: CGPoint(x: x0 + w, y: body.minY + 1))
            path.addLine(to: CGPoint(x: x0 - fs * 0.08, y: body.minY - fs * 0.42))
            path.closeSubpath()
        case .slant:
            let s = body.height * 0.3
            let b = body.insetBy(dx: -s / 2, dy: 0)
            path.move(to: CGPoint(x: b.minX - s / 2, y: b.minY))
            path.addLine(to: CGPoint(x: b.maxX - s / 2, y: b.minY))
            path.addLine(to: CGPoint(x: b.maxX + s / 2, y: b.maxY))
            path.addLine(to: CGPoint(x: b.minX + s / 2, y: b.maxY))
            path.closeSubpath()
        case .tag:
            let d = body.height * 0.5
            let r = min(fs * 0.16, body.height / 2)
            path.move(to: CGPoint(x: body.minX - d, y: body.midY))
            path.addLine(to: CGPoint(x: body.minX, y: body.maxY))
            path.addLine(to: CGPoint(x: body.maxX - r, y: body.maxY))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY),
                        tangent2End: CGPoint(x: body.maxX, y: body.maxY - r), radius: r)
            path.addLine(to: CGPoint(x: body.maxX, y: body.minY + r))
            path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY),
                        tangent2End: CGPoint(x: body.maxX - r, y: body.minY), radius: r)
            path.addLine(to: CGPoint(x: body.minX, y: body.minY))
            path.closeSubpath()
            // 穿绳子的小孔。
            let hole = body.height * 0.09
            path.addEllipse(in: CGRect(x: body.minX - d * 0.38 - hole, y: body.midY - hole, width: hole * 2, height: hole * 2))
            return (path, true)
        case .ribbon:
            let d = body.height * 0.34
            let l = body.minX - d * 1.3, rr = body.maxX + d * 1.3
            path.move(to: CGPoint(x: l, y: body.maxY))
            path.addLine(to: CGPoint(x: rr, y: body.maxY))
            path.addLine(to: CGPoint(x: rr - d, y: body.midY))
            path.addLine(to: CGPoint(x: rr, y: body.minY))
            path.addLine(to: CGPoint(x: l, y: body.minY))
            path.addLine(to: CGPoint(x: l + d, y: body.midY))
            path.closeSubpath()
        case .marker:
            // 每一行下半截画一道，像荧光笔划过。
            let grow = min(max(item.boxPadding, 0), 1)
            let rects = lines.isEmpty ? [t] : lines
            for line in rects {
                let h = line.height * (0.34 + 0.3 * grow)
                let bar = CGRect(x: line.minX - fs * 0.14, y: line.minY + line.height * 0.06,
                                 width: line.width + fs * 0.28, height: h)
                let r = min(h * 0.28, bar.width / 2)
                path.addRoundedRect(in: bar, cornerWidth: r, cornerHeight: r)
            }
        }
        return (path, false)
    }

    // MARK: 画

    static func draw(_ layout: Layout) -> CGImage? {
        let w = Int(layout.size.width), h = Int(layout.size.height)
        guard w >= 1, h >= 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let item = layout.item
        let whole = CGRect(x: 0, y: 0, width: w, height: h)
        let opacity = min(max(item.opacity, 0), 1)
        if opacity < 1 {
            ctx.setAlpha(opacity)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        if let image = item.image {
            drawImage(image.cg, layout: layout, in: ctx, whole: whole)
        } else if item.graphic != nil {
            drawGraphic(layout, in: ctx, whole: whole)
        } else {
            drawText(layout, in: ctx, whole: whole)
        }
        if opacity < 1 { ctx.endTransparencyLayer() }
        return ctx.makeImage()
    }

    private static func drawText(_ layout: Layout, in ctx: CGContext, whole: CGRect) {
        guard let font = layout.font else { return }
        let item = layout.item
        let fs = layout.fontSize
        let w = Int(whole.width), h = Int(whole.height)
        let styled = !item.isSticker
        let line = styled ? strokeLine(item, fs) : 0
        let bold: CGFloat = layout.fakeBold ? fs * 0.045 : 0

        /// 把字画一遍：先描边（如果有），再填充。
        func glyphs(into c: CGContext, fill: CGColor, stroke: CGColor) {
            c.textMatrix = .identity
            c.setLineJoin(.round)
            c.setLineCap(.round)
            c.setShouldSmoothFonts(false)
            // Core Text 把字距加在每个字后面，最后一个字后面也有；居中、靠右时往右挪回来。
            var nudge: CGFloat = 0
            if styled, item.letterSpacing != 0, !item.vertical {
                let kern = fs * min(max(item.letterSpacing, -0.2), 2)
                nudge = item.align == .center ? kern / 2 : (item.align == .right ? kern : 0)
            }
            let path = CGPath(rect: layout.content.offsetBy(dx: nudge, dy: 0), transform: nil)
            func pass(_ color: CGColor, _ strokeWidth: CGFloat) {
                let string = attributed(item, font: font, fontSize: fs, color: color, stroke: strokeWidth)
                let setter = CTFramesetterCreateWithAttributedString(string)
                CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, frameAttributes(item)), c)
            }
            if line > 0 { pass(stroke, line + bold) }
            pass(fill, bold > 0 ? -bold : 0)
        }

        if styled, item.boxOn, let box = layout.boxPath {
            ctx.addPath(box)
            ctx.setFillColor(item.boxColor.cgColor(alpha: item.boxOpacity))
            ctx.fillPath(using: layout.boxEvenOdd ? .evenOdd : .winding)
        }

        if styled, item.shadowOn || item.glowOn {
            // 先得到"字（连描边）盖住了哪些地方"，阴影和发光都从它模糊出来。
            let white = OverlayColor.white.cgColor()
            let coverage = self.coverage(width: w, height: h) { mask in
                glyphs(into: mask, fill: white, stroke: white)
            }
            if item.shadowOn {
                let soft = softened(coverage, width: w, height: h, radius: shadowBlur(item, fs))
                let o = shadowOffset(item, fs)
                fill(mask: soft, in: ctx, rect: whole.offsetBy(dx: o.width, dy: o.height),
                     color: item.shadowColor.cgColor(alpha: item.shadowOpacity))
            }
            if item.glowOn {
                var soft = softened(coverage, width: w, height: h, radius: glowBlur(item, fs))
                let gain = 1.2 + 4.5 * min(max(item.glowStrength, 0), 1)
                remap(&soft.pixels, width: soft.w, height: soft.h) { Int(CGFloat($0) * gain) }
                fill(mask: soft, in: ctx, rect: whole, color: item.glowColor.cgColor())
            }
        }

        glyphs(into: ctx, fill: item.isSticker ? OverlayColor.white.cgColor() : item.color.cgColor(),
               stroke: item.strokeColor.cgColor())
    }

    private static func drawImage(_ image: CGImage, layout: Layout, in ctx: CGContext, whole: CGRect) {
        let item = layout.item
        let w = Int(whole.width), h = Int(whole.height)
        let width = layout.fontSize
        if item.strokeOn || item.shadowOn {
            // 图片的不透明范围。
            var coverage = self.coverage(width: w, height: h) { mask in
                mask.interpolationQuality = .high
                mask.draw(image, in: layout.content)
            }
            if item.strokeOn {
                // 往外扩一圈：模糊之后取一个很低的阈值，边缘是圆润的。
                // 模糊可以在缩小的图上做，但取阈值要回到原大小再做，边缘才是清楚的。
                let line = imageOutline(item, width)
                let soft = softened(coverage, width: w, height: h, radius: line * 1.2)
                coverage = resized(soft, width: w, height: h)
                remap(&coverage, width: w, height: h) { ($0 - 12) * 18 }
            }
            if item.shadowOn {
                let soft = softened(coverage, width: w, height: h, radius: shadowBlur(item, width, unit: 0.08))
                let o = shadowOffset(item, width, unit: 0.12)
                fill(mask: soft, in: ctx, rect: whole.offsetBy(dx: o.width, dy: o.height),
                     color: item.shadowColor.cgColor(alpha: item.shadowOpacity))
            }
            if item.strokeOn {
                fill(mask: Mask(pixels: coverage, w: w, h: h), in: ctx, rect: whole, color: item.strokeColor.cgColor())
            }
        }
        ctx.draw(image, in: layout.content)
    }

    /// 画一遍，取出"哪些地方被盖住了"（0...255），一行一行从上到下。
    private static func coverage(width w: Int, height h: Int, draw: (CGContext) -> Void) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            draw(ctx)
            // 取出透明通道（RGBA 里的第 4 个）。逐像素的事都交给 vImage，调试版里也不会慢。
            out.withUnsafeMutableBytes { alpha in
                var src = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: alpha.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageExtractChannel_ARGB8888(&src, &dst, 3, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    /// 把每个像素的值按 f 换算一遍（查表）。
    private static func remap(_ pixels: inout [UInt8], width: Int, height: Int, _ f: (Int) -> Int) {
        guard width > 0, height > 0 else { return }
        let table = (0..<256).map { UInt8(min(max(f($0), 0), 255)) }
        pixels.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            vImageTableLookUp_Planar8(&buffer, &buffer, table, vImage_Flags(kvImageNoFlags))
        }
    }

    // MARK: 小工具

    /// 一张 8 位的覆盖图（可以比画布小，用的时候会拉伸到画布大小）。
    private struct Mask {
        var pixels: [UInt8]
        let w: Int
        let h: Int
    }

    /// 把覆盖图当蒙版，用指定颜色填到 ctx 里。
    private static func fill(mask: Mask, in ctx: CGContext, rect: CGRect, color: CGColor) {
        guard let provider = CGDataProvider(data: Data(mask.pixels) as CFData),
              let image = CGImage(width: mask.w, height: mask.h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: mask.w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        ctx.saveGState()
        ctx.clip(to: rect, mask: image)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.restoreGState()
    }

    /// 模糊一张覆盖图。半径大的时候先缩小再模糊（模糊过的东西本来就没有细节），大图上也很快。
    private static func softened(_ pixels: [UInt8], width w: Int, height h: Int, radius: CGFloat) -> Mask {
        let factor = min(8, max(1, Int(radius / 6)))
        guard factor > 1 else {
            var copy = pixels
            blur(&copy, width: w, height: h, radius: radius)
            return Mask(pixels: copy, w: w, h: h)
        }
        let sw = max(1, w / factor), sh = max(1, h / factor)
        var small = resized(Mask(pixels: pixels, w: w, h: h), width: sw, height: sh)
        blur(&small, width: sw, height: sh, radius: radius * CGFloat(sw) / CGFloat(w))
        return Mask(pixels: small, w: sw, h: sh)
    }

    /// 把覆盖图缩放到指定大小。
    private static func resized(_ mask: Mask, width w: Int, height h: Int) -> [UInt8] {
        if mask.w == w, mask.h == h { return mask.pixels }
        var out = [UInt8](repeating: 0, count: w * h)
        var source = mask.pixels
        source.withUnsafeMutableBytes { a in
            out.withUnsafeMutableBytes { b in
                var src = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(mask.h), width: vImagePixelCount(mask.w), rowBytes: mask.w)
                var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        return out
    }

    /// 模糊一张 8 位的图。连做两次三角形卷积，效果接近高斯模糊，耗时和模糊半径无关。
    private static func blur(_ pixels: inout [UInt8], width: Int, height: Int, radius: CGFloat) {
        let k = UInt32(max(1, Int(radius.rounded()))) * 2 + 1
        guard k >= 3, width > 0, height > 0 else { return }
        var scratch = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeMutableBytes { a in
            scratch.withUnsafeMutableBytes { b in
                var src = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var dst = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                let flags = vImage_Flags(kvImageEdgeExtend)
                vImageTentConvolve_Planar8(&src, &dst, nil, 0, 0, k, k, 0, flags)
                vImageTentConvolve_Planar8(&dst, &src, nil, 0, 0, k, k, 0, flags)
            }
        }
    }
}

// MARK: - 形状

extension OverlayDrawing {
    /// 形状的描边粗细（像素）：按短边算。
    private static func graphicLine(_ item: OverlayItem, _ short: CGFloat) -> CGFloat {
        item.strokeOn ? short * 0.12 * min(max(item.strokeWidth, 0.05), 1) : 0
    }

    fileprivate static func graphicLayout(_ item: OverlayItem, _ g: GraphicStyle, width: CGFloat) -> Layout? {
        let w = max(2, width.rounded())
        let h = max(2, (w * min(max(g.aspect, 0.05), 8)).rounded())
        let short = min(w, h)
        let line = graphicLine(item, short)
        var margin = line / 2 + 2
        if item.shadowOn {
            let o = shadowOffset(item, short, unit: 0.15)
            margin = max(margin, max(abs(o.width), abs(o.height)) + shadowBlur(item, short, unit: 0.12) * 1.7 + line / 2 + 2)
        }
        margin = ceil(margin)
        let rect = CGRect(x: margin, y: margin, width: w, height: h)
        return Layout(item: item, fontSize: w, size: CGSize(width: w + margin * 2, height: h + margin * 2),
                      content: rect, font: nil, fakeBold: false,
                      boxPath: graphicPath(g, in: rect), boxEvenOdd: false)
    }

    fileprivate static func drawGraphic(_ layout: Layout, in ctx: CGContext, whole: CGRect) {
        guard let path = layout.boxPath, let g = layout.item.graphic else { return }
        let item = layout.item
        let short = min(layout.content.width, layout.content.height)
        let line = graphicLine(item, short)
        let w = Int(whole.width), h = Int(whole.height)
        if item.shadowOn {
            let coverage = self.coverage(width: w, height: h) { mask in
                mask.addPath(path)
                mask.setFillColor(OverlayColor.white.cgColor())
                if g.fill { mask.fillPath() }
                if line > 0 {
                    mask.addPath(path)
                    mask.setStrokeColor(OverlayColor.white.cgColor())
                    mask.setLineWidth(line)
                    mask.setLineJoin(.round)
                    mask.strokePath()
                }
            }
            let soft = softened(coverage, width: w, height: h, radius: shadowBlur(item, short, unit: 0.12))
            let o = shadowOffset(item, short, unit: 0.15)
            fill(mask: soft, in: ctx, rect: whole.offsetBy(dx: o.width, dy: o.height),
                 color: item.shadowColor.cgColor(alpha: item.shadowOpacity))
        }
        if g.fill {
            ctx.addPath(path)
            ctx.setFillColor(item.color.cgColor())
            ctx.fillPath()
        }
        if line > 0 {
            ctx.addPath(path)
            ctx.setStrokeColor(item.strokeColor.cgColor())
            ctx.setLineWidth(line)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
    }

    /// 形状的轮廓。坐标是 Core Graphics 的（y 向上）。
    static func graphicPath(_ g: GraphicStyle, in r: CGRect) -> CGPath {
        let short = min(r.width, r.height)
        switch g.kind {
        case .rect:
            return cornerPolygon([CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
                                  CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.minY)],
                                 radius: g.corner * short / 2, cut: g.cut * short, cutMask: g.cutCorners)
        case .ellipse:
            return CGPath(ellipseIn: r, transform: nil)
        case .polygon:
            let n = min(max(g.sides, 3), 12)
            let pts = (0..<n).map { i -> CGPoint in
                let a = CGFloat.pi / 2 - CGFloat(i) * 2 * .pi / CGFloat(n)
                return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
            }
            return cornerPolygon(pts, radius: g.corner * short / 4, cut: 0, cutMask: 0)
        case .star:
            let n = min(max(g.sides, 4), 12)
            let pts = (0..<(n * 2)).map { i -> CGPoint in
                let k: CGFloat = i % 2 == 0 ? 1 : 0.45
                let a = CGFloat.pi / 2 - CGFloat(i) * .pi / CGFloat(n)
                return CGPoint(x: r.midX + cos(a) * r.width / 2 * k, y: r.midY + sin(a) * r.height / 2 * k)
            }
            return cornerPolygon(pts, radius: g.corner * short / 10, cut: 0, cutMask: 0)
        case .heart:
            let p = CGMutablePath()
            // 单位方框里的爱心（y 向上），再拉到 r。
            p.move(to: CGPoint(x: 0.5, y: 0.02))
            p.addCurve(to: CGPoint(x: 0.02, y: 0.62), control1: CGPoint(x: 0.25, y: 0.22), control2: CGPoint(x: 0.02, y: 0.4))
            p.addCurve(to: CGPoint(x: 0.5, y: 0.8), control1: CGPoint(x: 0.02, y: 0.98), control2: CGPoint(x: 0.4, y: 1.0))
            p.addCurve(to: CGPoint(x: 0.98, y: 0.62), control1: CGPoint(x: 0.6, y: 1.0), control2: CGPoint(x: 0.98, y: 0.98))
            p.addCurve(to: CGPoint(x: 0.5, y: 0.02), control1: CGPoint(x: 0.98, y: 0.4), control2: CGPoint(x: 0.75, y: 0.22))
            p.closeSubpath()
            var t = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width, y: r.height)
            return p.copy(using: &t) ?? p
        case .arrow:
            let head = min(r.width * 0.45, r.height)
            let shaft = r.height * 0.42
            let pts = [CGPoint(x: r.minX, y: r.midY + shaft / 2), CGPoint(x: r.maxX - head, y: r.midY + shaft / 2),
                       CGPoint(x: r.maxX - head, y: r.maxY), CGPoint(x: r.maxX, y: r.midY),
                       CGPoint(x: r.maxX - head, y: r.minY), CGPoint(x: r.maxX - head, y: r.midY - shaft / 2),
                       CGPoint(x: r.minX, y: r.midY - shaft / 2)]
            return cornerPolygon(pts, radius: g.corner * short / 8, cut: 0, cutMask: 0)
        case .bubble:
            // 圆角方框，左下角拖一个小尾巴。
            let tail = short * 0.22
            let body = CGRect(x: r.minX, y: r.minY + tail, width: r.width, height: r.height - tail)
            let rad = max(g.corner, 0.15) * min(body.width, body.height) / 2
            let p = CGMutablePath()
            p.addRoundedRect(in: body, cornerWidth: rad, cornerHeight: rad)
            p.move(to: CGPoint(x: body.minX + body.width * 0.18, y: body.minY + 1))
            p.addLine(to: CGPoint(x: body.minX + body.width * 0.1, y: r.minY))
            p.addLine(to: CGPoint(x: body.minX + body.width * 0.34, y: body.minY + 1))
            p.closeSubpath()
            return p
        }
    }

    /// 多边形：每个角可以圆角，也可以切掉（cutMask 里第 i 位 = 第 i 个角）。
    private static func cornerPolygon(_ pts: [CGPoint], radius: CGFloat, cut: CGFloat, cutMask: Int) -> CGPath {
        let n = pts.count
        let p = CGMutablePath()
        guard n >= 3 else { return p }
        func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let d = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
            return CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
        }
        func len(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(b.x - a.x, b.y - a.y) }
        // 从第 0 条边的中点出发，绕一圈。
        let start = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
        p.move(to: start)
        for k in 1...n {
            let i = k % n
            let prev = pts[(i - 1 + n) % n], cur = pts[i], next = pts[(i + 1) % n]
            let maxLen = min(len(prev, cur), len(cur, next)) / 2
            if cut > 0, cutMask & (1 << i) != 0 {
                let c = min(cut, maxLen)
                let a = unit(cur, prev), b = unit(cur, next)
                p.addLine(to: CGPoint(x: cur.x + a.x * c, y: cur.y + a.y * c))
                p.addLine(to: CGPoint(x: cur.x + b.x * c, y: cur.y + b.y * c))
            } else if radius > 0.5 {
                p.addArc(tangent1End: cur, tangent2End: next, radius: min(radius, maxLen))
            } else {
                p.addLine(to: cur)
            }
        }
        p.closeSubpath()
        return p
    }
}
