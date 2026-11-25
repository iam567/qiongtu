import SwiftUI

/// 一步一步走的流程：顶上是步骤条，底下是"上一步 / 下一步"。
/// 走过的步骤随时能点回去改；没走到的要按顺序一步步过去。
struct StepBar<Step: Identifiable & Equatable>: View {
    let steps: [Step]
    let current: Step
    /// 走到过的最远一步。
    let reached: Step
    let title: (Step) -> String
    var disabled = false
    var select: (Step) -> Void

    var body: some View {
        let reachedIndex = steps.firstIndex(of: reached) ?? 0
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { i, step in
                let isCurrent = step == current
                let open = i <= reachedIndex
                Button { if open { select(step) } } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? Theme.accent : (open ? Color.white.opacity(0.16) : Color.clear))
                                .overlay(Circle().stroke(open ? Color.clear : Color.white.opacity(0.25), lineWidth: 1))
                            if open && !isCurrent {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                            } else {
                                Text("\(i + 1)").font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(isCurrent ? Color.black : Theme.dim)
                            }
                        }
                        .frame(width: 20, height: 20)
                        Text(title(step))
                            .font(.system(size: 13, weight: isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? Color.white : (open ? Color.white.opacity(0.8) : Theme.dim))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!open || disabled)
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(i < reachedIndex ? Theme.accent.opacity(0.6) : Color.white.opacity(0.15))
                        .frame(width: 10, height: 1.5)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Theme.sheet)
    }
}

/// 底部的上一步 / 下一步。最后一步只留"上一步"（开始按钮在面板里）。
struct StepFooter: View {
    let isFirst: Bool
    let isLast: Bool
    var canAdvance = true
    var nextTitle = "下一步"
    var disabled = false
    var back: () -> Void
    var next: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if !isFirst {
                Button(action: back) {
                    Label("上一步", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
            }
            if !isLast {
                Button(action: next) {
                    HStack(spacing: 6) {
                        Text(nextTitle)
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(canAdvance ? Theme.accent : Theme.accent.opacity(0.35), in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                .disabled(!canAdvance)
            }
        }
        .disabled(disabled)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Theme.sheet)
    }
}
