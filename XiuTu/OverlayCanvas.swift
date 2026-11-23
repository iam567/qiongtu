import SwiftUI

/// 文字和贴纸的编辑画布：拖动移动，双指或右下角手柄缩放旋转。
struct OverlayCanvas: View {
    @Bindable var model: EditorModel
    var onEditText: (UUID) -> Void

    @Environment(\.displayScale) private var screenScale
    /// 渲染好的位图。拖动、旋转时样子没变，就不用每一帧重画。
    @State private var cache = OverlayRenderCache()

    private static let space = "overlayCanvas"

    var body: some View {
        GeometryReader { geo in
            let box = CGSize(width: geo.size.width - 32, height: geo.size.height - 32)
            let fitted = aspectFit(model.displayImage?.size ?? CGSize(width: 1, height: 1), in: box)
            ZStack {
                ZStack {
                    if let image = model.displayImage {
                        Image(uiImage: image)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .onTapGesture { model.selectedOverlayID = nil }
                    }
                    ForEach(model.overlayItems) { item in
                        if let shown = rendered(item, fittedWidth: fitted.width) {
                            OverlayItemView(model: model, item: item, image: shown.image, size: shown.size,
                                            fitted: fitted, space: Self.space, onEditText: onEditText)
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipped()

                if let item = model.selectedOverlay, let shown = rendered(item, fittedWidth: fitted.width) {
                    SelectionChrome(model: model, item: item, size: shown.size, fitted: fitted, space: Self.space)
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .coordinateSpace(name: Self.space)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }

    /// 用和最终导出相同的绘制代码渲染，保证所见即所得。
    private func rendered(_ item: OverlayItem, fittedWidth: CGFloat) -> (image: UIImage, size: CGSize)? {
        guard let r = cache.render(item, imageWidth: fittedWidth * screenScale) else { return nil }
        let f = 1 / (screenScale * r.k)
        return (r.image, CGSize(width: r.image.size.width * f, height: r.image.size.height * f))
    }
}

/// 按"长什么样"缓存每一项的位图：位置和角度变了不用重画，样式、文字、大小变了才重画。
private final class OverlayRenderCache {
    private struct Entry {
        let look: OverlayItem
        let width: CGFloat
        let image: UIImage
        let k: CGFloat
    }

    private var entries: [UUID: Entry] = [:]

    func render(_ item: OverlayItem, imageWidth: CGFloat) -> (image: UIImage, k: CGFloat)? {
        let look = item.appearance
        if let hit = entries[item.id], hit.width == imageWidth, hit.look == look { return (hit.image, hit.k) }
        guard let r = OverlayRenderer.render(item, imageWidth: imageWidth, maxPixel: 3000) else {
            entries[item.id] = nil
            return nil
        }
        if entries.count > 60 { entries.removeAll() }
        entries[item.id] = Entry(look: look, width: imageWidth, image: r.image, k: r.k)
        return r
    }
}

private struct OverlayItemView: View {
    let model: EditorModel
    let item: OverlayItem
    let image: UIImage
    let size: CGSize
    let fitted: CGSize
    let space: String
    var onEditText: (UUID) -> Void

    @State private var dragStart: CGPoint?
    @State private var pinchStart: CGFloat?
    @State private var rotateStart: CGFloat?

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .rotationEffect(.radians(item.rotation))
            .onTapGesture(count: 2) {
                model.selectedOverlayID = item.id
                if !item.isSticker, !item.isImage { onEditText(item.id) }
            }
            .onTapGesture { model.selectedOverlayID = item.id }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(space))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = item.center
                            model.selectedOverlayID = item.id
                        }
                        guard let s = dragStart, fitted.width > 0, fitted.height > 0 else { return }
                        let x = s.x + value.translation.width / fitted.width
                        let y = s.y + value.translation.height / fitted.height
                        model.updateOverlay(item.id) {
                            $0.center = CGPoint(x: min(max(x, -0.1), 1.1), y: min(max(y, -0.1), 1.1))
                        }
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        if pinchStart == nil {
                            pinchStart = item.scale
                            model.selectedOverlayID = item.id
                        }
                        guard let s = pinchStart else { return }
                        model.updateOverlay(item.id) { $0.scale = min(max(s * value.magnification, 0.2), 10) }
                    }
                    .onEnded { _ in pinchStart = nil }
            )
            .simultaneousGesture(
                RotateGesture()
                    .onChanged { value in
                        if rotateStart == nil { rotateStart = item.rotation }
                        guard let s = rotateStart else { return }
                        model.updateOverlay(item.id) { $0.rotation = s + CGFloat(value.rotation.radians) }
                    }
                    .onEnded { _ in rotateStart = nil }
            )
            .position(x: item.center.x * fitted.width, y: item.center.y * fitted.height)
    }
}

/// 选中状态的虚线框，加上删除和缩放旋转两个手柄。
private struct SelectionChrome: View {
    let model: EditorModel
    let item: OverlayItem
    let size: CGSize
    let fitted: CGSize
    let space: String

    private struct HandleStart {
        let length: CGFloat
        let angle: CGFloat
        let scale: CGFloat
        let rotation: CGFloat
    }

    @State private var start: HandleStart?

    private struct EdgeStart {
        /// 拖之前框在拉的方向上有多长（屏幕点）。
        let length: CGFloat
        let center: CGPoint
        let fontSize: CGFloat
    }

    @State private var edgeStart: EdgeStart?

    /// 文字可以拉边改框的长度：横排拉右边改宽，竖排拉下边改高。
    private var canStretch: Bool { !item.isSticker && !item.isImage && !item.isGraphic }

    var body: some View {
        let center = CGPoint(x: item.center.x * fitted.width, y: item.center.y * fitted.height)
        ZStack {
            Rectangle()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .allowsHitTesting(false)
            handle("xmark")
                .onTapGesture { model.removeOverlay(item.id) }
                .offset(x: -size.width / 2, y: -size.height / 2)
            handle("plus.square.on.square")
                .onTapGesture { model.duplicateOverlay(item.id) }
                .offset(x: size.width / 2, y: -size.height / 2)
            handle("arrow.up.left.and.arrow.down.right")
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                        .onChanged { value in
                            if start == nil {
                                let v = CGPoint(x: value.startLocation.x - center.x, y: value.startLocation.y - center.y)
                                start = HandleStart(length: max(hypot(v.x, v.y), 1), angle: atan2(v.y, v.x),
                                                    scale: item.scale, rotation: item.rotation)
                            }
                            guard let s = start else { return }
                            let v = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                            let length = max(hypot(v.x, v.y), 1)
                            let angle = atan2(v.y, v.x)
                            model.updateOverlay(item.id) {
                                $0.scale = min(max(s.scale * length / s.length, 0.2), 10)
                                $0.rotation = s.rotation + angle - s.angle
                            }
                        }
                        .onEnded { _ in start = nil }
                )
                .offset(x: size.width / 2, y: size.height / 2)
            if canStretch {
                edgeHandle(center: center)
                    .offset(x: item.vertical ? 0 : size.width / 2, y: item.vertical ? size.height / 2 : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .rotationEffect(.radians(item.rotation))
        .position(center)
    }

    /// 拉边：拉的那条边跟着手走，对面那条边不动；字排满了自动换行（竖排换列）。
    private func edgeHandle(center: CGPoint) -> some View {
        Capsule()
            .fill(Color.white)
            .frame(width: item.vertical ? 26 : 8, height: item.vertical ? 8 : 26)
            .overlay(Capsule().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
            .contentShape(Rectangle().inset(by: -12))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        let fs = max(item.size * item.scale * fitted.width, 1)
                        if edgeStart == nil {
                            // 没拉过的框，从现在字实际占的长度开始拉。
                            var length = item.wrap * fs
                            if item.wrap <= 0, let layout = OverlayDrawing.layout(item, fontSize: fs) {
                                length = item.vertical ? layout.contentSize.height : layout.contentSize.width
                            }
                            edgeStart = EdgeStart(length: length, center: item.center, fontSize: fs)
                        }
                        guard let s = edgeStart, fitted.width > 0, fitted.height > 0 else { return }
                        // 拉的方向（跟着文字一起转）。
                        let r = item.rotation
                        let axis = item.vertical ? CGPoint(x: -sin(r), y: cos(r)) : CGPoint(x: cos(r), y: sin(r))
                        let d = value.translation.width * axis.x + value.translation.height * axis.y
                        let length = min(max(s.length + d, s.fontSize * 1.05), s.fontSize * 80)
                        let moved = (length - s.length) / 2
                        model.updateOverlay(item.id) {
                            $0.wrap = length / s.fontSize
                            $0.center = CGPoint(x: s.center.x + axis.x * moved / fitted.width,
                                                y: s.center.y + axis.y * moved / fitted.height)
                        }
                    }
                    .onEnded { _ in edgeStart = nil }
            )
    }

    private func handle(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 26, height: 26)
            .background(Color.white, in: Circle())
            .contentShape(Circle().inset(by: -8))
    }
}
