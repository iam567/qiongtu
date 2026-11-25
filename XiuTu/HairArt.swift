import CoreGraphics
import Foundation

/// 美发 → 发型 按钮上的小图：用代码画的半身像，每个发型一张，头发是主角。
/// 只用 Core Graphics；画出来是整张矩形图，圆角由用它的地方裁。
enum HairArt {
    static func image(for title: String, size: CGSize = CGSize(width: 136, height: 168), scale: CGFloat = 2) -> CGImage? {
        guard let build = styles[title] ?? MalePresets.hairArtAlias[title].flatMap({ styles[$0] }) else { return nil }
        let pw = Int((size.width * scale).rounded()), ph = Int((size.height * scale).rounded())
        guard pw > 0, ph > 0,
              let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 换成设计稿的坐标：原点左上角，y 向下。
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: CGFloat(pw) / W, y: -CGFloat(ph) / H)
        var scene = Scene()
        build(&scene)
        draw(scene, in: ctx)
        return ctx.makeImage()
    }

    // MARK: 设计稿和配色

    /// 所有坐标都按 136 × 168 的设计稿写。
    private static let W: CGFloat = 136
    private static let H: CGFloat = 168
    private static let cx: CGFloat = 68

    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, a]) ?? CGColor(gray: 0, alpha: a)
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private enum Ink {
        static let hair: (CGFloat, CGFloat, CGFloat) = (0.23, 0.155, 0.125)
        static let light: (CGFloat, CGFloat, CGFloat) = (0.62, 0.44, 0.33)
        static let dark: (CGFloat, CGFloat, CGFloat) = (0.09, 0.06, 0.05)
        static let stubble: (CGFloat, CGFloat, CGFloat) = (0.36, 0.30, 0.27)
        static let skin: (CGFloat, CGFloat, CGFloat) = (0.975, 0.87, 0.79)
        static let skinShade: (CGFloat, CGFloat, CGFloat) = (0.90, 0.745, 0.655)
    }

    private static func ink(_ c: (CGFloat, CGFloat, CGFloat), _ a: CGFloat = 1) -> CGColor { rgb(c.0, c.1, c.2, a) }

    // MARK: 零件

    /// 一块头发：轮廓，加上画在它上面的亮发丝、暗发丝和大块的光泽。
    private struct Piece {
        var fill: CGPath
        var light: [CGPath] = []
        var dark: [CGPath] = []
        var shine: [(path: CGPath, width: CGFloat)] = []
    }

    private struct Scene {
        var male = false
        var ears = false
        /// 寸头：头发只是一层青皮，颜色浅。
        var pale = false
        /// 在身体后面的头发。
        var back: [Piece] = []
        /// 在脸和身体前面的头发。
        var front: [Piece] = []
        /// 发圈。
        var ties: [CGRect] = []
        /// 整个人往下挪多少（头顶上有丸子、马尾的要留出地方）。
        var shift: CGFloat = 0
    }

    /// 一条从上往下的边：x 随高度怎么变。
    private struct Edge {
        var top: CGFloat
        var bottom: CGFloat
        /// 中段往 x 正方向鼓多少。
        var bulge: CGFloat = 0
        /// 波浪：幅度、一个浪有多高、相位；grow = 1 时发根是直的，越往下越卷。
        var amp: CGFloat = 0
        var period: CGFloat = 26
        var phase: CGFloat = 0
        var grow: CGFloat = 1

        func x(_ t: CGFloat, _ y: CGFloat) -> CGFloat {
            let base = top + (bottom - top) * t + bulge * sin(.pi * t)
            let k = (1 - grow) + grow * min(1, t * 1.7)
            return base + amp * k * sin(2 * .pi * y / period + phase)
        }
    }

    private enum End { case flat, round, taper, curlRight, curlLeft }

    /// 两条边之间的一片头发（垂下来的发片、背后的一大片都用它）。
    private static func ribbon(left: Edge, right: Edge, top: CGFloat, bottom: CGFloat, end: End = .round, strands: Int = 2) -> Piece {
        let n = 44
        var l: [CGPoint] = [], r: [CGPoint] = []
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n), y = top + (bottom - top) * t
            l.append(pt(left.x(t, y), y))
            r.append(pt(right.x(t, y), y))
        }
        let path = CGMutablePath()
        path.move(to: l[0])
        for p in l.dropFirst() { path.addLine(to: p) }
        let a = l[n], b = r[n], w = b.x - a.x
        switch end {
        case .flat:
            path.addLine(to: b)
        case .round:
            let d = min(w * 0.4, 7)
            path.addCurve(to: b, control1: pt(a.x + w * 0.12, a.y + d), control2: pt(b.x - w * 0.12, b.y + d))
        case .taper:
            path.addQuadCurve(to: pt((a.x + b.x) / 2, a.y + min(w * 0.9, 12)), control: pt(a.x + w * 0.15, a.y + 6))
            path.addQuadCurve(to: b, control: pt(b.x - w * 0.15, b.y + 6))
        case .curlRight:
            path.addCurve(to: pt(b.x + 1, b.y + min(w * 0.5, 6)), control1: pt(a.x + 0.5, a.y + min(w * 0.6, 7)),
                          control2: pt(b.x - w * 0.45, b.y + min(w * 0.8, 9)))
            path.addLine(to: b)
        case .curlLeft:
            path.addLine(to: pt(a.x - 1, a.y + min(w * 0.5, 6)))
            path.addCurve(to: b, control1: pt(a.x + w * 0.45, a.y + min(w * 0.8, 9)), control2: pt(b.x - 0.5, b.y + min(w * 0.6, 7)))
        }
        for p in r.reversed().dropFirst() { path.addLine(to: p) }
        path.closeSubpath()

        var light: [CGPath] = []
        if strands > 0 {
            for s in 1...strands {
                let f = CGFloat(s) / CGFloat(strands + 1)
                let line = CGMutablePath()
                for i in 3..<(n - 1) {
                    let p = pt(l[i].x + (r[i].x - l[i].x) * f, l[i].y)
                    if i == 3 { line.move(to: p) } else { line.addLine(to: p) }
                }
                light.append(line)
            }
        }
        return Piece(fill: path, light: light)
    }

    /// 穿过几个点的平滑曲线，采样成折线。
    private static func spline(_ pts: [CGPoint], samples: Int = 10) -> [CGPoint] {
        guard pts.count >= 2 else { return pts }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples), t2 = t * t, t3 = t2 * t
                func f(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
                }
                out.append(pt(f(p0.x, p1.x, p2.x, p3.x), f(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    /// 沿着一条曲线走的一束头发（马尾、刘海、碎发），粗细可以一路变。
    private static func tube(_ pts: [CGPoint], strands: Int = 1, width: (CGFloat) -> CGFloat) -> Piece {
        let c = spline(pts), n = c.count - 1
        var l: [CGPoint] = [], r: [CGPoint] = []
        for i in 0...n {
            let a = c[max(i - 1, 0)], b = c[min(i + 1, n)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 0.001)
            dx /= len; dy /= len
            let w = max(width(CGFloat(i) / CGFloat(n)), 0.2) / 2
            l.append(pt(c[i].x - dy * w, c[i].y + dx * w))
            r.append(pt(c[i].x + dy * w, c[i].y - dx * w))
        }
        let path = CGMutablePath()
        path.move(to: l[0])
        for p in l.dropFirst() { path.addLine(to: p) }
        for p in r.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        var light: [CGPath] = []
        if strands > 0 {
            for s in 1...strands {
                let f = CGFloat(s) / CGFloat(strands + 1)
                let line = CGMutablePath()
                for i in 1..<n {
                    let p = pt(l[i].x + (r[i].x - l[i].x) * f, l[i].y + (r[i].y - l[i].y) * f)
                    if i == 1 { line.move(to: p) } else { line.addLine(to: p) }
                }
                light.append(line)
            }
        }
        return Piece(fill: path, light: light)
    }

    /// 刘海 / 发际线的样子。
    private enum Fringe {
        /// 额头露出来；数值是发际线最高处的 y。
        case open(CGFloat)
        /// 男生偏方的发际线。
        case square(CGFloat)
        /// 中分：额头露出来，正中有一道分缝。
        case part(CGFloat)
        /// 齐刘海；数值是下沿的 y。
        case blunt(CGFloat)
        /// 空气刘海：一缕一缕，中间透出额头。
        case air(CGFloat)
        /// 八字刘海：从中间分开往两边垂。
        case curtain
        /// 侧分；数值是分缝的 x。
        case side(CGFloat)
        /// 碎刘海：下沿的 y，和小分缝的 x。
        case choppy(CGFloat, CGFloat)
        /// 卷刘海：下沿一个一个小弧。
        case wavy(CGFloat)
        /// 很短的斜刘海。
        case swept
    }

    /// 头顶这一块：外沿绕着头骨，内沿就是发际线 / 刘海。
    private static func cap(lift: CGFloat = 7, side: CGFloat = 4, puff: CGFloat = 3, peak: CGFloat = 0,
                            end: CGFloat = 80, burn: CGFloat = 0, fringe: Fringe, origin: CGFloat? = nil) -> Piece {
        let top = 36 - lift
        let lo = pt(cx - 24 - side, end), ro = pt(cx + 24 + side, end)
        let li = pt(cx - 21.5, end), ri = pt(cx + 21.5, end)
        let p = CGMutablePath()
        p.move(to: lo)
        p.addCurve(to: pt(cx + peak, top), control1: pt(lo.x - puff, end - 30), control2: pt(cx - 22 + peak * 0.5, top))
        p.addCurve(to: ro, control1: pt(cx + 22 + peak * 0.5, top), control2: pt(ro.x + puff, end - 30))
        if burn > 0 { p.addLine(to: pt(cx + 23.2, end + burn)) }
        p.addLine(to: ri)
        var partX = cx + peak
        switch fringe {
        case .open(let t):
            p.addCurve(to: pt(cx, t), control1: pt(cx + 22.5, end - 20), control2: pt(cx + 15, t))
            p.addCurve(to: li, control1: pt(cx - 15, t), control2: pt(cx - 22.5, end - 20))
        case .square(let t):
            p.addCurve(to: pt(cx + 15, t + 1.5), control1: pt(cx + 22.5, end - 14), control2: pt(cx + 20.5, t + 3))
            p.addQuadCurve(to: pt(cx - 15, t + 1.5), control: pt(cx, t - 1.5))
            p.addCurve(to: li, control1: pt(cx - 20.5, t + 3), control2: pt(cx - 22.5, end - 14))
        case .part(let t):
            p.addCurve(to: pt(cx + 3.5, t + 1.5), control1: pt(cx + 22.5, end - 20), control2: pt(cx + 14, t + 1))
            p.addLine(to: pt(cx, t - 8))
            p.addLine(to: pt(cx - 3.5, t + 1.5))
            p.addCurve(to: li, control1: pt(cx - 14, t + 1), control2: pt(cx - 22.5, end - 20))
            partX = cx
        case .blunt(let y):
            p.addLine(to: pt(cx + 22.5, y + 1.5))
            p.addCurve(to: pt(cx - 22.5, y + 1.5), control1: pt(cx + 9, y - 1.5), control2: pt(cx - 9, y - 1.5))
            p.addLine(to: li)
        case .air(let y):
            var last = pt(cx + 21.5, y + 2)
            p.addLine(to: last)
            for gx in [13.5, 4.5, -4.5, -13.5] as [CGFloat] {
                let next = pt(cx + gx, y - 11)
                p.addCurve(to: next, control1: pt(last.x - 2.2, y + 4), control2: pt(next.x + 2.2, y + 4))
                last = next
            }
            let final = pt(cx - 21.5, y + 2)
            p.addCurve(to: final, control1: pt(last.x - 2.2, y + 4), control2: pt(final.x + 2.2, y + 4))
            p.addLine(to: li)
        case .curtain:
            p.addCurve(to: pt(cx, 42), control1: pt(cx + 17, 64), control2: pt(cx + 5, 55))
            p.addCurve(to: li, control1: pt(cx - 5, 55), control2: pt(cx - 17, 64))
            partX = cx
        case .side(let px):
            p.addCurve(to: pt(px, 40), control1: pt(cx + 17, 57), control2: pt(px + 10, 44))
            p.addCurve(to: li, control1: pt(px - 7, 46), control2: pt(cx - 22.5, end - 20))
            partX = px
        case .choppy(let y, let gap):
            p.addLine(to: pt(cx + 22.5, y))
            var i = 0
            var x: CGFloat = 19
            while x >= -19.5 {
                let near = abs(cx + x - gap) < 2.8
                let jitter: [CGFloat] = [2.6, -1.4, 1.2, -2.4, 3, -0.6, 2, -2, 2.8, -1]
                p.addLine(to: pt(cx + x, near ? y - 9 : y + jitter[i % jitter.count]))
                x -= 4.8
                i += 1
            }
            p.addLine(to: pt(cx - 22.5, y))
            p.addLine(to: li)
        case .wavy(let y):
            p.addLine(to: pt(cx + 22, y - 1))
            var x: CGFloat = 22
            while x > -21 {
                let nx = x - 7.33
                p.addQuadCurve(to: pt(cx + nx, y - 1), control: pt(cx + (x + nx) / 2, y + 5.5))
                x = nx
            }
            p.addLine(to: li)
        case .swept:
            p.addCurve(to: pt(cx - 13, 46), control1: pt(cx + 19, 57), control2: pt(cx + 2, 57))
            p.addCurve(to: li, control1: pt(cx - 19, 48), control2: pt(cx - 22.5, end - 16))
            partX = cx - 13
        }
        if burn > 0 { p.addLine(to: pt(cx - 23.2, end + burn)) }
        p.closeSubpath()

        // 发丝从分缝 / 头顶往下散开；落在头发外面的部分画的时候自己会被裁掉。
        let o = pt(origin ?? partX, top + 3)
        var light: [CGPath] = []
        for dx in [-27, -21, -13, -5, 5, 13, 21, 27] as [CGFloat] {
            let k = abs(dx) / 27
            let target = pt(cx + dx, 60 + k * k * (end - 62))
            let line = CGMutablePath()
            line.move(to: o)
            line.addQuadCurve(to: target, control: pt((o.x + target.x) / 2 + (dx > 0 ? 5 : -5) * k, o.y + 3 + 6 * (1 - k)))
            light.append(line)
        }
        // 头顶的一道光泽。
        let shine = CGMutablePath()
        shine.move(to: pt(cx - 15, top + 13))
        shine.addQuadCurve(to: pt(cx + 15, top + 13), control: pt(cx, top + 4))
        return Piece(fill: p, light: light, shine: [(shine, 4.5)])
    }

    /// 背后的一大片。
    private static func sheet(to bottom: CGFloat, spread: CGFloat = 0, amp: CGFloat = 0, period: CGFloat = 26,
                              grow: CGFloat = 1, half: CGFloat = 30) -> Piece {
        ribbon(left: Edge(top: cx - 25, bottom: cx - half - spread, bulge: -(2 + spread * 0.4), amp: amp, period: period, phase: 0, grow: grow),
               right: Edge(top: cx + 25, bottom: cx + half + spread, bulge: 2 + spread * 0.4, amp: amp, period: period, phase: .pi, grow: grow),
               top: 60, bottom: bottom, end: .flat, strands: 0)
    }

    /// 垂到身前的左右两缕。
    private static func locks(to bottom: CGFloat, from top: CGFloat = 60, spread: CGFloat = 0, bulge: CGFloat = 2,
                              amp: CGFloat = 0, period: CGFloat = 26, grow: CGFloat = 1, inner: CGFloat = 16,
                              curl: Bool = false, end: End = .round, strands: Int = 2) -> [Piece] {
        var out: [Piece] = []
        for sgn in [-1, 1] as [CGFloat] {
            let phase: CGFloat = sgn > 0 ? .pi : 0
            let outer = Edge(top: cx + sgn * 28, bottom: cx + sgn * (31 + spread), bulge: sgn * bulge,
                             amp: amp, period: period, phase: phase, grow: grow)
            let inside = Edge(top: cx + sgn * 20, bottom: cx + sgn * inner, bulge: 0,
                              amp: amp * 0.75, period: period, phase: phase, grow: grow)
            let tip: End = curl ? (sgn < 0 ? .curlRight : .curlLeft) : end
            out.append(sgn < 0 ? ribbon(left: outer, right: inside, top: top, bottom: bottom, end: tip, strands: strands)
                               : ribbon(left: inside, right: outer, top: top, bottom: bottom, end: tip, strands: strands))
        }
        return out
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    /// 一个小卷：圆，加上里面一道 C 形的亮线。
    private static func curl(_ c: CGPoint, _ r: CGFloat, turn: CGFloat) -> Piece {
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: r * 0.52, startAngle: turn, endAngle: turn + 3.6, clockwise: false)
        return Piece(fill: circle(c, r), light: [arc])
    }

    /// 麻花辫：一行两瓣，左右错开半行，叠成人字纹。
    private static func braid(from a: CGPoint, to b: CGPoint, width: CGFloat, count: Int) -> [Piece] {
        var out: [Piece] = []
        let dx = (b.x - a.x) / CGFloat(count), dy = (b.y - a.y) / CGFloat(count)
        for i in 0..<count {
            let w = width * (1 - 0.26 * CGFloat(i) / CGFloat(count))
            for sgn in [-1, 1] as [CGFloat] {
                let row = CGFloat(i) + 0.5 + (sgn > 0 ? 0.5 : 0)
                let c = pt(a.x + dx * row + sgn * w * 0.21, a.y + dy * row)
                let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: sgn * 0.62)
                let petal = CGMutablePath()
                petal.addEllipse(in: CGRect(x: -w * 0.27, y: -dy * 0.82, width: w * 0.54, height: dy * 1.64), transform: t)
                let line = CGMutablePath()
                line.move(to: pt(0, -dy * 0.45).applying(t))
                line.addLine(to: pt(0, dy * 0.45).applying(t))
                out.append(Piece(fill: petal, light: [line], dark: [petal]))
            }
        }
        return out
    }

    /// 简单的伪随机数，保证每次画出来都一样。
    private struct Dice {
        var state: UInt64
        mutating func next() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
    }

    // MARK: 55 个发型

    /// 刘海 / 分缝这一组共用的中长发。
    private static func medium(_ s: inout Scene, fringe: Fringe, peak: CGFloat = 0) {
        s.back = [sheet(to: 138)]
        s.front = [cap(peak: peak, fringe: fringe)] + locks(to: 142, curl: true)
    }

    /// 头发全部往后梳起来的头顶。
    private static func pulledBack(_ s: inout Scene, fringe: Fringe = .open(46)) {
        s.ears = true
        s.front = [cap(lift: 5.5, side: 2.5, puff: 2, end: 74, burn: 5, fringe: fringe)]
    }

    private static func men(_ s: inout Scene) {
        s.male = true
        s.ears = true
    }

    private static let styles: [String: (inout Scene) -> Void] = [
        "长直发": { s in
            s.back = [sheet(to: 170, half: 31)]
            s.front = [cap(lift: 6.5, fringe: .part(46))] + locks(to: 172, bulge: 1, inner: 13, end: .flat, strands: 3)
        },
        "大波浪": { s in
            s.back = [sheet(to: 150, spread: 4, amp: 3.5, period: 30)]
            s.front = [cap(lift: 8, peak: 3, fringe: .side(cx - 10))]
                + locks(to: 154, spread: 5, bulge: 3, amp: 4.6, period: 30, inner: 15, strands: 3)
        },
        "法式卷": { s in
            s.back = [sheet(to: 122, spread: 6, amp: 3.2, period: 16, grow: 0.7)]
            s.front = [cap(lift: 8, side: 5, puff: 4, fringe: .air(63))]
                + locks(to: 127, spread: 7, bulge: 4, amp: 3.8, period: 16, grow: 0.6, inner: 17, strands: 2)
        },
        "羊毛卷": { s in
            var dice = Dice(state: 11)
            s.shift = 11
            // 背后一大团。
            s.back = [Piece(fill: CGPath(ellipseIn: CGRect(x: cx - 37, y: 30, width: 74, height: 92), transform: nil))]
            var a: CGFloat = 0
            while a < 2 * .pi {
                s.back.append(curl(pt(cx + 38 * cos(a), 76 + 46 * sin(a)), 7.5, turn: dice.next() * 6))
                a += 0.36
            }
            // 头顶和刘海。
            s.front = [cap(lift: 9, side: 6, puff: 5, end: 84, fringe: .wavy(57))]
            a = .pi
            while a < 2 * .pi + 0.01 {
                s.front.append(curl(pt(cx + 31 * cos(a), 58 + 31 * sin(a)), 7, turn: dice.next() * 6))
                a += 0.3
            }
            for x in stride(from: CGFloat(-18), through: 18, by: 9) {
                s.front.append(curl(pt(cx + x, 41 + abs(x) * 0.25), 6.5, turn: dice.next() * 6))
                s.front.append(curl(pt(cx + x * 0.9, 51 + abs(x) * 0.2), 5.5, turn: dice.next() * 6))
            }
            // 两侧一路卷到肩上。
            for sgn in [-1, 1] as [CGFloat] {
                var y: CGFloat = 62
                while y <= 120 {
                    s.front.append(curl(pt(cx + sgn * (28 + dice.next() * 3), y), 7.5, turn: dice.next() * 6))
                    if y > 92 { s.front.append(curl(pt(cx + sgn * (19 + dice.next() * 2), y + 3), 6, turn: dice.next() * 6)) }
                    y += 8.5
                }
            }
        },
        "水波纹": { s in
            s.back = [sheet(to: 146, spread: 2, amp: 2.4, period: 13, grow: 0)]
            var pieces = [cap(lift: 7, peak: 4, fringe: .side(cx - 12))]
                + locks(to: 150, spread: 3, bulge: 2, amp: 3, period: 13, grow: 0.15, inner: 15, strands: 1)
            // 一道一道横着的光泽，就是"水波"。
            var bands = Piece(fill: CGMutablePath())
            var y: CGFloat = 67
            while y < 150 {
                for sgn in [-1, 1] as [CGFloat] {
                    let band = CGMutablePath()
                    band.move(to: pt(cx + sgn * 16, y + 1.5))
                    band.addQuadCurve(to: pt(cx + sgn * 35, y - 1.5), control: pt(cx + sgn * 26, y - 3.5))
                    bands.shine.append((band, 3))
                }
                y += 13
            }
            pieces.append(bands)
            s.front = pieces
        },
        "锁骨发": { s in
            s.back = [sheet(to: 117)]
            s.front = [cap(fringe: .side(cx - 7))] + locks(to: 121, bulge: 3, inner: 17.5, curl: true)
        },
        "波波头": { s in
            s.back = [sheet(to: 97, half: 27)]
            s.front = [cap(lift: 8, side: 5, puff: 4, fringe: .blunt(64))]
                + locks(to: 98, spread: -2, bulge: 6.5, inner: 19, end: .round)
        },
        "短发": { s in
            s.back = [sheet(to: 86, half: 24)]
            s.front = [cap(lift: 7.5, side: 4, peak: 3, fringe: .side(cx - 9))]
                + locks(to: 86, spread: -5, bulge: 3, inner: 20, end: .taper, strands: 1)
        },
        "精灵短发": { s in
            s.ears = true
            s.front = [cap(lift: 6.5, side: 2.2, puff: 2, peak: -3, end: 71, burn: 8, fringe: .swept)]
            // 额前几缕碎发。
            s.front.append(tube([pt(cx - 12, 45), pt(cx + 2, 54), pt(cx + 14, 60), pt(cx + 20, 63)]) { 5 * (1 - $0 * 0.75) })
        },
        "高马尾": { s in
            pulledBack(&s)
            s.shift = 16
            s.back = [tube([pt(cx + 5, 30), pt(cx + 22, 15), pt(cx + 41, 26), pt(cx + 47, 60), pt(cx + 43, 100), pt(cx + 38, 128)], strands: 2) { t in
                (7 + 10 * sin(min(t * 1.5, 1) * .pi / 2)) * (t > 0.8 ? 1 - (t - 0.8) / 0.2 * 0.7 : 1)
            }]
            s.ties = [CGRect(x: cx + 9, y: 19.5, width: 8, height: 6)]
        },
        "低马尾": { s in
            pulledBack(&s, fringe: .part(46))
            s.back = [ribbon(left: Edge(top: cx - 22, bottom: cx - 6), right: Edge(top: cx + 22, bottom: cx + 22),
                             top: 70, bottom: 100, end: .flat, strands: 0)]
            s.front.append(tube([pt(cx + 18, 96), pt(cx + 23, 110), pt(cx + 26, 130), pt(cx + 24, 154)], strands: 2) { t in
                (8 + 5 * sin(min(t * 2, 1) * .pi / 2)) * (t > 0.75 ? 1 - (t - 0.75) / 0.25 * 0.75 : 1)
            })
            s.ties = [CGRect(x: cx + 14.5, y: 97, width: 9, height: 5)]
        },
        "丸子头": { s in
            pulledBack(&s)
            s.shift = 20
            var bun = curl(pt(cx, 19), 13, turn: 2.2)
            let inner = CGMutablePath()
            inner.addArc(center: pt(cx + 1, 19), radius: 3.5, startAngle: 0.5, endAngle: 5, clockwise: false)
            bun.light.append(inner)
            s.back = [bun]
            // 鬓角各留一缕。
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 21.5, 58), pt(cx + sgn * 24.5, 74), pt(cx + sgn * 22.5, 91)], strands: 0) { 2.6 * (1 - $0 * 0.7) })
            }
        },
        "双马尾": { s in
            s.front = [cap(lift: 6.5, side: 3, puff: 2.5, end: 76, fringe: .air(63))]
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 26, 60), pt(cx + sgn * 37, 66), pt(cx + sgn * 42, 92), pt(cx + sgn * 39, 124), pt(cx + sgn * 35, 146)], strands: 2) { t in
                    (7 + 8 * sin(min(t * 2.2, 1) * .pi / 2)) * (t > 0.7 ? 1 - (t - 0.7) / 0.3 * 0.75 : 1)
                })
                s.ties.append(CGRect(x: cx + sgn * 30.5 - 3.5, y: 58, width: 7, height: 9))
            }
        },
        "公主切": { s in
            s.back = [sheet(to: 170, half: 32)]
            s.front = [cap(lift: 6.5, fringe: .blunt(64))]
            for sgn in [-1, 1] as [CGFloat] {
                // 脸颊两边齐齐剪断的一截。
                let outer = Edge(top: cx + sgn * 28, bottom: cx + sgn * 29.5)
                let inside = Edge(top: cx + sgn * 20, bottom: cx + sgn * 14.5)
                s.front.append(sgn < 0 ? ribbon(left: outer, right: inside, top: 60, bottom: 93, end: .flat, strands: 2)
                                       : ribbon(left: inside, right: outer, top: 60, bottom: 93, end: .flat, strands: 2))
                // 后面的长发从它外侧垂下去。
                let far = Edge(top: cx + sgn * 29.5, bottom: cx + sgn * 33)
                let near = Edge(top: cx + sgn * 23.5, bottom: cx + sgn * 21)
                s.front.append(sgn < 0 ? ribbon(left: far, right: near, top: 90, bottom: 172, end: .flat, strands: 1)
                                       : ribbon(left: near, right: far, top: 90, bottom: 172, end: .flat, strands: 1))
            }
        },
        "编发": { s in
            s.ears = false
            s.back = [ribbon(left: Edge(top: cx - 24, bottom: cx - 22), right: Edge(top: cx + 24, bottom: cx + 14),
                             top: 60, bottom: 104, end: .flat, strands: 0)]
            s.front = [cap(lift: 6.5, fringe: .part(46))]
            // 左边的头发收成一股。
            s.front.append(ribbon(left: Edge(top: cx - 28, bottom: cx - 30, bulge: -2), right: Edge(top: cx - 20, bottom: cx - 17),
                                  top: 60, bottom: 96, end: .flat, strands: 2))
            s.front.append(ribbon(left: Edge(top: cx + 20, bottom: cx + 19), right: Edge(top: cx + 28, bottom: cx + 24, bulge: 1),
                                  top: 60, bottom: 90, end: .taper, strands: 1))
            s.front += braid(from: pt(cx - 24, 91), to: pt(cx - 26.5, 143), width: 17, count: 6)
            s.front.append(tube([pt(cx - 26.5, 146), pt(cx - 27, 153), pt(cx - 25.5, 161)], strands: 1) { 8 * (1 - $0 * 0.65) })
            s.ties = [CGRect(x: cx - 31.5, y: 144, width: 10, height: 4.5)]
        },
        "空气刘海": { s in medium(&s, fringe: .air(63)) },
        "八字刘海": { s in
            medium(&s, fringe: .curtain)
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 1.5, 41), pt(cx + sgn * 9, 51), pt(cx + sgn * 18, 64), pt(cx + sgn * 24, 79), pt(cx + sgn * 28.5, 87)], strands: 2) { t in
                    4 + 5 * sin(t * .pi) + (t > 0.8 ? -(t - 0.8) * 12 : 0)
                })
            }
        },
        "齐刘海": { s in medium(&s, fringe: .blunt(64)) },
        "中分": { s in
            medium(&s, fringe: .part(47))
            // 分缝。
            let line = CGMutablePath()
            line.move(to: pt(cx, 30.5))
            line.addLine(to: pt(cx, 40))
            s.front.append(Piece(fill: CGMutablePath(), dark: [line]))
        },
        "侧分": { s in medium(&s, fringe: .side(cx - 13), peak: 5) },
        // 下面 30 个
        "层次长发": { s in
            s.back = [sheet(to: 152, spread: 2)]
            s.front = [cap(lift: 7.5, fringe: .curtain)] + locks(to: 150, spread: 3, inner: 17, end: .taper, strands: 2)
                + locks(to: 112, spread: 4, bulge: 4, inner: 22, end: .taper, strands: 1)
        },
        "韩系大卷": { s in
            s.back = [sheet(to: 156, spread: 6, amp: 4, period: 36)]
            s.front = [cap(lift: 9, side: 5, puff: 4, fringe: .curtain)]
                + locks(to: 158, spread: 7, bulge: 4, amp: 5.5, period: 36, inner: 15, strands: 3)
        },
        "木马卷": { s in
            s.back = [sheet(to: 150, spread: 3)]
            s.front = [cap(lift: 7, fringe: .air(63))]
            for x in [-27, -19, 19, 27] as [CGFloat] {
                var y: CGFloat = 74
                while y < 152 {
                    s.front.append(curl(pt(cx + x, y), 6.4, turn: x > 0 ? 1 : 4))
                    y += 8
                }
            }
        },
        "蛋卷头": { s in
            s.back = [sheet(to: 148, spread: 7, amp: 2.6, period: 8, grow: 0.2)]
            s.front = [cap(lift: 9, side: 6, puff: 5, fringe: .part(46))]
                + locks(to: 150, spread: 8, bulge: 4, amp: 2.8, period: 8, grow: 0.1, inner: 15, strands: 3)
        },
        "螺旋卷": { s in
            s.back = [sheet(to: 148, spread: 3)]
            s.front = [cap(lift: 7, peak: 3, fringe: .side(cx - 9))]
            for x in [-30, -22, 22, 30] as [CGFloat] {
                s.front.append(tube((0...8).map { pt(cx + x + ($0 % 2 == 0 ? -3 : 3), 64 + CGFloat($0) * 11) }, strands: 1) { _ in 8 })
            }
        },
        "港风卷发": { s in
            s.back = [sheet(to: 140, spread: 10, amp: 4, period: 24)]
            s.front = [cap(lift: 13, side: 7, puff: 6, peak: 5, fringe: .side(cx - 12))]
                + locks(to: 144, spread: 10, bulge: 6, amp: 5, period: 24, inner: 16, strands: 3)
        },
        "复古手推波": { s in
            s.back = [sheet(to: 92, half: 27)]
            var pieces = [cap(lift: 6, side: 3, peak: 5, fringe: .side(cx - 13))]
                + locks(to: 94, spread: -3, bulge: 4, amp: 3.4, period: 14, grow: 0.1, inner: 20, curl: true, strands: 1)
            var bands = Piece(fill: CGMutablePath())
            for y in stride(from: CGFloat(44), to: 92, by: 11) {
                for sgn in [-1, 1] as [CGFloat] {
                    let band = CGMutablePath()
                    band.move(to: pt(cx + sgn * 14, y + 2))
                    band.addQuadCurve(to: pt(cx + sgn * 30, y - 1), control: pt(cx + sgn * 23, y - 4))
                    bands.shine.append((band, 2.6))
                }
            }
            pieces.append(bands)
            s.front = pieces
        },
        "内扣长发": { s in
            s.back = [sheet(to: 148)]
            s.front = [cap(fringe: .part(46))] + locks(to: 150, spread: 1, bulge: 4, inner: 14, curl: true, strands: 3)
        },
        "一刀切": { s in
            s.back = [sheet(to: 128, half: 32)]
            s.front = [cap(lift: 6.5, fringe: .part(46))] + locks(to: 128, spread: 2, bulge: 1, inner: 13, end: .flat, strands: 3)
        },
        "法式短发": { s in
            s.back = [sheet(to: 95, spread: 1, half: 27)]
            s.front = [cap(lift: 8, side: 5, puff: 4, fringe: .air(62))] + locks(to: 97, spread: 0, bulge: 5, amp: 1.8, period: 18, inner: 19, curl: true)
        },
        "鲻鱼头": { s in
            s.back = [sheet(to: 124, half: 25)]
            s.front = [cap(lift: 9.5, side: 4, puff: 4, fringe: .choppy(60, cx + 5), origin: cx + 5)]
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 25, 66), pt(cx + sgn * 25, 96), pt(cx + sgn * 24, 116), pt(cx + sgn * 30, 128)], strands: 1) { 9 * (1 - $0 * 0.75) })
            }
        },
        "水母头": { s in
            s.back = [sheet(to: 168, half: 22)]
            s.front = [cap(lift: 8.5, side: 6, puff: 5, fringe: .blunt(64))] + locks(to: 92, spread: 1, bulge: 7, inner: 19, end: .round)
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 25, 90), pt(cx + sgn * 25, 130), pt(cx + sgn * 24, 168)], strands: 1) { 8 * (1 - $0 * 0.4) })
            }
        },
        "外翘短发": { s in
            s.back = [sheet(to: 94, half: 25)]
            s.front = [cap(lift: 7.5, fringe: .air(62))] + locks(to: 90, spread: -3, bulge: 2, inner: 20, strands: 1)
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 25, 78), pt(cx + sgn * 27, 92), pt(cx + sgn * 37, 98)], strands: 1) { 9 * (1 - $0 * 0.8) })
            }
        },
        "短卷发": { s in
            var dice = Dice(state: 23)
            s.shift = 6
            s.back = [Piece(fill: CGPath(ellipseIn: CGRect(x: cx - 33, y: 34, width: 66, height: 66), transform: nil))]
            s.front = [cap(lift: 9, side: 5, puff: 5, end: 80, fringe: .wavy(57))]
            for sgn in [-1, 1] as [CGFloat] {
                for y in stride(from: CGFloat(58), through: 96, by: 8) { s.front.append(curl(pt(cx + sgn * (29 + dice.next() * 3), y), 7, turn: dice.next() * 6)) }
            }
            for x in stride(from: CGFloat(-18), through: 18, by: 9) { s.front.append(curl(pt(cx + x, 38 + abs(x) * 0.25), 6, turn: dice.next() * 6)) }
        },
        "锁骨内扣": { s in
            s.back = [sheet(to: 114, spread: 1)]
            s.front = [cap(fringe: .air(63))] + locks(to: 116, spread: 1, bulge: 4.5, inner: 16, curl: true)
        },
        "低丸子头": { s in
            pulledBack(&s, fringe: .part(46))
            s.back = [curl(pt(cx + 4, 98), 15, turn: 2)]
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 21, 56), pt(cx + sgn * 25, 74), pt(cx + sgn * 22, 94)], strands: 0) { 3 * (1 - $0 * 0.7) })
            }
        },
        "双丸子头": { s in
            pulledBack(&s, fringe: .air(62))
            s.shift = 16
            s.back = [curl(pt(cx - 21, 25), 11, turn: 1), curl(pt(cx + 21, 25), 11, turn: 4)]
        },
        "半扎丸子": { s in
            medium(&s, fringe: .part(46))
            s.shift = 14
            s.back.append(curl(pt(cx, 24), 11, turn: 2.2))
        },
        "公主头": { s in
            medium(&s, fringe: .part(46))
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 10, 40), pt(cx + sgn * 23, 48), pt(cx + sgn * 30, 62)], strands: 2) { 9 - 3 * $0 })
            }
            s.ties = [CGRect(x: cx - 33, y: 60, width: 6, height: 6), CGRect(x: cx + 27, y: 60, width: 6, height: 6)]
        },
        "侧马尾": { s in
            pulledBack(&s, fringe: .side(cx + 10))
            s.front.append(tube([pt(cx - 20, 88), pt(cx - 28, 100), pt(cx - 30, 126), pt(cx - 26, 158)], strands: 2) { t in
                (8 + 7 * sin(min(t * 2, 1) * .pi / 2)) * (t > 0.75 ? 1 - (t - 0.75) / 0.25 * 0.75 : 1)
            })
            s.ties = [CGRect(x: cx - 26, y: 89, width: 10, height: 6)]
        },
        "鱼骨辫": { s in
            s.back = [ribbon(left: Edge(top: cx - 22, bottom: cx - 12), right: Edge(top: cx + 24, bottom: cx + 22), top: 60, bottom: 104, end: .flat, strands: 0)]
            s.front = [cap(lift: 6.5, fringe: .part(46))]
            s.front.append(ribbon(left: Edge(top: cx + 20, bottom: cx + 17), right: Edge(top: cx + 28, bottom: cx + 30, bulge: 2), top: 60, bottom: 94, end: .flat, strands: 2))
            s.front += braid(from: pt(cx + 24, 90), to: pt(cx + 26, 148), width: 18, count: 11)
            s.ties = [CGRect(x: cx + 21, y: 148, width: 10, height: 4.5)]
        },
        "双麻花辫": { s in
            s.front = [cap(lift: 6.5, side: 3, end: 78, fringe: .part(46))]
            for sgn in [-1, 1] as [CGFloat] {
                s.front += braid(from: pt(cx + sgn * 25, 76), to: pt(cx + sgn * 29, 146), width: 15, count: 8)
                s.ties.append(CGRect(x: cx + sgn * 29 - 4.5, y: 146, width: 9, height: 4.5))
            }
        },
        "拳击辫": { s in
            pulledBack(&s, fringe: .part(46))
            for sgn in [-1, 1] as [CGFloat] {
                s.front += braid(from: pt(cx + sgn * 9, 34), to: pt(cx + sgn * 24, 70), width: 11, count: 5)
                s.front += braid(from: pt(cx + sgn * 25, 78), to: pt(cx + sgn * 27, 140), width: 11, count: 8)
            }
        },
        "新娘盘发": { s in
            pulledBack(&s, fringe: .side(cx - 9))
            s.back = [curl(pt(cx - 10, 96), 11, turn: 1), curl(pt(cx + 10, 96), 11, turn: 3), curl(pt(cx, 104), 10, turn: 5)]
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 22, 58), pt(cx + sgn * 27, 70), pt(cx + sgn * 23, 82), pt(cx + sgn * 27, 94), pt(cx + sgn * 24, 104)], strands: 0) { 3.4 * (1 - $0 * 0.6) })
            }
        },
        "泡泡马尾": { s in
            pulledBack(&s)
            s.shift = 16
            var y: CGFloat = 24
            for i in 0..<5 {
                s.back.append(curl(pt(cx + 24 + CGFloat(i) * 4, y + 6), 11, turn: CGFloat(i)))
                s.ties.append(CGRect(x: cx + 20 + CGFloat(i) * 4, y: y - 5, width: 8, height: 4))
                y += 21
            }
        },
        "脏辫": { s in
            s.back = [sheet(to: 150, spread: 1)]
            s.front = [cap(lift: 6, fringe: .open(46))]
            for x in stride(from: CGFloat(-32), through: 32, by: 5.8) where abs(x) > 17 {
                s.front += braid(from: pt(cx + x * 0.86, 58), to: pt(cx + x, 152), width: 6, count: 13)
            }
        },
        "法式刘海": { s in
            medium(&s, fringe: .curtain)
            s.front.append(tube([pt(cx - 3, 42), pt(cx - 9, 54), pt(cx - 11, 63)], strands: 1) { 8 * (1 - $0 * 0.5) })
            s.front.append(tube([pt(cx + 3, 42), pt(cx + 9, 54), pt(cx + 11, 63)], strands: 1) { 8 * (1 - $0 * 0.5) })
        },
        "眉上刘海": { s in medium(&s, fringe: .blunt(55)) },
        "龙须刘海": { s in
            medium(&s, fringe: .part(46))
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 2, 40), pt(cx + sgn * 14, 54), pt(cx + sgn * 17, 74), pt(cx + sgn * 15, 92)], strands: 0) { 3.2 * (1 - $0 * 0.6) })
            }
        },
        "大光明": { s in
            s.ears = true
            s.back = [sheet(to: 140)]
            s.front = [cap(lift: 8, side: 2.5, puff: 2, end: 72, fringe: .open(42), origin: cx)]
        },
        "寸头": { s in
            men(&s)
            s.pale = true
            s.front = [cap(lift: 2.6, side: 1.2, puff: 0.8, end: 70, fringe: .square(46.5))]
            s.front[0].light = []
            s.front[0].shine = []
        },
        "背头": { s in
            men(&s)
            s.front = [cap(lift: 11.5, side: 1.8, puff: 1.2, end: 71, burn: 5, fringe: .square(47.5), origin: cx)]
            // 往后梳的纹路。
            for dx in [-14, -7, 0, 7, 14] as [CGFloat] {
                let line = CGMutablePath()
                line.move(to: pt(cx + dx, 47))
                line.addQuadCurve(to: pt(cx + dx * 0.55, 27), control: pt(cx + dx * 1.15, 35))
                s.front[0].dark.append(line)
            }
        },
        "纹理烫": { s in
            men(&s)
            var dice = Dice(state: 5)
            s.shift = 7
            s.front = [cap(lift: 9, side: 2.6, puff: 2.5, end: 70, burn: 4, fringe: .wavy(56))]
            var a: CGFloat = .pi * 1.08
            while a < .pi * 1.93 {
                s.front.append(curl(pt(cx + 26 * cos(a), 52 + 25 * sin(a)), 5.6, turn: dice.next() * 6))
                a += 0.27
            }
            for x in stride(from: CGFloat(-15), through: 15, by: 7.5) {
                s.front.append(curl(pt(cx + x, 37 + abs(x) * 0.2), 5.2, turn: dice.next() * 6))
                s.front.append(curl(pt(cx + x * 0.95, 47 + abs(x) * 0.15), 4.8, turn: dice.next() * 6))
            }
        },
        "微分碎盖": { s in
            men(&s)
            s.front = [cap(lift: 8.5, side: 3.2, puff: 3.2, end: 72, burn: 3, fringe: .choppy(63, cx - 6), origin: cx - 6)]
        },
        "狼尾": { s in
            men(&s)
            s.back = [ribbon(left: Edge(top: cx - 23, bottom: cx - 24), right: Edge(top: cx + 23, bottom: cx + 24),
                             top: 66, bottom: 116, end: .flat, strands: 0)]
            s.front = [cap(lift: 8.5, side: 3.4, puff: 3, end: 76, burn: 4, fringe: .choppy(61, cx + 6), origin: cx + 6)]
            // 后颈留长，发尾往外翘。
            for sgn in [-1, 1] as [CGFloat] {
                s.front.append(tube([pt(cx + sgn * 25, 68), pt(cx + sgn * 25.5, 94), pt(cx + sgn * 28, 112), pt(cx + sgn * 36, 121)], strands: 1) { t in
                    10 * (1 - t * 0.8) * min(1, 0.5 + t * 3)
                })
                s.front.append(tube([pt(cx + sgn * 21, 98), pt(cx + sgn * 21, 112), pt(cx + sgn * 26, 124)], strands: 1) { t in
                    8.5 * (1 - t * 0.8)
                })
            }
        },
    ]

    // MARK: 画

    private static func draw(_ scene: Scene, in ctx: CGContext) {
        // 背景：暖灰，头后面带一点柔光。
        if let g = CGGradient(colorsSpace: space, colors: [rgb(0.86, 0.82, 0.77), rgb(0.73, 0.69, 0.64)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: pt(0, 0), end: pt(0, H), options: [])
        }
        if let g = CGGradient(colorsSpace: space, colors: [rgb(1, 0.98, 0.95, 0.42), rgb(1, 0.98, 0.95, 0)] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(g, startCenter: pt(cx, 66), startRadius: 0, endCenter: pt(cx, 66), endRadius: 78, options: [])
        }

        // 人像以底边中点为准放大一点，头像把画面占满。
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: cx, y: H + scene.shift)
        ctx.scaleBy(x: 1.14, y: 1.14)
        ctx.translateBy(x: -cx, y: -H)

        paint(scene.back, behind: true, pale: scene.pale, in: ctx)
        body(male: scene.male, in: ctx)
        if scene.ears {
            ctx.setFillColor(ink(Ink.skinShade))
            for sgn in [-1, 1] as [CGFloat] {
                ctx.fillEllipse(in: CGRect(x: cx + sgn * 24.6 - 3.4, y: 71, width: 6.8, height: 12))
            }
        }
        face(male: scene.male, in: ctx)
        paint(scene.front, behind: false, pale: scene.pale, in: ctx)
        for tie in scene.ties {
            ctx.setFillColor(rgb(0.80, 0.36, 0.38))
            ctx.addPath(CGPath(roundedRect: tie, cornerWidth: min(tie.width, tie.height) / 2, cornerHeight: min(tie.width, tie.height) / 2, transform: nil))
            ctx.fillPath()
        }
    }

    /// 把一组头发画成一个整体：先平涂，再只在头发上叠明暗和发丝。
    private static func paint(_ pieces: [Piece], behind: Bool, pale: Bool, in ctx: CGContext) {
        guard !pieces.isEmpty else { return }
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(ink(pale ? Ink.stubble : Ink.hair))
        for piece in pieces where !piece.fill.isEmpty {
            ctx.addPath(piece.fill)
            ctx.fillPath()
        }
        ctx.setBlendMode(.sourceAtop)
        if !pale, let g = CGGradient(colorsSpace: space,
                                     colors: [ink(Ink.light, 0.34), ink(Ink.hair, 0), ink(Ink.dark, 0.5)] as CFArray,
                                     locations: [0, 0.42, 1]) {
            ctx.drawLinearGradient(g, start: pt(0, 20), end: pt(0, H), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        if behind {
            ctx.setFillColor(ink(Ink.dark, 0.38))
            ctx.fill(CGRect(x: -W, y: -H, width: W * 3, height: H * 3))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(ink(Ink.light, 0.2))
        for piece in pieces {
            for item in piece.shine {
                ctx.setLineWidth(item.width)
                ctx.addPath(item.path)
                ctx.strokePath()
            }
        }
        ctx.setLineWidth(0.9)
        ctx.setStrokeColor(ink(Ink.light, 0.36))
        for piece in pieces {
            for line in piece.light {
                ctx.addPath(line)
                ctx.strokePath()
            }
        }
        ctx.setStrokeColor(ink(Ink.dark, 0.55))
        for piece in pieces {
            for line in piece.dark {
                ctx.addPath(line)
                ctx.strokePath()
            }
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func body(male: Bool, in ctx: CGContext) {
        let neck: CGFloat = male ? 11.5 : 8.5
        let half: CGFloat = male ? 58 : 47
        let top: CGFloat = male ? 113 : 117
        let shoulders = CGMutablePath()
        shoulders.move(to: pt(cx - half, H))
        shoulders.addLine(to: pt(cx - half, top + 24))
        shoulders.addCurve(to: pt(cx - neck - 1, top), control1: pt(cx - half, top + 9), control2: pt(cx - neck - 13, top + 6))
        shoulders.addLine(to: pt(cx + neck + 1, top))
        shoulders.addCurve(to: pt(cx + half, top + 24), control1: pt(cx + neck + 13, top + 6), control2: pt(cx + half, top + 9))
        shoulders.addLine(to: pt(cx + half, H))
        shoulders.closeSubpath()
        ctx.addPath(shoulders)
        ctx.setFillColor(male ? rgb(0.31, 0.35, 0.41) : rgb(0.965, 0.945, 0.915))
        ctx.fillPath()
        // 领口。
        ctx.saveGState()
        ctx.addPath(shoulders)
        ctx.clip()
        ctx.setFillColor(ink(Ink.skin))
        if male {
            ctx.fillEllipse(in: CGRect(x: cx - neck - 3, y: top - 8, width: (neck + 3) * 2, height: 17))
            ctx.setStrokeColor(rgb(0.24, 0.27, 0.32))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: cx - neck - 3, y: top - 8, width: (neck + 3) * 2, height: 17))
        } else {
            ctx.fillEllipse(in: CGRect(x: cx - neck - 10, y: top - 14, width: (neck + 10) * 2, height: 30))
        }
        ctx.restoreGState()

        // 脖子，下巴底下压一点阴影。
        ctx.setFillColor(ink(Ink.skin))
        ctx.fill(CGRect(x: cx - neck, y: 90, width: neck * 2, height: top - 90 + 1.5))
        ctx.saveGState()
        ctx.clip(to: CGRect(x: cx - neck, y: 90, width: neck * 2, height: top - 90 + 1.5))
        ctx.setFillColor(ink(Ink.skinShade))
        ctx.fillEllipse(in: CGRect(x: cx - 22, y: 92, width: 44, height: 20))
        ctx.restoreGState()
    }

    private static func facePath(male: Bool) -> CGPath {
        let jaw: CGFloat = male ? 21.5 : 18.5
        let chinY: CGFloat = male ? 106 : 105
        let chin: CGFloat = male ? 12.5 : 7
        let p = CGMutablePath()
        p.move(to: pt(cx, 36))
        p.addCurve(to: pt(cx + 24, 68), control1: pt(cx + 18, 36), control2: pt(cx + 24, 50))
        p.addCurve(to: pt(cx + jaw, 91), control1: pt(cx + 24, 78), control2: pt(cx + jaw + 2.5, 85))
        p.addCurve(to: pt(cx, chinY), control1: pt(cx + jaw - 3.5, 100), control2: pt(cx + chin, chinY))
        p.addCurve(to: pt(cx - jaw, 91), control1: pt(cx - chin, chinY), control2: pt(cx - jaw + 3.5, 100))
        p.addCurve(to: pt(cx - 24, 68), control1: pt(cx - jaw - 2.5, 85), control2: pt(cx - 24, 78))
        p.addCurve(to: pt(cx, 36), control1: pt(cx - 24, 50), control2: pt(cx - 18, 36))
        p.closeSubpath()
        return p
    }

    private static func face(male: Bool, in ctx: CGContext) {
        ctx.addPath(facePath(male: male))
        ctx.setFillColor(ink(Ink.skin))
        ctx.fillPath()
        // 腮红。
        if !male {
            ctx.setFillColor(rgb(0.96, 0.58, 0.56, 0.24))
            for sgn in [-1, 1] as [CGFloat] {
                ctx.fillEllipse(in: CGRect(x: cx + sgn * 13.5 - 5, y: 79, width: 10, height: 6.5))
            }
        }
        ctx.setLineCap(.round)
        // 眉毛。
        ctx.setStrokeColor(ink(Ink.hair, 0.8))
        ctx.setLineWidth(male ? 1.9 : 1.2)
        for sgn in [-1, 1] as [CGFloat] {
            ctx.move(to: pt(cx + sgn * 5.5, 66.2))
            ctx.addQuadCurve(to: pt(cx + sgn * 14.5, male ? 65.6 : 66), control: pt(cx + sgn * 10.5, male ? 64.6 : 63.8))
            ctx.strokePath()
        }
        // 眼睛。
        ctx.setFillColor(ink(Ink.dark))
        for sgn in [-1, 1] as [CGFloat] {
            ctx.fillEllipse(in: CGRect(x: cx + sgn * 9.8 - 1.9, y: 70.4, width: 3.8, height: 4.6))
            if !male {
                ctx.setStrokeColor(ink(Ink.dark))
                ctx.setLineWidth(0.9)
                ctx.move(to: pt(cx + sgn * 6.6, 71.6))
                ctx.addQuadCurve(to: pt(cx + sgn * 13.8, 70.6), control: pt(cx + sgn * 10, 68.8))
                ctx.strokePath()
            }
        }
        // 鼻子只点一下影子。
        ctx.setStrokeColor(ink(Ink.skinShade))
        ctx.setLineWidth(1.1)
        ctx.move(to: pt(cx - 1.8, 83.5))
        ctx.addQuadCurve(to: pt(cx + 1.8, 83.5), control: pt(cx, 85))
        ctx.strokePath()
        // 嘴。
        if male {
            ctx.setStrokeColor(rgb(0.70, 0.45, 0.40))
            ctx.setLineWidth(1.3)
            ctx.move(to: pt(cx - 4.2, 92.5))
            ctx.addQuadCurve(to: pt(cx + 4.2, 92.5), control: pt(cx, 94))
            ctx.strokePath()
        } else {
            let lips = CGMutablePath()
            lips.move(to: pt(cx - 4.4, 91.6))
            lips.addQuadCurve(to: pt(cx, 90.6), control: pt(cx - 2, 89.8))
            lips.addQuadCurve(to: pt(cx + 4.4, 91.6), control: pt(cx + 2, 89.8))
            lips.addQuadCurve(to: pt(cx - 4.4, 91.6), control: pt(cx, 95.6))
            ctx.addPath(lips)
            ctx.setFillColor(rgb(0.83, 0.42, 0.43))
            ctx.fillPath()
        }
    }
}
