import SwiftUI

/// 智能构图的画布：整张照片上画出找到的取景，选中的那个可以拖、可以改大小。
struct SmartCropCanvas: View {
    @Bindable var model: EditorModel

    private let margin: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let box = CGSize(width: geo.size.width - margin * 2, height: geo.size.height - margin * 2)
            let image = model.baseUIImage
            let fitted = aspectFit(image?.size ?? CGSize(width: 1, height: 1), in: box)
            let state = model.smartCropState
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().frame(width: fitted.width, height: fitted.height)
                }
                if state.current != nil {
                    CropOverlay(rect: $model.smartCropRect, size: fitted, lockedAspect: model.smartCropLocked)
                }
                // 没选中的取景：细框加序号，点一下选它。
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                        if item.id != state.selected {
                            Rectangle()
                                .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .frame(width: item.rect.width * fitted.width, height: item.rect.height * fitted.height)
                                .allowsHitTesting(false)
                                .overlay(alignment: .topLeading) {
                                    Button { model.smartCropState.selected = item.id } label: {
                                        Text("\(i + 1)")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.black)
                                            .frame(width: 24, height: 24)
                                            .background(Theme.accent, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .padding(4)
                                }
                                .offset(x: item.rect.minX * fitted.width, y: item.rect.minY * fitted.height)
                        }
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// 智能构图面板：点"开始分析"，AI 找出几个取景；选一个应用，或者全部存下来。
struct SmartCropPanel: View {
    @Bindable var model: EditorModel
    var openSettings: () -> Void

    @State private var exports: [MacExport] = []
    private let settings = AISettings.shared

    var body: some View {
        let state = model.smartCropState
        VStack(spacing: 12) {
            HStack {
                Spacer(minLength: 0)
                ProviderMenu(openSettings: openSettings, compact: true)
            }
            if !settings.isConfigured(settings.active), state.items.isEmpty {
                NeedsKeyView(openSettings: openSettings)
            } else if state.running {
                HStack(spacing: 12) {
                    ProgressView().tint(.white)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = max(0, Int(context.date.timeIntervalSince(state.started)))
                        Text("\(settings.active.shortTitle) 正在看图找取景… \(seconds) 秒")
                            .font(.system(size: 14))
                            .monospacedDigit()
                    }
                    Spacer()
                    Button("取消") { model.cancelSmartCrop() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.vertical, 22)
            } else if state.items.isEmpty {
                mainButton("开始分析") { model.runSmartCrop() }
            } else {
                results
            }
            if let usage = state.usage {
                Text(usage)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let note = state.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity, alignment: .leading)
            }
            AIFailureView(message: state.error) { model.runSmartCrop() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .macExport($exports) { count in model.smartCropState.note = "已导出 \(count) 张" }
    }

    private var results: some View {
        let state = model.smartCropState
        return VStack(spacing: 12) {
            HScroll {
                HRow(spacing: 8) {
                    ForEach(SmartCropRatio.allCases) { ratio in
                        Chip(title: ratio.title, selected: state.ratio == ratio) { model.setSmartCropRatio(ratio) }
                    }
                }
            }
            HScroll {
                HRow(alignment: .top, spacing: 10) {
                    ForEach(Array(state.items.enumerated()), id: \.element.id) { i, item in
                        let selected = item.id == state.selected
                        Button { model.smartCropState.selected = item.id } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    Color(white: 0.1)
                                    if let image = model.smartCropThumb(item) {
                                        Image(uiImage: image).resizable().scaledToFit()
                                    }
                                }
                                .frame(width: Platform.isMac ? 100 : 84, height: Platform.isMac ? 100 : 84)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selected ? Theme.accent : Color.clear, lineWidth: 2.5))
                                .overlay(alignment: .topLeading) {
                                    Text("\(i + 1)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                        .frame(width: 19, height: 19)
                                        .background(Theme.accent, in: Circle())
                                        .padding(4)
                                }
                                Text(item.title)
                                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                                    .foregroundStyle(selected ? Theme.accent : Color.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                    .frame(width: Platform.isMac ? 100 : 84)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
            if let current = state.current, !current.how.isEmpty || !current.why.isEmpty {
                Text([current.how, current.why].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { saveAll() } label: {
                    Text(state.saving ? "正在处理…" : (Platform.isMac ? "全部导出" : "全部保存"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                .disabled(state.saving)
                mainButton("再找一组") { model.runSmartCrop() }
            }
        }
    }

    private func mainButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "viewfinder")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(Theme.accent, in: Theme.buttonShape)
                .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
        }
        .buttonStyle(.plain)
    }

    private func saveAll() {
        guard Platform.isMac else {
            model.saveSmartCrops()
            return
        }
        model.smartCropState.saving = true
        Task {
            let list = await model.smartCropImages()
            model.smartCropState.saving = false
            exports = list.enumerated().map { MacExport(data: $1.data, name: "智能构图-\($0 + 1)-\($1.title)", source: "智能构图") }
        }
    }
}
