import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.68, blue: 0.26)
    static let bg = Color.black
    static let panel = Color(white: 0.07)
    static let chip = Color(white: 0.16)
    static let dim = Color(white: 0.6)
}

/// 编辑器里的各个工具。
enum Tool: String, Hashable, Identifiable {
    case crop, filter, adjust, mosaic, text, sticker, ai, beauty, liquify
    case doodle, mark, frame, backdrop, collage, layers, reshape, makeup, skin, shape, effect, graphic, bodyTone, smartCrop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: return "裁剪"
        case .filter: return "滤镜"
        case .adjust: return "调色"
        case .mosaic: return "马赛克"
        case .text: return "文字"
        case .sticker: return "贴纸"
        case .ai: return "AI 修图"
        case .beauty: return "美颜"
        case .liquify: return "美体"
        case .doodle: return "涂鸦"
        case .mark: return "标记"
        case .frame: return "边框"
        case .backdrop: return "背景"
        case .collage: return "拼图"
        case .layers: return "图层"
        case .reshape: return "面部重塑"
        case .makeup: return "美妆"
        case .skin: return "皮肤"
        case .shape: return "塑形"
        case .bodyTone: return "身体提亮"
        case .smartCrop: return "智能构图"
        case .effect: return "特效"
        case .graphic: return "形状"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop.rotate"
        case .filter: return "camera.filters"
        case .adjust: return "slider.horizontal.3"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "t.square"
        case .sticker: return "face.smiling"
        case .ai: return "sparkles"
        case .beauty: return "face.smiling"
        case .liquify: return "hand.draw"
        case .doodle: return "scribble.variable"
        case .mark: return "arrow.up.right"
        case .frame: return "photo.artframe"
        case .backdrop: return "photo.on.rectangle"
        case .collage: return "rectangle.split.2x2"
        case .layers: return "square.3.layers.3d"
        case .reshape: return "face.dashed"
        case .makeup: return "paintbrush.pointed"
        case .skin: return "sparkle"
        case .shape: return "figure.arms.open"
        case .bodyTone: return "sun.max"
        case .smartCrop: return "viewfinder"
        case .effect: return "sparkles.rectangle.stack"
        case .graphic: return "square.on.circle"
        }
    }
}

func aspectFit(_ size: CGSize, in box: CGSize) -> CGSize {
    guard size.width > 0, size.height > 0, box.width > 0, box.height > 0 else { return .zero }
    let s = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * s, height: size.height * s)
}

/// 面板里的小标签按钮。symbol 不为空时前面带一个小图标。
struct Chip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    /// 右上角的小角标（比如 "AI"）。
    var badge: String? = nil
    var action: () -> Void

    var body: some View {
        if Platform.isMac {
            MacChip(title: title, symbol: symbol, selected: selected, badge: badge, action: action)
        } else {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    }
                    Text(title)
                        .font(.system(size: 14, weight: selected ? .semibold : .regular))
                }
                .foregroundStyle(selected ? Color.black : Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? Color.white : Theme.chip, in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if let badge { CornerBadge(text: badge).offset(x: 3, y: -5) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// Mac 上的标签：圆角方块，能拉满格子宽度；"AI"角标放在里面，不压到旁边的标签；鼠标移上去会亮一点。
private struct MacChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var badge: String?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                    // 放不下时先把字缩小，不用"…"截掉。
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
                if let badge {
                    Text(badge)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(selected ? Color.white : Color.black)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(selected ? Color.black.opacity(0.75) : Theme.accent, in: RoundedRectangle(cornerRadius: 3))
                }
            }
            .foregroundStyle(selected ? Color.black : Color.white)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(selected ? Color.white : (hovering ? Color(white: 0.24) : Theme.chip),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 按下去缩一点的按钮手感。
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 功能按钮：圆角方块里放图标，名字在下面。badge 是右上角的小角标（比如 "AI"）。
struct FeatureTile: View {
    let symbol: String
    let title: String
    var selected = false
    var badge: String? = nil
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(selected ? Color.black : Color.white)
                    .frame(width: 54, height: 54)
                    .background(selected ? Theme.accent : Theme.chip,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 5, y: -4)
                        }
                    }
                Text(title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 64)
        }
        .buttonStyle(PressStyle())
    }
}

/// 小角标：凡是会调用 AI 生成的按钮，右上角都带一个 "AI"。
struct CornerBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.black)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Theme.accent, in: Capsule())
    }
}

/// 图片按钮：一张缩略图，名字在下面。没有图时显示 symbol 占位。
struct ImageTile: View {
    let title: String
    let image: UIImage?
    var selected = false
    var symbol: String? = nil
    /// 右上角的小角标（比如 "AI"）。
    var badge: String? = nil
    var width: CGFloat = 68
    var height: CGFloat = 84
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color(white: 0.14)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.dim)
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5)
                )
                .overlay(alignment: .topTrailing) {
                    if let badge { CornerBadge(text: badge).padding(4) }
                }
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: width)
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// 一排等宽的分段标签：小图标 + 文字，选中的那格是白底。
struct SegmentBar<Item: Identifiable & Equatable>: View {
    let items: [Item]
    let selected: Item
    let title: (Item) -> String
    var symbol: ((Item) -> String)? = nil
    /// 放不下时改成可以左右滑，每格按内容宽度排。
    var scrolls = false
    var select: (Item) -> Void

    var body: some View {
        if scrolls, Platform.isMac {
            // Mac：不左右滑，放不下就换行，每个标签单独一个胶囊。
            FlowLayout(spacing: 6) {
                ForEach(items) { item in
                    let on = item == selected
                    Button { select(item) } label: {
                        HStack(spacing: 4) {
                            if let symbol {
                                Image(systemName: symbol(item)).font(.system(size: 12, weight: .semibold))
                            }
                            Text(title(item))
                                .font(.system(size: 13, weight: on ? .semibold : .regular))
                                .lineLimit(1)
                        }
                        .foregroundStyle(on ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(on ? Color.white : Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if scrolls {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    row.padding(3)
                }
                .background(Theme.chip, in: Capsule())
                .clipShape(Capsule())
                .onAppear { proxy.scrollTo(selected.id, anchor: .center) }
                .onChange(of: selected) { _, item in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(item.id, anchor: .center) }
                }
            }
        } else {
            row
                .padding(3)
                .background(Theme.chip, in: Capsule())
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item == selected
                Button { select(item) } label: {
                    HStack(spacing: 4) {
                        if let symbol {
                            Image(systemName: symbol(item)).font(.system(size: 12, weight: .semibold))
                        }
                        Text(title(item))
                            .font(.system(size: 14, weight: on ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(scrolls ? 1 : 0.8)
                    }
                    .foregroundStyle(on ? Color.black : Color.white)
                    .padding(.horizontal, scrolls ? 10 : 0)
                    .frame(maxWidth: scrolls ? nil : .infinity, minHeight: 32)
                    .background(on ? Color.white : Color.clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .id(item.id)
            }
        }
    }
}

/// 底部确认栏中间那种"文字 + 下划线"的标签（调色的 光效/色彩/细节/光影）。
struct UnderlineTabs<Item: Identifiable & Equatable>: View {
    let items: [Item]
    let selected: Item
    let title: (Item) -> String
    var select: (Item) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                let on = item == selected
                Button { select(item) } label: {
                    VStack(spacing: 5) {
                        Text(title(item))
                            .font(.system(size: 15, weight: on ? .bold : .regular))
                            .foregroundStyle(on ? Color.white : Theme.dim)
                        Capsule().fill(on ? Theme.accent : Color.clear).frame(width: 18, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 图标在上、文字在下的方块按钮。
struct IconTile: View {
    let symbol: String
    let title: String
    var selected = false
    var badge: String? = nil
    var modified = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol)
                        .font(.system(size: 22, weight: .regular))
                        .frame(width: 44, height: 30)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: 8, y: -2)
                    } else if modified {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6).offset(x: -4, y: 2)
                    }
                }
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(selected ? Theme.accent : Color.white)
            .frame(minWidth: 58)
        }
        .buttonStyle(.plain)
    }
}
