import SwiftUI

/// 裁剪界面：图片上叠一个可拖动的裁剪框。
struct CropCanvas: View {
    @Bindable var model: EditorModel

    private let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let box = CGSize(width: geo.size.width - margin * 2, height: geo.size.height - margin * 2)
            let fitted = aspectFit(model.displayImage?.size ?? CGSize(width: 1, height: 1), in: box)
            ZStack {
                if let image = model.displayImage {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: fitted.width, height: fitted.height)
                }
                CropOverlay(rect: $model.crop.rect, size: fitted, lockedAspect: model.cropLockedAspect)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

struct CropOverlay: View {
    @Binding var rect: CGRect
    let size: CGSize
    let lockedAspect: CGFloat?

    private enum Handle {
        case move, topLeft, topRight, bottomLeft, bottomRight, left, right, top, bottom
    }

    private struct DragStart {
        let handle: Handle?
        let rect: CGRect
    }

    @State private var start: DragStart?

    /// 手势区域比图片大一圈，这样贴边的角也抓得住。
    private let pad: CGFloat = 22
    private let minSide: CGFloat = 0.08

    var body: some View {
        let frame = CGRect(x: pad + rect.minX * size.width, y: pad + rect.minY * size.height,
                           width: rect.width * size.width, height: rect.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { p in
                p.addRect(CGRect(x: pad, y: pad, width: size.width, height: size.height))
                p.addRect(frame)
            }
            .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))

            Path { p in
                for i in 1...2 {
                    let x = frame.minX + frame.width * CGFloat(i) / 3
                    let y = frame.minY + frame.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: frame.minY))
                    p.addLine(to: CGPoint(x: x, y: frame.maxY))
                    p.move(to: CGPoint(x: frame.minX, y: y))
                    p.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)

            Path { p in p.addRect(frame) }
                .stroke(Color.white, lineWidth: 1)

            Path { p in
                let l: CGFloat = min(22, frame.width / 3, frame.height / 3)
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: frame.minX, y: frame.minY), 1, 1),
                    (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
                    (CGPoint(x: frame.minX, y: frame.maxY), 1, -1),
                    (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
                ]
                for (c, sx, sy) in corners {
                    p.move(to: CGPoint(x: c.x + sx * l, y: c.y))
                    p.addLine(to: c)
                    p.addLine(to: CGPoint(x: c.x, y: c.y + sy * l))
                }
            }
            .stroke(Color.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size.width + pad * 2, height: size.height + pad * 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if start == nil {
                        start = DragStart(handle: hitTest(value.startLocation, frame: frame), rect: rect)
                    }
                    guard let s = start, let handle = s.handle, size.width > 0, size.height > 0 else { return }
                    let dx = value.translation.width / size.width
                    let dy = value.translation.height / size.height
                    rect = updated(handle: handle, from: s.rect, dx: dx, dy: dy)
                }
                .onEnded { _ in start = nil }
        )
    }

    private func hitTest(_ p: CGPoint, frame: CGRect) -> Handle? {
        let corner: CGFloat = 34
        let edge: CGFloat = 24
        func near(_ a: CGPoint) -> Bool { hypot(p.x - a.x, p.y - a.y) < corner }
        if near(CGPoint(x: frame.minX, y: frame.minY)) { return .topLeft }
        if near(CGPoint(x: frame.maxX, y: frame.minY)) { return .topRight }
        if near(CGPoint(x: frame.minX, y: frame.maxY)) { return .bottomLeft }
        if near(CGPoint(x: frame.maxX, y: frame.maxY)) { return .bottomRight }
        if lockedAspect == nil {
            let inX = p.x > frame.minX && p.x < frame.maxX
            let inY = p.y > frame.minY && p.y < frame.maxY
            if inY && abs(p.x - frame.minX) < edge { return .left }
            if inY && abs(p.x - frame.maxX) < edge { return .right }
            if inX && abs(p.y - frame.minY) < edge { return .top }
            if inX && abs(p.y - frame.maxY) < edge { return .bottom }
        }
        return frame.contains(p) ? .move : nil
    }

    private func updated(handle: Handle, from s: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        if handle == .move {
            let x = min(max(0, s.minX + dx), 1 - s.width)
            let y = min(max(0, s.minY + dy), 1 - s.height)
            return CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        if let aspect = lockedAspect {
            return lockedCorner(handle: handle, from: s, dx: dx, dy: dy, aspect: aspect)
        }
        var x0 = s.minX, y0 = s.minY, x1 = s.maxX, y1 = s.maxY
        switch handle {
        case .left, .topLeft, .bottomLeft: x0 = min(max(0, x0 + dx), x1 - minSide)
        case .right, .topRight, .bottomRight: x1 = max(min(1, x1 + dx), x0 + minSide)
        default: break
        }
        switch handle {
        case .top, .topLeft, .topRight: y0 = min(max(0, y0 + dy), y1 - minSide)
        case .bottom, .bottomLeft, .bottomRight: y1 = max(min(1, y1 + dy), y0 + minSide)
        default: break
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// 锁定比例时拖角：对角固定不动，框按比例缩放。
    private func lockedCorner(handle: Handle, from s: CGRect, dx: CGFloat, dy: CGFloat, aspect: CGFloat) -> CGRect {
        let sx: CGFloat = (handle == .topRight || handle == .bottomRight) ? 1 : -1
        let sy: CGFloat = (handle == .bottomLeft || handle == .bottomRight) ? 1 : -1
        let ax = sx > 0 ? s.minX : s.maxX
        let ay = sy > 0 ? s.minY : s.maxY
        let maxW = sx > 0 ? 1 - ax : ax
        let maxH = sy > 0 ? 1 - ay : ay
        var w = max(s.width + sx * dx, (s.height + sy * dy) * aspect)
        w = min(w, maxW, maxH * aspect)
        w = max(w, minSide, minSide * aspect)
        w = min(w, maxW, maxH * aspect)
        let h = w / aspect
        return CGRect(x: sx > 0 ? ax : ax - w, y: sy > 0 ? ay : ay - h, width: w, height: h)
    }
}
