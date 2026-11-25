import SwiftUI

/// 身体提亮：脸白身体暗的时候，把身体的皮肤调到和脸一致。
struct BodyTonePanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let state = model.bodyToneState
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HRow(spacing: 8) {
                    ForEach(BodyToneState.Mode.allCases) { mode in
                        Chip(title: mode.title, symbol: mode.symbol, selected: state.mode == mode) { model.setBodyToneMode(mode) }
                    }
                }
                if !Platform.isMac { Spacer(minLength: 0) }
            }
            HStack(spacing: 8) {
                Chip(title: "看范围", symbol: "eye", selected: state.showMask) { model.setBodyToneShowMask(!state.showMask) }
                    .fixedSize()
                if state.params.useColor {
                    Circle()
                        .fill(Color(red: Double(state.params.tone.x), green: Double(state.params.tone.y), blue: Double(state.params.tone.z)))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 1.5))
                }
                if state.busy { ProgressView().tint(.white) }
                Spacer(minLength: 0)
                round("arrow.uturn.backward") { model.bodyToneUndoStroke() }
                    .opacity(state.params.strokes.isEmpty ? 0.35 : 1)
                round("arrow.counterclockwise") { model.bodyToneReset() }
            }
            if model.bodyToneWantsStrokes {
                line("笔刷", nil) {
                    Slider(value: Binding(get: { Double(state.brush) }, set: { model.bodyToneState.brush = CGFloat($0) }), in: 12...120)
                }
            } else if state.params.useColor {
                line("范围", "\(Int((state.params.range * 100).rounded()))") {
                    Slider(value: Binding(get: { Double(state.params.range) }, set: { model.setBodyToneRange(CGFloat($0), editing: true) }),
                           in: 0...1) { editing in
                        model.setBodyToneRange(model.bodyToneState.params.range, editing: editing)
                    }
                }
            }
            let value = state.params[state.key]
            line(state.key.title, "\(Int((value * 100).rounded()))") {
                Slider(value: Binding(get: { Double(value) }, set: { model.setBodyTone(CGFloat($0)) }),
                       in: state.key.signed ? -1...1 : 0...1)
            }
            .disabled(state.key == .match && state.params.faceMean == nil)
            HScroll {
                HRow(spacing: 6) {
                    ForEach(BodyToneKey.allCases) { key in
                        IconTile(symbol: key.symbol, title: key.title, selected: state.key == key,
                                 modified: state.params[key] != 0) { model.bodyToneState.key = key }
                    }
                    IconTile(symbol: "sparkles", title: "AI 提亮", badge: "AI") {
                        model.startAIPreset(EditorModel.bodyTonePreset, group: .body)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            if let error = state.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func line(_ title: String, _ value: String?, @ViewBuilder slider: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.dim).frame(width: 56, alignment: .leading)
            slider()
            if let value {
                Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }

    private func round(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Theme.chip, in: Circle())
        }
        .buttonStyle(.plain)
    }
}
