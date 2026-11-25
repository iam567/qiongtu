import SwiftUI

/// 换衣服：点一款 → 选颜色、裙摆 → 点"开始换"才发给 AI。也可以照着一张图里的衣服换。
struct OutfitPanel: View {
    @Bindable var model: EditorModel
    var custom: () -> Void

    @State private var group = ""
    @State private var picking = false

    var body: some View {
        let male = GenderSetting.shared.isMale
        let groups = OutfitCatalog.groups(male: male)
        let current = groups.contains(group) ? group : groups.first ?? ""
        VStack(spacing: 10) {
            if let reference = model.outfitReference {
                referenceCard(reference)
            } else if let outfit = model.outfitPick {
                card(outfit)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    GenderToggle()
                    HScroll {
                        HRow(spacing: 8) {
                            ForEach(groups, id: \.self) { name in
                                Chip(title: name, selected: current == name) { group = name }
                            }
                        }
                    }
                }
                HScroll {
                    HRow(alignment: .top, spacing: 10) {
                        ForEach(OutfitCatalog.list(male: male).filter { $0.group == current }) { outfit in
                            tile(outfit.title, badge: "AI") {
                                OutfitArt(shape: outfit.shape, color: OutfitCatalog.color(outfit.colors.first ?? ""))
                            } action: { model.pickOutfit(outfit) }
                        }
                        tile("照着图换", badge: "AI") {
                            Image(systemName: "photo.badge.plus").font(.system(size: 24)).foregroundStyle(.white)
                        } action: { picking = true }
                        tile("自己写", badge: "AI") {
                            Image(systemName: "square.and.pencil").font(.system(size: 24)).foregroundStyle(.white)
                        } action: { custom() }
                    }
                    .padding(.vertical, 2)
                }
                .id(current + (male ? "m" : "f"))
            }
        }
        .imageSource(isPresented: $picking) { loaders in
            Task {
                guard let data = await loaders.first?(), let image = UIImage(data: data) else { return }
                model.outfitReference = AIOneShot.prepared(image, maxSide: 1400)
            }
        }
    }

    private func tile(_ title: String, badge: String, @ViewBuilder art: () -> some View, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color(white: 0.2)
                    art()
                }
                .frame(width: 68, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topTrailing) { CornerBadge(text: badge).padding(4) }
                Text(title).font(.system(size: 12)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.8).frame(width: 72)
            }
        }
        .buttonStyle(PressStyle())
    }

    private func card(_ outfit: Outfit) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Color(white: 0.2)
                    OutfitArt(shape: outfit.shape, color: OutfitCatalog.color(model.outfitColor))
                }
                .frame(width: 84, height: 104)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    Text(outfit.title).font(.system(size: 17, weight: .bold))
                    Text(outfit.prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HScroll {
                HRow(spacing: 8) {
                    ForEach(outfit.colors, id: \.self) { name in
                        SwatchChip(title: name, swatch: AnyShapeStyle(OutfitCatalog.color(name)), selected: model.outfitColor == name) {
                            model.outfitColor = name
                        }
                    }
                }
            }
            if outfit.skirt {
                HScroll {
                    HRow(spacing: 8) {
                        ForEach(OutfitSkirt.allCases) { skirt in
                            Chip(title: "裙摆 " + skirt.title, selected: model.outfitSkirt == skirt) { model.outfitSkirt = skirt }
                        }
                    }
                }
            }
            buttons { model.pickOutfit(nil) } start: {
                model.runOutfit(prompt: OutfitCatalog.prompt(outfit, color: model.outfitColor, skirt: model.outfitSkirt), title: outfit.title)
            }
        }
    }

    private func referenceCard(_ image: UIImage) -> some View {
        VStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxHeight: Platform.isMac ? 220 : 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            buttons { model.outfitReference = nil } start: {
                model.runOutfit(prompt: OutfitCatalog.referencePrompt, title: "照着图换")
            }
        }
    }

    private func buttons(back: @escaping () -> Void, start: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Label("换一款", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 42)
                    .background(Theme.chip, in: Theme.buttonShape)
            }
            .buttonStyle(.plain)
            Button(action: start) {
                Text("开始换")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 42)
                    .background(Theme.accent, in: Theme.buttonShape)
                    .overlay(alignment: .topTrailing) { CornerBadge(text: "AI").offset(x: -6, y: -5) }
            }
            .buttonStyle(.plain)
        }
    }
}
