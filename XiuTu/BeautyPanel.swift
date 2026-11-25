import SwiftUI

/// 当前服务商的小标签，点开可以在已经填了 Key 的几家之间快速切换。
struct ProviderMenu: View {
    var openSettings: () -> Void
    /// 紧凑模式只显示服务商名字，不显示型号。
    var compact = false
    /// 只显示一个齿轮图标（地方不够时用）。
    var iconOnly = false
    private let settings = AISettings.shared

    var body: some View {
        Menu {
            ForEach(AIProvider.allCases.filter { settings.isConfigured($0) }) { provider in
                Button {
                    settings.setActive(provider)
                } label: {
                    let name = "\(provider.shortTitle) · \(settings.config(provider).model)"
                    if settings.active == provider {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
            Divider()
            Button("AI 设置…", action: openSettings)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gearshape")
                if !iconOnly {
                    Text(settings.isConfigured(settings.active) && !compact
                         ? "\(settings.active.shortTitle) · \(settings.config(settings.active).model)"
                         : settings.active.shortTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .font(.system(size: iconOnly ? 16 : 12))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: iconOnly ? 30 : (compact ? 90 : 190), alignment: .trailing)
        }
    }
}

/// 出错时显示原因；如果还有别的服务商填了 Key，给出"换一家重试"的按钮。
struct AIErrorView: View {
    let model: EditorModel
    private let settings = AISettings.shared

    var body: some View {
        if let error = model.aiError, !model.aiRunning {
            VStack(alignment: .leading, spacing: 8) {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
                let others = AIProvider.allCases.filter { $0 != settings.active && settings.isConfigured($0) }
                if !others.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(others) { provider in
                            Button {
                                settings.setActive(provider)
                                model.retryAI()
                            } label: {
                                Text("换 \(provider.shortTitle) 重试")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 美颜面板：AI 美颜（只把脸部发给服务商）和手动美颜（全部在本机）。
struct BeautyPanel: View {
    @Bindable var model: EditorModel
    var openSettings: () -> Void

    private let settings = AISettings.shared

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                // Mac：一键美颜 / 手动美颜在左边的工具栏里选。
                if !Platform.isMac {
                    Chip(title: "AI 美颜", symbol: "sparkles", selected: model.beautyMode == .ai) { model.beautyMode = .ai }
                    Chip(title: "手动美颜", symbol: "slider.horizontal.3", selected: model.beautyMode == .manual) { model.beautyMode = .manual }
                }
                Spacer()
                if model.beautyMode == .ai { ProviderMenu(openSettings: openSettings, compact: true) }
            }
            AIErrorView(model: model)
            if model.detectingFaces {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在找人脸…").font(.system(size: 14))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
            } else if model.faces.isEmpty {
                FaceRescue(model: model, message: "这张图里没有找到人脸")
            } else {
                if model.faces.count > 1 { facePicker }
                if model.beautyMode == .ai { aiSection } else { manualSection }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var facePicker: some View {
        HScroll {
            HRow(spacing: 8) {
                Text("修哪张脸")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                ForEach(model.faces.indices, id: \.self) { index in
                    Chip(title: model.faceEdited(index) ? "第 \(index + 1) 张 ✓" : "第 \(index + 1) 张",
                         selected: model.faceIndex == index) { model.selectFace(index) }
                }
                Chip(title: "看全图", selected: false) { model.focusRect = nil }
            }
        }
    }

    // MARK: AI 美颜

    @ViewBuilder
    private var aiSection: some View {
        if !settings.isConfigured(settings.active) {
            VStack(spacing: 10) {
                Text("还没有设置 \(settings.active.shortTitle) 的 API Key").font(.system(size: 14))
                Button(action: openSettings) {
                    Text("去设置")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(Theme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else if model.aiRunning {
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(model.aiStarted)))
                    Text("\(model.beautyStyle ?? "")：\(settings.active.shortTitle) 正在处理… \(seconds) 秒")
                        .font(.system(size: 14))
                        .monospacedDigit()
                }
                Spacer()
                Button("取消") { model.cancelAI() }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.vertical, 22)
        } else {
            VStack(spacing: 10) {
                if model.aiHasResult {
                    HStack(spacing: 12) {
                        Text("强度")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.dim)
                        Slider(value: Binding(get: { Double(model.aiStrength) }, set: { model.setAIStrength(CGFloat($0)) }), in: 0...1)
                        Text("\(Int((model.aiStrength * 100).rounded()))")
                            .font(.system(size: 14, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                        Button { model.regenerateFaceAI() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                        }
                        .accessibilityLabel("重新生成这个风格")
                    }
                }
                HScroll {
                    HRow(spacing: 8) {
                        GenderToggle()
                        Chip(title: "原图", selected: !model.aiHasResult) { model.discardFaceAI() }
                        if FavoriteFaceStore.shared.current != nil {
                            Chip(title: model.isFaceStyleCached(.favorite) ? "满意脸型 ✓" : "满意脸型", symbol: "star.fill",
                                 selected: model.beautyStyle == BeautyStyle.favorite.id && model.aiHasResult, badge: "AI") {
                                model.runFavoriteFace()
                            }
                        }
                        ForEach(BeautyStyle.current) { style in
                            Chip(title: model.isFaceStyleCached(style) ? "\(style.title) ✓" : style.title,
                                 selected: model.beautyStyle == style.id && model.aiHasResult, badge: "AI") {
                                model.runFaceAI(style)
                            }
                        }
                    }
                    .padding(.top, 6)
                    .padding(.trailing, 6)
                }
                if let usage = model.aiUsageText, model.aiHasResult {
                    Text(usage)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: 手动美颜

    private var manualSection: some View {
        let key = model.beautyKey
        return VStack(spacing: 10) {
            HScroll {
                HRow(spacing: 8) {
                    Chip(title: "原图", selected: model.beauty.isIdentity) { model.applyBeautyPreset(nil) }
                    ForEach(BeautyPreset.all) { preset in
                        Chip(title: preset.title, selected: model.beautyPreset == preset.id) {
                            model.applyBeautyPreset(preset)
                        }
                    }
                }
            }
            HStack(spacing: 12) {
                Text("\(Int((model.beauty[key] * 100).rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .leading)
                Slider(value: Binding(get: { Double(model.beauty[key]) }, set: { model.setBeauty(key, CGFloat($0)) }), in: 0...1)
                if key == .lips {
                    HStack(spacing: 6) {
                        ForEach(BeautyParams.lipColors.indices, id: \.self) { index in
                            Button { model.setLipColor(index) } label: {
                                Circle()
                                    .fill(Color(uiColor: BeautyParams.lipColors[index].color))
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(model.beauty.lipColor == index ? Color.white : Color.clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(BeautyParams.lipColors[index].name)
                        }
                    }
                }
            }
            HStack(spacing: 2) {
                ForEach(BeautyKey.allCases) { item in
                    IconTile(symbol: item.symbol, title: item.title, selected: item == key,
                             modified: model.beauty[item] > 0) {
                        model.beautyKey = item
                    }
                }
            }
        }
    }
}
