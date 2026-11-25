import SwiftUI

/// 点了一位大师：先看风格，选取景，点"开始生成"才发给 AI。
struct MasterCard: View {
    @Bindable var model: EditorModel
    let master: MasterInfo
    var start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let image = model.masterThumbs[master.title] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Platform.isMac ? 96 : 68, height: Platform.isMac ? 119 : 84)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(master.title).font(.system(size: 17, weight: .bold))
                    Text(master.note).font(.system(size: 12)).foregroundStyle(Theme.accent)
                    row("色彩", master.color)
                    row("光线", master.light)
                    row("构图", master.compose)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HScroll {
                HRow(spacing: 8) {
                    ForEach(master.frames) { frame in
                        Chip(title: frame.title, symbol: "viewfinder",
                             selected: model.aiMasterCompose && model.aiMasterFrame == frame.title) {
                            model.aiMasterCompose = true
                            model.aiMasterFrame = frame.title
                        }
                    }
                    Chip(title: "原构图", symbol: "rectangle", selected: !model.aiMasterCompose) { model.aiMasterCompose = false }
                }
            }
            if model.aiMasterCompose, let frame = master.frames.first(where: { $0.title == model.aiMasterFrame }) {
                Text(frame.person)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button { model.pickMaster(nil) } label: {
                    Label("换一位", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 42)
                        .background(Theme.chip, in: Theme.buttonShape)
                }
                .buttonStyle(.plain)
                Button(action: start) {
                    Text("开始生成")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Theme.accent, in: Theme.buttonShape)
                        .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
        .task { model.prepareMasterThumbs() }
    }

    private func row(_ name: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name).foregroundStyle(Theme.dim)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
    }
}
