import SwiftUI
import UIKit

/// 美妆面板：小分类 + 浓淡滑块 + 一排预设。上妆全部在本机完成，美甲和装饰交给 AI。
struct MakeupPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.makeupState
        VStack(spacing: 10) {
            if state.category.isLocal, state.detecting {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在找人脸…").font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 44)
            } else if state.category.isLocal, state.faces.isEmpty {
                FaceRescue(model: model, message: state.unreliable ? "这张脸太小或者太侧，五官定位不准" : "这张图里没有找到人脸")
            } else {
                header(state)
                if state.category.isLocal { slider }
                options(state)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: 小分类 + 选脸

    @ViewBuilder
    private func header(_ state: MakeupState) -> some View {
        let tabs = state.category.tabs
        if !tabs.isEmpty || (state.category.isLocal && state.faces.count > 1) || state.category == .look {
            HStack(spacing: 10) {
                if state.category == .look { GenderToggle() }
                HScroll {
                    HRow(spacing: 18) {
                        ForEach(tabs.indices, id: \.self) { index in
                            let on = state.tab == index
                            Button { model.setMakeupTab(index) } label: {
                                Text(tabs[index])
                                    .font(.system(size: 14, weight: on ? .semibold : .regular))
                                    .foregroundStyle(on ? Color.white : Theme.dim)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if state.category.isLocal, state.faces.count > 1 {
                    Menu {
                        ForEach(state.faces.indices, id: \.self) { index in
                            Button {
                                model.selectMakeupFace(index)
                            } label: {
                                if index == state.faceIndex {
                                    Label("第 \(index + 1) 张脸", systemImage: "checkmark")
                                } else {
                                    Text("第 \(index + 1) 张脸")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "person.crop.circle")
                            Text("\(state.faceIndex + 1)/\(state.faces.count)").monospacedDigit()
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.chip, in: Capsule())
                    }
                }
            }
        }
    }

    // MARK: 浓淡

    private var slider: some View {
        let amount = model.makeupAmount
        return HStack(spacing: 12) {
            Text("\(Int(((amount ?? 0) * 100).rounded()))")
                .font(.system(size: 15, weight: .semibold))
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
            Slider(value: Binding(get: { Double(amount ?? 0) }, set: { model.setMakeupAmount(CGFloat($0)) }), in: 0...1)
        }
        .opacity(amount == nil ? 0.3 : 1)
        .disabled(amount == nil)
    }

    // MARK: 一排选项

    private func options(_ state: MakeupState) -> some View {
        let built = model.makeupOptions()
        let listKey = "\(state.session)|\(state.faceIndex)|\(state.category.rawValue)|\(state.tab)"
        return HScroll {
            HRow(alignment: .top, spacing: 8) {
                if let custom = model.makeupCustomColor {
                    CustomColorTile(color: custom) { model.setMakeupCustomColor($0) }
                }
                ForEach(built.list) { option in
                    tile(option, state)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .padding(.horizontal, -16)
        .id(listKey)
        .task(id: listKey) {
            model.prepareMakeupThumbs(built.list, crop: built.crop)
        }
    }

    @ViewBuilder
    private func tile(_ option: MakeupOption, _ state: MakeupState) -> some View {
        switch option.kind {
        case .thumb:
            ImageTile(title: option.title, image: state.thumbs[model.makeupThumbKey(option)], selected: option.selected,
                      width: 62, height: 62) { model.chooseMakeup(option) }
        case .swatch(let color):
            SwatchTile(title: option.title, color: color, selected: option.selected) { model.chooseMakeup(option) }
        case .symbol(let symbol):
            FeatureTile(symbol: symbol, title: option.title, selected: option.selected) { model.chooseMakeup(option) }
        case .ai(let preset):
            FeatureTile(symbol: preset.symbol, title: option.title, badge: "AI") { model.chooseMakeup(option) }
        }
    }
}

/// 一个圆形色块，名字在下面。
private struct SwatchTile: View {
    let title: String
    let color: MakeupColor
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(red: color.r, green: color.g, blue: color.b))
                    .frame(width: 46, height: 46)
                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .padding(4)
                    .overlay(Circle().stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5))
                    .frame(width: 62, height: 62)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.accent : Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: 62)
            }
        }
        .buttonStyle(PressStyle())
    }
}

/// 自己挑颜色。
private struct CustomColorTile: View {
    let color: MakeupColor
    var change: (MakeupColor) -> Void

    var body: some View {
        VStack(spacing: 6) {
            ColorPicker("", selection: Binding(
                get: { Color(red: color.r, green: color.g, blue: color.b) },
                set: { picked in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    UIColor(picked).getRed(&r, green: &g, blue: &b, alpha: &a)
                    change(MakeupColor(min(max(r, 0), 1), min(max(g, 0), 1), min(max(b, 0), 1)))
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .scaleEffect(1.5)
            .frame(width: 62, height: 62)
            Text("自选")
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .frame(width: 62)
        }
    }
}

/// 美妆时底部确认栏（✕ 和 ✓ 之间）显示的内容：妆容 / 口红 / 眉毛 …… 这些大类，可以左右滑。
struct MakeupTitle: View {
    @Bindable var model: EditorModel

    var body: some View {
        let selected = model.makeupState.category
        ScrollViewReader { proxy in
            HScroll {
                HRow(spacing: 20) {
                    ForEach(MakeupCategory.allCases) { category in
                        let on = category == selected
                        Button {
                            model.setMakeupCategory(category)
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(category.id, anchor: .center) }
                        } label: {
                            VStack(spacing: 5) {
                                Text(category.title)
                                    .font(.system(size: 15, weight: on ? .bold : .regular))
                                    .foregroundStyle(on ? Color.white : Theme.dim)
                                Capsule().fill(on ? Theme.accent : Color.clear).frame(width: 18, height: 3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(category.id)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
