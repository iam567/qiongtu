import CoreImage
import Foundation
import simd

/// 一位大师的资料（masters.json，iOS 和安卓共用，由 tools/make_masters.py 生成）。
struct MasterInfo: Decodable, Identifiable {
    /// 一种取景：有人和没人的照片各一套要求。
    struct Frame: Decodable, Identifiable {
        let title: String
        let person: String
        let scene: String
        var id: String { title }
    }

    /// 小图的色调（没有的沿用 MasterPreview 里写好的）。
    struct Look: Decodable {
        var exposure, contrast, highlights, shadows, saturation, vibrance, temperature, tint, fade, vignette, bloom: Float?
        var mono: Bool?
        var shadowTint, highlightTint: [Float]?
    }

    let group: String
    let title: String
    let note: String
    /// 发给 AI 的影调要求（只描述手法，不写名字）。
    let tone: String
    /// 界面上介绍风格的三句话。
    let color: String
    let light: String
    let compose: String
    let frames: [Frame]
    let look: Look?
    var id: String { title }

    var prompt: String { "给这张照片做专业调色，风格是：\(tone)。画面保持彩色，不要变成黑白。调色克制自然：肤色干净健康、不偏色，暗部保留细节，不死黑也不过曝，饱和度和反差都不过头，像相机直出，不要 HDR 感。\(MasterCompose.keepTail)" }
}

enum MasterCatalog {
    static let all: [MasterInfo] = {
        guard let url = Bundle.main.url(forResource: "masters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([MasterInfo].self, from: data) else { return [] }
        return list
    }()

    static let byTitle = Dictionary(uniqueKeysWithValues: all.map { ($0.title, $0) })

    /// 按出现的先后排好的组名。
    static let groups: [String] = all.reduce(into: []) { if !$0.contains($1.group) { $0.append($1.group) } }

    static let presets: [AIPreset] = all.map { AIPreset(title: $0.title, prompt: $0.prompt, note: $0.note) }

    /// 资料里带了色调的那几位的小图。
    static let looks: [(String, FilmLook)] = all.compactMap { master in
        guard let l = master.look else { return nil }
        var c = ColorParams()
        c.exposure = l.exposure ?? 0
        c.contrast = l.contrast ?? 0
        c.highlights = l.highlights ?? 0
        c.shadows = l.shadows ?? 0
        c.saturation = l.saturation ?? 0
        c.vibrance = l.vibrance ?? 0
        c.temperature = l.temperature ?? 0
        c.tint = l.tint ?? 0
        c.fade = l.fade ?? 0
        c.mono = l.mono ?? false
        if let t = l.shadowTint, t.count == 3 { c.shadowTint = SIMD3(t[0], t[1], t[2]) }
        if let t = l.highlightTint, t.count == 3 { c.highlightTint = SIMD3(t[0], t[1], t[2]) }
        return (master.title, FilmLook(id: "master-" + master.title, name: master.title, category: .master, color: c,
                                       vignette: CGFloat(l.vignette ?? 0), bloom: CGFloat(l.bloom ?? 0)))
    }
}
