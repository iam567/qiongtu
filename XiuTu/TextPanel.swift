import SwiftUI
import UniformTypeIdentifiers

// MARK: - 文字

/// 文字面板：上面一排是"加文字"和各类设置的标签，下面是当前标签的内容。面板上不放说明文字，只在出错时显示原因。
/// 所有设置都作用在画面上选中的那段文字上，可以随意组合（描边 + 阴影 + 底色 + 发光都能同时开）。
struct TextPanel: View {
    @Bindable var model: EditorModel
    var onAdd: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case preset, font, color, stroke, shadow, box, glow, layout

        var id: String { rawValue }

        var title: String {
            switch self {
            case .preset: return "花字"
            case .font: return "字体"
            case .color: return "颜色"
            case .stroke: return "描边"
            case .shadow: return "阴影"
            case .box: return "底色"
            case .glow: return "发光"
            case .layout: return "排版"
            }
        }
    }

    @State private var tab: Tab = .preset
    @State private var fontCategory: FontCategory = .common
    @State private var importing = false
    @Environment(\.displayScale) private var screenScale

    private let fonts = FontStore.shared

    private static let fontTypes: [UTType] = {
        var types: [UTType] = [.font]
        for ext in ["ttf", "otf", "ttc", "otc"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) { types.append(type) }
        }
        return types
    }()

    var body: some View {
        let selected = model.selectedOverlay.flatMap { $0.isSticker ? nil : $0 }
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: onAdd) {
                    Label("文字", systemImage: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                HScroll {
                    HRow(spacing: 18) {
                        ForEach(Tab.allCases) { item in tabButton(item) }
                    }
                    .padding(.trailing, 8)
                }
            }
            Group {
                if let selected {
                    content(selected)
                } else {
                    Text("先加一段文字")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 128, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.fontTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            if let font = fonts.importFonts(from: urls) {
                fontCategory = .mine
                change { $0.fontID = font.id }
            }
        }
    }

    private func tabButton(_ item: Tab) -> some View {
        let on = tab == item
        return Button { tab = item } label: {
            VStack(spacing: 4) {
                Text(item.title)
                    .font(.system(size: 15, weight: on ? .bold : .regular))
                    .foregroundStyle(on ? Color.white : Theme.dim)
                Capsule().fill(on ? Theme.accent : Color.clear).frame(width: 16, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func change(_ body: (inout OverlayItem) -> Void) {
        guard let id = model.selectedOverlayID else { return }
        model.updateOverlay(id, body)
    }

    @ViewBuilder
    private func content(_ item: OverlayItem) -> some View {
        switch tab {
        case .preset: presets(item)
        case .font: fontPicker(item)
        case .color:
            VStack(spacing: 12) {
                OverlayColorRow(selected: item.color) { color in
                    if let color { change { $0.color = color } }
                }
                MiniSlider(title: "不透明度", value: item.opacity, range: 0.1...1, labelWidth: 56) { v in change { $0.opacity = v } }
            }
        case .stroke:
            VStack(spacing: 12) {
                OverlayColorRow(selected: item.strokeOn ? item.strokeColor : nil, allowsNone: true) { color in
                    change {
                        if let color {
                            $0.strokeOn = true
                            $0.strokeColor = color
                        } else {
                            $0.strokeOn = false
                        }
                    }
                }
                MiniSlider(title: "粗细", value: item.strokeWidth, range: 0.05...1) { v in
                    change {
                        $0.strokeOn = true
                        $0.strokeWidth = v
                    }
                }
            }
        case .shadow:
            VStack(spacing: 10) {
                OverlayColorRow(selected: item.shadowOn ? item.shadowColor : nil, allowsNone: true) { color in
                    change {
                        if let color {
                            $0.shadowOn = true
                            $0.shadowColor = color
                        } else {
                            $0.shadowOn = false
                        }
                    }
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "虚实", value: item.shadowBlur, range: 0...1) { v in change { $0.shadowOn = true; $0.shadowBlur = v } }
                    MiniSlider(title: "距离", value: item.shadowDistance, range: 0...1) { v in change { $0.shadowOn = true; $0.shadowDistance = v } }
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "角度", value: item.shadowAngle, range: 0...360) { v in change { $0.shadowOn = true; $0.shadowAngle = v } }
                    MiniSlider(title: "浓度", value: item.shadowOpacity, range: 0.1...1) { v in change { $0.shadowOn = true; $0.shadowOpacity = v } }
                }
            }
        case .box:
            VStack(spacing: 8) {
                OverlayColorRow(selected: item.boxOn ? item.boxColor : nil, allowsNone: true) { color in
                    change {
                        if let color {
                            $0.boxOn = true
                            $0.boxColor = color
                        } else {
                            $0.boxOn = false
                        }
                    }
                }
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(OverlayShape.allCases) { shape in shapeTile(shape, item: item) }
                    }
                    .padding(.vertical, 1)
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "浓度", value: item.boxOpacity, range: 0.1...1) { v in change { $0.boxOn = true; $0.boxOpacity = v } }
                    MiniSlider(title: "留白", value: item.boxPadding, range: 0...1) { v in change { $0.boxOn = true; $0.boxPadding = v } }
                }
            }
        case .glow:
            VStack(spacing: 12) {
                OverlayColorRow(selected: item.glowOn ? item.glowColor : nil, allowsNone: true) { color in
                    change {
                        if let color {
                            $0.glowOn = true
                            $0.glowColor = color
                        } else {
                            $0.glowOn = false
                        }
                    }
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "大小", value: item.glowSize, range: 0...1) { v in change { $0.glowOn = true; $0.glowSize = v } }
                    MiniSlider(title: "强度", value: item.glowStrength, range: 0...1) { v in change { $0.glowOn = true; $0.glowStrength = v } }
                }
            }
        case .layout:
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    textToggle("竖排", on: item.vertical) {
                        change {
                            $0.vertical.toggle()
                            // 框拉过的长度横竖不通用，换方向就重来；竖排一列太长的，先按一列 8 个字排。
                            let longest = $0.text.split(separator: "\n").map(\.count).max() ?? 0
                            $0.wrap = $0.vertical && longest > 10 ? 8.3 : 0
                        }
                    }
                    Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
                    ForEach(OverlayAlign.allCases) { align in
                        toggle(align.symbol, on: item.align == align) { change { $0.align = align } }
                    }
                    Rectangle().fill(Theme.chip).frame(width: 1, height: 20)
                    toggle("bold", on: item.bold) { change { $0.bold.toggle() } }
                    toggle("italic", on: item.italic) { change { $0.italic.toggle() } }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    MiniSlider(title: "字距", value: item.letterSpacing, range: -0.05...0.8) { v in
                        change { $0.letterSpacing = abs(v) < 0.02 ? 0 : v }
                    }
                    MiniSlider(title: "行距", value: item.lineSpacing, range: -0.2...1) { v in
                        change { $0.lineSpacing = abs(v) < 0.03 ? 0 : v }
                    }
                }
                MiniSlider(title: "大小", value: item.scale, range: 0.3...5) { v in change { $0.scale = v } }
            }
        }
    }

    /// 和 toggle 一样大的开关，但写字（"竖排"用图标说不清）。
    private func textToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 50, height: 34)
                .background(on ? Color.white : Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ symbol: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 44, height: 34)
                .background(on ? Color.white : Theme.chip, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: 花字

    private func presets(_ item: OverlayItem) -> some View {
        HScroll {
            HRow(alignment: .top, spacing: 10) {
                ForEach(OverlayPreset.all) { preset in
                    Button {
                        change { $0 = preset.applied(to: $0) }
                    } label: {
                        VStack(spacing: 6) {
                            thumb(key: "preset-\(preset.id)-\(item.fontID)-\(item.bold)-\(item.italic)", width: 72, height: 60) {
                                var sample = OverlayItem(text: "字")
                                sample.fontID = item.fontID
                                sample.bold = item.bold
                                sample.italic = item.italic
                                return preset.applied(to: sample)
                            }
                            Text(preset.title)
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, Platform.isMac ? 0 : -16)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }

    /// 用真正的绘制代码画一个小样。
    private func thumb(key: String, width: CGFloat, height: CGFloat, selected: Bool = false,
                       fontSize: CGFloat = 30, make: () -> OverlayItem) -> some View {
        let image = OverlayThumbs.image(key: "\(key)-\(fontSize)", fontSize: fontSize * screenScale, make: make)
        return ZStack {
            Color(white: 0.3)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(width - 6, image.size.width / screenScale),
                           height: min(height - 6, image.size.height / screenScale))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2)
        )
    }

    private func shapeTile(_ shape: OverlayShape, item: OverlayItem) -> some View {
        let on = item.boxOn && item.boxShape == shape
        return Button {
            change {
                $0.boxOn = true
                $0.boxShape = shape
            }
        } label: {
            thumb(key: "shape-\(shape.rawValue)", width: 54, height: 36, selected: on, fontSize: 15) {
                var sample = OverlayItem(text: "字")
                sample.color = .black
                sample.boxOn = true
                sample.boxColor = .white
                sample.boxShape = shape
                return sample
            }
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(shape.title)
    }

    // MARK: 字体

    private func fontPicker(_ item: OverlayItem) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(FontCategory.allCases) { category in
                    Button { fontCategory = category } label: {
                        Text(category.title)
                            .font(.system(size: 13, weight: fontCategory == category ? .semibold : .regular))
                            .foregroundStyle(fontCategory == category ? Theme.accent : Color.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Theme.chip.opacity(fontCategory == category ? 1 : 0), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            HScroll {
                HRow(spacing: 8) {
                    if fontCategory == .mine {
                        Chip(title: "导入字体", symbol: "square.and.arrow.down", selected: false) { importing = true }
                    }
                    ForEach(fonts.fonts(in: fontCategory)) { choice in fontChip(choice, item: item) }
                }
            }
            .padding(.horizontal, Platform.isMac ? 0 : -16)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            // 只在出错时显示一行原因（导入失败、下载失败）。
            if let problem = fonts.note {
                Text(problem)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func fontChip(_ choice: FontChoice, item: OverlayItem) -> some View {
        let on = item.fontID == choice.id
        let ready = fonts.isReady(choice)
        let progress = fonts.downloading[choice.id]
        return Button { pick(choice) } label: {
            HStack(spacing: 5) {
                Text(choice.title)
                    .font(ready ? Font(OverlayFonts.ctFont(id: choice.id, size: 15)) : .system(size: 14))
                    .lineLimit(1)
                if let progress {
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.system(size: 11))
                        .monospacedDigit()
                } else if !ready {
                    Image(systemName: "arrow.down.circle").font(.system(size: 12))
                }
            }
            .foregroundStyle(on ? Color.black : Color.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(on ? Color.white : Theme.chip, in: Capsule())
            .clipped()
        }
        .buttonStyle(.plain)
        .contextMenu {
            if choice.kind == .custom {
                Button("删除这款字体", role: .destructive) { fonts.delete(choice) }
            }
        }
    }

    private func pick(_ choice: FontChoice) {
        fonts.note = nil
        if fonts.isReady(choice) {
            change { $0.fontID = choice.id }
            return
        }
        let target = model.selectedOverlayID
        fonts.download(choice) { ok in
            // 下载期间如果换了别的文字，就不动它了。
            guard ok, let target, model.selectedOverlayID == target else { return }
            model.updateOverlay(target) { $0.fontID = choice.id }
        }
    }
}

// MARK: - 小部件

/// 一排颜色：最前面是"自定义颜色"（系统调色盘），allowsNone 时再前面多一个"关掉"。
struct OverlayColorRow: View {
    let selected: OverlayColor?
    var allowsNone = false
    var onPick: (OverlayColor?) -> Void

    var body: some View {
        HScroll {
            HRow(spacing: 10) {
                if allowsNone {
                    Button { onPick(nil) } label: {
                        Image(systemName: "nosign")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(selected == nil ? Theme.accent : Theme.dim)
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关掉")
                }
                ColorPicker("自定义颜色", selection: Binding(
                    get: { Color(uiColor: (selected ?? .white).uiColor) },
                    set: { onPick(OverlayColor(UIColor($0))) }
                ), supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32, height: 32)
                ForEach(OverlayColor.palette, id: \.self) { color in
                    Button { onPick(color) } label: {
                        Circle()
                            .fill(Color(uiColor: color.uiColor))
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                            .padding(3)
                            .overlay(Circle().stroke(selected == color ? Theme.accent : Color.clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
        .padding(.horizontal, Platform.isMac ? 0 : -16)
        .contentMargins(.horizontal, 16, for: .scrollContent)
    }
}

/// 带名字的小滑块。两个并排放正好一行。
struct MiniSlider: View {
    let title: String
    let value: CGFloat
    let range: ClosedRange<CGFloat>
    var labelWidth: CGFloat = 30
    var onChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
                .frame(width: labelWidth, alignment: .leading)
            Slider(value: Binding(
                get: { Double(min(max(value, range.lowerBound), range.upperBound)) },
                set: { onChange(CGFloat($0)) }
            ), in: Double(range.lowerBound)...Double(range.upperBound))
        }
    }
}

/// 面板上各种小样的缓存。
@MainActor
enum OverlayThumbs {
    private static var cache: [String: UIImage] = [:]

    static func image(key: String, fontSize: CGFloat, make: () -> OverlayItem) -> UIImage? {
        if let hit = cache[key] { return hit }
        guard let image = OverlayRenderer.thumbnail(make(), fontSize: fontSize) else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
