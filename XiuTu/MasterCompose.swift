import CoreGraphics
import Foundation
import Vision

/// 大师风格的"大师构图"：除了色彩影调，再按这位摄影师惯用的取景方式重新构图。
/// 只描述手法，不写名字（名字会带来和画面无关的联想，容易被审核误判）。
/// 有人和没人的照片用两套描述：没人的场景照如果照着"人物居中"去写，AI 会自己加一个人进去。
enum MasterCompose {
    /// 大师指令里"构图保持原样"的那句尾巴。
    static let keepTail = "只调整光线、色彩、反差和影调；画面内容、人物长相、姿势、服装和构图都保持原样，结果仍是一张真实的照片。"

    /// 像真照片的要求：AI 整张重画时最容易磨皮、涂抹、到处加光斑。
    static let realTail = "画质要求：真实镜头拍出来的样子。皮肤保留毛孔、细纹和自然的颜色不均，头发是一根根真实的发丝，布料有织纹；" +
        "不磨皮、不涂抹，不要绘画感和塑料感，不要发光的边缘、柔光滤镜或到处的光斑，焦外按真实镜头自然虚化。画面里不要画出网格、辅助线或取景框。"

    /// 换成"按大师的构图重新取景"。frame 是选的哪一种取景。找不到这位大师或指令不是标准格式时返回 nil。
    static func prompt(_ base: String, title: String, frame: String? = nil, hasPerson: Bool) -> String? {
        guard base.contains(keepTail), let master = MasterCatalog.byTitle[title],
              let f = master.frames.first(where: { $0.title == frame }) ?? master.frames.first else { return nil }
        let tail: String
        if hasPerson {
            tail = "构图按这个取景重新拍：\(f.person)。这是同一个人、同一个地方、同一时刻，像同一台相机退后、靠近或换了个角度又按了一次快门。" +
                "人物长相、五官比例、表情、发型、身材、服装和姿势都不变，脸的朝向不变；原照片里没拍到的部分（更宽的环境、身体的其余部分）按原场景合理延续。" +
                "只能用原照片里已经有的东西：不要凭空加窗框、门框、柱子、墙、栏杆、前景遮挡、灯、花瓣或别的人。"
        } else {
            tail = "构图按这个取景重新拍：\(f.scene)。必须还是同一个地方、同一时刻，陈设和物件都来自原场景，缺的部分按原场景合理延续。" +
                "原照片里没有人，结果里也不能出现任何人、人影或人体的一部分——上面说到的人像、肤色只是在讲影调，不要因此加人；" +
                "也不要凭空加窗框、门框、柱子、前景遮挡、灯或别的东西。"
        }
        return base.replacingOccurrences(of: keepTail, with: tail + realTail + "画面比例不变，结果是一张真实的照片。")
    }

    /// 照片里有没有人：认出人体或者人脸都算有。
    /// 不用人像分割判断——它在岩石、水流这类纹理上会误报出一大片"人"。
    static func hasPerson(in image: CGImage) -> Bool {
        let human = VNDetectHumanRectanglesRequest()
        human.upperBodyOnly = false
        let face = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([human, face])
        let people = (human.results ?? []).filter { $0.confidence >= 0.5 }
        return !people.isEmpty || !(face.results ?? []).isEmpty
    }
}
