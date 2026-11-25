import SwiftUI

/// 换衣服的一种款式（outfits.json，iOS 和安卓共用，由 tools/make_outfits.py 生成）。
struct Outfit: Decodable, Identifiable {
    let group: String
    let title: String
    /// 小图的剪影。
    let shape: String
    let prompt: String
    /// 推荐颜色，第一个是默认的。
    let colors: [String]
    /// 有没有裙摆可以选。
    let skirt: Bool
    let male: Bool
    var id: String { (male ? "m" : "f") + title }
}

enum OutfitSkirt: String, CaseIterable, Identifiable {
    case normal, train, overflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: return "正常"
        case .train: return "拖尾"
        case .overflow: return "溢出画面"
        }
    }

    var prompt: String {
        switch self {
        case .normal: return ""
        case .train: return "裙摆在身后拖出长长的一段，自然铺在地上。"
        case .overflow:
            return "裙摆做得极大，朝镜头方向铺开，占满画面下方三分之一到一半，从画面的左右两边和下边溢出去，近大远小，近处的布料褶皱和装饰清晰巨大，有强烈的视觉冲击；裙摆自然盖在地面和近处的东西上。"
        }
    }
}

enum OutfitCatalog {
    private struct File: Decodable {
        let colors: [String: String]
        let outfits: [Outfit]
    }

    private static let file: File? = {
        guard let url = Bundle.main.url(forResource: "outfits", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(File.self, from: data)
    }()

    static let all: [Outfit] = file?.outfits ?? []

    static func list(male: Bool) -> [Outfit] { all.filter { $0.male == male } }

    static func groups(male: Bool) -> [String] {
        list(male: male).reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } }
    }

    static func color(_ name: String) -> Color {
        guard let hex = file?.colors[name], let v = UInt32(hex, radix: 16) else { return .gray }
        return Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }

    /// 除了衣服什么都不许动。
    static let clean = "原来那身衣服要完全脱掉、一点都不留：领子、领口、脖子周围、肩膀、袖子、袖口、扣子、腰带、下摆全部换成新衣服的样子，" +
        "不能新旧衣服混在一起，不能把旧领子或里面的衣服留在脖子上。新衣服的领口、肩线、袖子要完整清楚；按新款式该露出的脖子、锁骨、肩膀和手臂露出自然的皮肤，肤色和脸、脖子连贯一致；" +
        "垂在胸前的头发仍然盖在新衣服上面。"

    static let hairClean = "原来的头发要完全换掉：比新发型长的、垂在肩上、胸前、背后、手臂和袖子旁边的，以及飘在空中的零碎发丝和发梢全部去掉，一根都不留；" +
        "露出来的脖子、肩膀、衣服和背景按原来的样子补全。"
    static let hairKeep = "只动头发：脸、五官、表情、妆、头饰、耳饰、衣服、手、姿势和背景完全不变，不要移动、裁剪、缩放画面，不要改光线和色调，不要加光斑。"

    static let keep = "只换衣服（包括和它配套的鞋子），其余全部和原照片逐像素一样：人物的脸、表情、妆、发型、头饰、肤色、身材、姿势、手的位置和手里的东西都不变，还是同一个人；" +
        "背景、天空、云、建筑、地面、光线、色调和构图完全不变，不要加光斑、光晕、云、花瓣或任何新东西，不要移动、裁剪、缩放画面。" +
        "衣服要像真的穿在身上：合身，布料的厚薄、垂坠、褶皱和姿势一致，受光方向、明暗、影子和现场一致，和地面、栏杆接触的地方有自然的遮挡和投影，手和头发挡在前面的地方仍然挡在前面。" +
        "布料要有真实的织纹和细节，像真实照片，不要绘画感、塑料感和发光感。"

    static func prompt(_ outfit: Outfit, color: String, skirt: OutfitSkirt) -> String {
        "把画面里主要人物的衣服换成：\(outfit.prompt)。颜色是\(color)。\(outfit.skirt ? skirt.prompt : "")" + clean + keep
    }

    /// 照着另一张图里的衣服换。
    static let referencePrompt = "第二张图是衣服的参考。把第一张图里主要人物的衣服换成第二张图里的那身衣服：款式、颜色、图案、面料和细节都照着它来，" +
        "但不要把第二张图里的人、脸、姿势或背景搬过来。" + clean + keep
}

extension OutfitCatalog {
    /// 没换干净的地方：涂抹以后只补这一块。
    static let patchPrompt = "涂抹区域里还留着旧衣服。把涂抹区域换成和这个人身上现在这件衣服一致的样子：领口、肩线、布料、颜色和花纹都接得上；" +
        "按现在这件衣服的款式该露出皮肤的地方就露出自然的皮肤，肤色和脸、脖子连贯一致。旧衣服的领子、扣子和颜色一点都不留。垂下来的头发和首饰保留。"
}

extension AIIntent {
    /// 自己写的指令是不是在换衣服：是的话背景一律用原图。
    static func changesClothes(_ prompt: String) -> Bool {
        let wear = ["衣服", "裙", "礼服", "婚纱", "西装", "外套", "旗袍", "和服", "汉服", "上衣", "裤", "大衣", "衬衫", "制服", "穿搭", "换装", "穿着"]
        let verbs = ["换", "改成", "变成", "穿上", "换装", "穿成"]
        return wear.contains { prompt.contains($0) } && verbs.contains { prompt.contains($0) }
    }
}

/// 衣服的剪影小图。
struct OutfitArt: View {
    let shape: String
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            func poly(_ pts: [(CGFloat, CGFloat)]) -> Path {
                var path = Path()
                path.addLines(pts.map { p($0.0, $0.1) })
                path.closeSubpath()
                return path
            }
            let dark = GraphicsContext.Shading.color(.black.opacity(0.18))
            let line = GraphicsContext.Shading.color(.black.opacity(0.22))
            func fill(_ path: Path) {
                ctx.fill(path, with: .linearGradient(Gradient(colors: [color, color.opacity(0.82)]), startPoint: p(0.5, 0), endPoint: p(0.5, 1)))
                ctx.stroke(path, with: line, lineWidth: 1)
            }
            func curve(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat), _ c: (CGFloat, CGFloat)) -> Path {
                var path = Path()
                path.move(to: p(from.0, from.1))
                path.addQuadCurve(to: p(to.0, to.1), control: p(c.0, c.1))
                return path
            }
            switch shape {
            case "gown":
                var skirt = Path()
                skirt.move(to: p(0.42, 0.4))
                skirt.addCurve(to: p(0.06, 0.95), control1: p(0.34, 0.5), control2: p(0.08, 0.62))
                skirt.addQuadCurve(to: p(0.94, 0.95), control: p(0.5, 1.03))
                skirt.addCurve(to: p(0.58, 0.4), control1: p(0.92, 0.62), control2: p(0.66, 0.5))
                skirt.closeSubpath()
                fill(poly([(0.36, 0.17), (0.5, 0.21), (0.64, 0.17), (0.6, 0.42), (0.4, 0.42)]))
                fill(Path(ellipseIn: CGRect(x: 0.24 * size.width, y: 0.15 * size.height, width: 0.15 * size.width, height: 0.13 * size.height)))
                fill(Path(ellipseIn: CGRect(x: 0.61 * size.width, y: 0.15 * size.height, width: 0.15 * size.width, height: 0.13 * size.height)))
                fill(skirt)
                for x in [0.28, 0.5, 0.72] as [CGFloat] { ctx.stroke(curve((0.5, 0.45), (x, 0.94), ((0.5 + x) / 2, 0.62)), with: line, lineWidth: 1) }
            case "mermaid":
                var d = Path()
                d.move(to: p(0.38, 0.14))
                d.addQuadCurve(to: p(0.42, 0.4), control: p(0.4, 0.28))
                d.addQuadCurve(to: p(0.4, 0.68), control: p(0.31, 0.54))
                d.addQuadCurve(to: p(0.18, 0.95), control: p(0.34, 0.86))
                d.addQuadCurve(to: p(0.82, 0.95), control: p(0.5, 1.0))
                d.addQuadCurve(to: p(0.6, 0.68), control: p(0.66, 0.86))
                d.addQuadCurve(to: p(0.58, 0.4), control: p(0.69, 0.54))
                d.addQuadCurve(to: p(0.62, 0.14), control: p(0.6, 0.28))
                d.addQuadCurve(to: p(0.38, 0.14), control: p(0.5, 0.26))
                fill(d)
                for x in [0.36, 0.64] as [CGFloat] { ctx.stroke(curve((0.5, 0.7), (x, 0.95), (0.48, 0.84)), with: line, lineWidth: 1) }
            case "aline":
                fill(poly([(0.37, 0.14), (0.45, 0.2), (0.55, 0.2), (0.63, 0.14), (0.6, 0.4), (0.8, 0.94), (0.2, 0.94), (0.4, 0.4)]))
                ctx.fill(poly([(0.395, 0.39), (0.605, 0.39), (0.612, 0.43), (0.388, 0.43)]), with: dark)
                for x in [0.38, 0.5, 0.62] as [CGFloat] { ctx.stroke(curve((0.5, 0.45), (x, 0.93), (0.5, 0.7)), with: line, lineWidth: 1) }
            case "short", "lolita":
                let low: CGFloat = shape == "lolita" ? 0.76 : 0.68
                fill(poly([(0.37, 0.16), (0.45, 0.22), (0.55, 0.22), (0.63, 0.16), (0.6, 0.42), (0.4, 0.42)]))
                var s = Path()
                s.move(to: p(0.4, 0.42))
                s.addQuadCurve(to: p(0.16, low), control: p(0.22, 0.5))
                let n = 6
                for i in 0..<n {
                    let a = 0.16 + 0.68 * CGFloat(i) / CGFloat(n), b = 0.16 + 0.68 * CGFloat(i + 1) / CGFloat(n)
                    s.addQuadCurve(to: p(b, low), control: p((a + b) / 2, low + 0.07))
                }
                s.addQuadCurve(to: p(0.6, 0.42), control: p(0.78, 0.5))
                s.closeSubpath()
                if shape == "lolita" {
                    for x in [0.22, 0.61] as [CGFloat] { fill(Path(ellipseIn: CGRect(x: x * size.width, y: 0.16 * size.height, width: 0.17 * size.width, height: 0.15 * size.height))) }
                }
                fill(s)
                ctx.fill(poly([(0.395, 0.4), (0.605, 0.4), (0.612, 0.44), (0.388, 0.44)]), with: dark)
            case "qipao":
                var d = Path()
                d.move(to: p(0.44, 0.12))
                d.addLine(to: p(0.56, 0.12))
                d.addLine(to: p(0.7, 0.2))
                d.addLine(to: p(0.72, 0.28))
                d.addLine(to: p(0.61, 0.27))
                d.addQuadCurve(to: p(0.59, 0.44), control: p(0.62, 0.36))
                d.addQuadCurve(to: p(0.64, 0.93), control: p(0.72, 0.62))
                d.addLine(to: p(0.36, 0.93))
                d.addQuadCurve(to: p(0.41, 0.44), control: p(0.28, 0.62))
                d.addQuadCurve(to: p(0.39, 0.27), control: p(0.38, 0.36))
                d.addLine(to: p(0.28, 0.28))
                d.addLine(to: p(0.3, 0.2))
                d.closeSubpath()
                fill(d)
                ctx.stroke(curve((0.5, 0.13), (0.62, 0.28), (0.52, 0.26)), with: line, lineWidth: 1.5)
                ctx.stroke(curve((0.6, 0.93), (0.65, 0.66), (0.62, 0.8)), with: line, lineWidth: 1.5)
            case "kimono", "hanfu":
                let sleeve: CGFloat = shape == "kimono" ? 0.62 : 0.56
                fill(poly([(0.38, 0.16), (0.1, 0.24), (0.06, sleeve), (0.3, sleeve), (0.34, 0.36)]))
                fill(poly([(0.62, 0.16), (0.9, 0.24), (0.94, sleeve), (0.7, sleeve), (0.66, 0.36)]))
                let hem: CGFloat = shape == "kimono" ? 0.66 : 0.78
                fill(poly([(0.38, 0.14), (0.62, 0.14), (0.66, 0.42), (hem, 0.95), (1 - hem, 0.95), (0.34, 0.42)]))
                ctx.stroke(poly([(0.42, 0.14), (0.56, 0.36), (0.6, 0.14)]), with: line, lineWidth: 1.5)
                ctx.fill(poly([(0.345, 0.4), (0.655, 0.4), (0.66, shape == "kimono" ? 0.54 : 0.47), (0.34, shape == "kimono" ? 0.54 : 0.47)]), with: dark)
                ctx.stroke(curve((0.5, 0.5), (0.46, 0.94), (0.52, 0.72)), with: line, lineWidth: 1)
            case "sailor":
                fill(poly([(0.36, 0.16), (0.64, 0.16), (0.8, 0.26), (0.76, 0.42), (0.66, 0.38), (0.64, 0.52), (0.36, 0.52), (0.34, 0.38), (0.24, 0.42), (0.2, 0.26)]))
                ctx.fill(poly([(0.36, 0.16), (0.64, 0.16), (0.68, 0.26), (0.5, 0.38), (0.32, 0.26)]), with: dark)
                fill(poly([(0.37, 0.52), (0.63, 0.52), (0.76, 0.82), (0.24, 0.82)]))
                for i in 1..<6 {
                    let t = CGFloat(i) / 6
                    ctx.stroke(curve((0.37 + 0.26 * t, 0.53), (0.24 + 0.52 * t, 0.82), (0.31 + 0.39 * t, 0.67)), with: line, lineWidth: 1)
                }
            case "suit", "coat":
                let hem: CGFloat = shape == "coat" ? 0.86 : 0.6
                fill(poly([(0.36, 0.14), (0.64, 0.14), (0.8, 0.24), (0.86, 0.6), (0.74, 0.62), (0.69, 0.36), (0.71, hem), (0.29, hem), (0.31, 0.36), (0.26, 0.62), (0.14, 0.6), (0.2, 0.24)]))
                if shape == "suit" { fill(poly([(0.33, 0.6), (0.67, 0.6), (0.66, 0.95), (0.53, 0.95), (0.5, 0.68), (0.47, 0.95), (0.34, 0.95)])) }
                ctx.fill(poly([(0.42, 0.14), (0.5, 0.36), (0.58, 0.14)]), with: .color(.white.opacity(0.85)))
                ctx.stroke(curve((0.5, 0.36), (0.5, hem), (0.5, 0.5)), with: line, lineWidth: 1.5)
                if shape == "coat" { ctx.fill(poly([(0.3, 0.5), (0.7, 0.5), (0.7, 0.55), (0.3, 0.55)]), with: dark) }
            case "armor":
                fill(poly([(0.5, 0.36), (0.78, 0.94), (0.22, 0.94)]))
                fill(poly([(0.36, 0.15), (0.64, 0.15), (0.68, 0.34), (0.6, 0.56), (0.4, 0.56), (0.32, 0.34)]))
                for x in [0.19, 0.62] as [CGFloat] { fill(Path(ellipseIn: CGRect(x: x * size.width, y: 0.14 * size.height, width: 0.19 * size.width, height: 0.15 * size.height))) }
                ctx.stroke(curve((0.5, 0.2), (0.5, 0.55), (0.5, 0.4)), with: line, lineWidth: 1.5)
                ctx.fill(poly([(0.39, 0.5), (0.61, 0.5), (0.6, 0.56), (0.4, 0.56)]), with: dark)
            case "hoodie":
                fill(poly([(0.36, 0.2), (0.64, 0.2), (0.82, 0.3), (0.88, 0.66), (0.75, 0.68), (0.69, 0.44), (0.69, 0.72), (0.31, 0.72), (0.31, 0.44), (0.25, 0.68), (0.12, 0.66), (0.18, 0.3)]))
                fill(Path(ellipseIn: CGRect(x: 0.35 * size.width, y: 0.1 * size.height, width: 0.3 * size.width, height: 0.17 * size.height)))
                ctx.fill(poly([(0.38, 0.52), (0.62, 0.52), (0.66, 0.66), (0.34, 0.66)]), with: dark)
            default:
                fill(poly([(0.38, 0.16), (0.46, 0.2), (0.54, 0.2), (0.62, 0.16), (0.8, 0.24), (0.84, 0.46), (0.72, 0.48), (0.67, 0.36), (0.66, 0.58), (0.34, 0.58), (0.33, 0.36), (0.28, 0.48), (0.16, 0.46), (0.2, 0.24)]))
                ctx.stroke(curve((0.5, 0.2), (0.5, 0.57), (0.5, 0.4)), with: line, lineWidth: 1.2)
                fill(poly([(0.35, 0.58), (0.65, 0.58), (0.72, 0.94), (0.28, 0.94)]))
            }
        }
    }
}
