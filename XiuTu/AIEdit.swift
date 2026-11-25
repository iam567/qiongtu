import CoreImage
import UIKit

/// AI 面板里的快捷指令。
struct AIPreset: Identifiable {
    let title: String
    /// 按钮上的图标。
    var symbol = "sparkles"
    let prompt: String
    /// 一句话说明。
    var note: String = ""
    /// 没涂抹时自动找到人脸，只把头部这一块发给 AI（脸占的像素多，才不容易被画成另一个人）。
    var faceCrop = false
    /// 只修光影和颜色的指令：结果只采用 AI 的光影和颜色，细节（脸、纹理、分辨率）全部保留原图。
    var toneOnly = false
    /// 美发类：没涂抹时自动把头和头发这一大块发给 AI。
    var hairCrop = false
    /// 只改身体的这一块：结果只在这一块里采用。
    var part: BodyPart? = nil
    /// 按钮显示成这个颜色的色块（染发用），0xRRGGBB。
    var tint: UInt32? = nil
    var id: String { title }
}

enum AIIntent {
    /// 修跑焦：强调这是"还原"不是"重画"，五官的形状和位置一点都不能变。
    static let refocusPrompt = """
    This is a crop from a photo where the camera focused on the background, so the person is slightly out of focus. \
    Restore sharp focus on the person: crisp eyes and eyelashes, individual hair strands, realistic skin texture with pores, clear fabric texture. \
    This is a restoration, not a redraw. Every facial feature must keep exactly the same shape, size, position and proportions as in the input: \
    the same eye shape and spacing, the same nose, lips, eyebrows, jawline, face width, the same expression and gaze direction. \
    Do not beautify, do not change makeup, skin tone, lighting, colors or hairstyle. It must be unmistakably the same individual. \
    Keep the exact same framing and position of everything so the result can be overlaid on the original. Photorealistic.
    """

    /// 修手抖：去掉拍摄时相机晃动造成的拖影和重影。涂抹了就只修涂抹的部分，背景的动感保留。
    static let deshakePrompt = """
    这张照片拍的时候相机晃了，画面有手抖造成的运动模糊、拖影和重影。把手抖去掉：\
    把重影合回一个清晰的轮廓，恢复锐利的边缘和真实的细节（文字、车牌、灯、发丝、纹理都要清楚），就像用安全快门、稳稳拍下的同一张照片。\
    这是还原，不是重画：构图、视角、所有东西的形状大小和位置、颜色、光线都和原图一致，结果要能和原图逐像素对齐叠在一起。\
    不要磨皮美化，不要改人物长相，不要加任何新东西。真实的照片质感。
    """

    /// 指令是不是"把涂抹的东西去掉/换掉"这一类。
    /// 这一类才把涂抹区域当蒙版发出去（蒙版里的内容 AI 看不到，会从头重画）；
    /// 其他指令（提亮、磨皮、瘦身……）是在原有内容上修改，AI 必须能看到原图，所以不发蒙版。
    static func replacesContent(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        return ["去掉", "消除", "删除", "移除", "抹掉", "擦掉", "去除", "换成", "替换", "remove", "erase", "delete", "replace"]
            .contains { p.contains($0) }
    }
}

enum AIPresetGroup: String, CaseIterable, Identifiable {
    case fix, light, remove, outfit, compose, master, camera, creative, body
    case hairStyle, hairColor, hairCare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fix: return "修复"
        case .light: return "光线"
        case .remove: return "消除"
        case .outfit: return "换衣服"
        case .compose: return "构图"
        case .master: return "大师"
        case .camera: return "相机"
        case .creative: return "创意"
        case .body: return "AI 美体"
        case .hairStyle: return "发型"
        case .hairColor: return "染发"
        case .hairCare: return "发质发量"
        }
    }

    /// 美发的三组。
    static let hairGroups: [AIPresetGroup] = [.hairStyle, .hairColor, .hairCare]

    var isHair: Bool { Self.hairGroups.contains(self) }

    /// AI 修图面板里的四组；AI 美体单独放在"美体"里。
    static let editGroups: [AIPresetGroup] = [.fix, .light, .remove, .outfit, .compose, .master, .camera, .creative]

    /// 主菜单里的名字（面板里的分段标签用更短的 title）。
    var menuTitle: String {
        switch self {
        case .camera: return "相机质感"
        case .creative: return "创意玩法"
        default: return title
        }
    }

    /// 这一组的按钮是不是用图片（小图是本机模拟的大致色调）。
    var usesTonePreview: Bool { self == .master || self == .camera || self == .light || self == .creative }

    var symbol: String {
        switch self {
        case .fix: return "wand.and.stars"
        case .light: return "lightbulb"
        case .remove: return "eraser"
        case .outfit: return "tshirt"
        case .compose: return "crop"
        case .master: return "camera.aperture"
        case .camera: return "camera"
        case .creative: return "theatermasks"
        case .body: return "figure.stand"
        case .hairStyle: return "scissors"
        case .hairColor: return "paintpalette"
        case .hairCare: return "wand.and.stars"
        }
    }

    /// 这一组是干什么的。
    var note: String {
        switch self {
        case .fix: return "让 AI 找出并修掉拍摄上的毛病，内容和构图不变。"
        case .light: return "让 AI 给画面重新打光；内容和构图不变。"
        case .remove: return "去掉或换掉画面里的东西。"
        case .outfit: return "只换衣服。"
        case .compose: return "会重新安排画面，整张图由 AI 重画，分辨率以 AI 输出为准。"
        case .master: return "按这位摄影师的典型风格重新处理光线、色彩和影调；整张图交给 AI 重画。"
        case .camera: return "把手机拍的照片处理成这台相机拍出来的质感；整张图交给 AI 重画。"
        case .creative: return "把照片画成别的风格，或者加点好玩的东西；整张图交给 AI 重画。"
        case .body: return "调整身材比例。只想改局部时先涂抹。"
        case .hairStyle, .hairColor, .hairCare:
            return "只把头和头发这一块发给 AI，脸尽量保持原样；每点一次计一次费。"
        }
    }

    var presets: [AIPreset] {
        switch self {
        case .fix:
            return [
                AIPreset(title: "一键修复", symbol: "wand.and.stars", prompt: "你是一位摄影大师兼调色师。先判断这张照片在曝光和色彩上的毛病（过曝或欠曝、逆光导致主体太暗、高光溢出、暗部死黑、偏色和白平衡不准、灰雾、反差不足或过头），然后把它调成一张曝光和色彩都正确、自然好看的照片。只改曝光、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐。", toneOnly: true),
                AIPreset(title: "修跑焦", symbol: "camera.viewfinder", prompt: AIIntent.refocusPrompt, faceCrop: true),
                AIPreset(title: "修手抖", symbol: "hand.raised.slash", prompt: AIIntent.deshakePrompt),
                AIPreset(title: "去 AI 味", symbol: "camera.aperture", prompt: "这张照片看起来有明显的 AI 生成感。把它处理成一张真正用相机拍出来的照片：去掉过度锐化和边缘白边，细节恢复成镜头自然的清晰度（焦外和远处自然地柔一点）；皮肤要有真实的毛孔和细微的不均匀，不要塑料感和过度磨皮；降低过高的饱和度、过度的 HDR 和处处都亮的均匀光，恢复真实的明暗层次和阴影；去掉过分完美对称、过分干净的痕迹，保留真实世界里自然的小瑕疵。不要额外加胶片颗粒。画面内容、构图、人物长相、姿势和服装都不变。"),
                AIPreset(title: "修过曝", symbol: "sun.max", prompt: "修复过曝：找回高光里的层次，压住发白的天空和皮肤。只改曝光、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐。", toneOnly: true),
                AIPreset(title: "修逆光", symbol: "sun.horizon", prompt: "修复逆光和欠曝：把人物和暗部提亮到正常，像补了一盏柔和的面光；保留背景亮部的层次，不要发灰。只改曝光、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐。", toneOnly: true),
                AIPreset(title: "去紫边", symbol: "rainbow", prompt: "去掉高反差边缘上的紫边、蓝边和绿边（色差），其他不变。"),
                AIPreset(title: "校正偏色", symbol: "eyedropper.halffull", prompt: "校正白平衡和偏色，让肤色和中性色看起来自然准确。只改曝光、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐。", toneOnly: true),
                AIPreset(title: "去噪点", symbol: "aqi.medium", prompt: "去掉噪点和压缩痕迹，保留真实细节和皮肤纹理，不要涂抹感。"),
                AIPreset(title: "去雾", symbol: "cloud.fog", prompt: "去掉灰雾感，让画面更通透、反差正常，颜色不要过饱和。只改曝光、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐。", toneOnly: true),
                AIPreset(title: "去反光", symbol: "rays", prompt: "去掉玻璃反光和眩光，让画面更通透，其他内容不变。"),
                AIPreset(title: "增强画质", symbol: "wand.and.rays", prompt: "提升清晰度和细节，降低噪点，保持人物长相和构图不变。"),
            ]
        case .light:
            return [
                AIPreset(title: "自然补光", symbol: "lightbulb", prompt: "像在镜头旁边加了一块大反光板：把人物的脸和暗部柔和地提亮，眼睛里有自然的眼神光，背景亮度基本不变。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "窗边柔光", symbol: "lightbulb", prompt: "把光线改成从一侧大窗户照进来的柔和自然光：亮面到暗面过渡细腻，暗部保留层次，整体安静干净。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "伦勃朗光", symbol: "lightbulb", prompt: "把人物的布光改成伦勃朗光：主光从侧前上方约 45 度打来，远离光源一侧的脸颊上留下一块倒三角形的亮斑，其余在柔和的阴影里，立体而有戏剧感，背景相应压暗。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "蝴蝶光", symbol: "lightbulb", prompt: "把人物的布光改成蝴蝶光：主光在正前方偏高，鼻子下方有一小块对称的阴影，颧骨和下颌线被勾勒出来，皮肤明亮干净。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "侧光", symbol: "lightbulb", prompt: "把光线改成从正侧面打来的硬朗侧光：半张脸亮、半张脸暗，明暗分界清楚，质感和轮廓被强调。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "轮廓光", symbol: "lightbulb", prompt: "在人物身后加一盏轮廓光：头发和肩膀边缘有一圈明亮的光边，把人从背景里分离出来，正面保持柔和的补光。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "日落逆光", symbol: "lightbulb", prompt: "把光线改成日落时分的逆光：太阳在人物身后偏低，发丝边缘被染成金色，画面带暖色的眩光和通透的空气感，脸部有柔和的补光不发黑。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "黄金时刻", symbol: "lightbulb", prompt: "把光线改成日出日落前后的黄金时刻：低角度的暖金色阳光，长而柔和的影子，高光偏暖、阴影微冷。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "蓝调时刻", symbol: "lightbulb", prompt: "把光线改成日落后的蓝调时刻：天光是深邃的蓝色，整体偏冷而安静，人物脸上有一点来自环境灯光的暖色补光。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "阴天柔光", symbol: "lightbulb", prompt: "把光线改成薄云阴天的漫射光：几乎没有硬阴影，明暗柔和均匀，肤色干净。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "正午阳光", symbol: "lightbulb", prompt: "把光线改成晴天的直射阳光：明亮通透，阴影清晰有方向，颜色鲜明。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "棚拍柔光", symbol: "lightbulb", prompt: "把光线改成影棚里大柔光箱的布光：主光柔和均匀，另一侧有轻微补光，阴影干净，像商业人像棚拍。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "环形灯", symbol: "lightbulb", prompt: "把光线改成正前方环形灯的效果：脸部明亮均匀、几乎没有阴影，眼睛里有一圈环形的眼神光。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "电影青橙", symbol: "lightbulb", prompt: "把光线和色彩改成电影感的青橙色调：亮部和肤色偏暖橙，阴影偏青蓝，主光有明确的方向，对比适中。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "霓虹夜色", symbol: "lightbulb", prompt: "把光线改成夜晚街头的霓虹灯光：一侧是洋红色、另一侧是青蓝色的彩色光打在人物身上，背景暗下去。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "舞台聚光", symbol: "lightbulb", prompt: "把光线改成舞台追光：一束明亮的聚光从上方打在主体身上，周围迅速暗下去，接近全黑。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "烛光", symbol: "lightbulb", prompt: "把光线改成烛光：光源在人物前下方，暖橙色、范围很小，脸部被柔和地照亮，周围沉入暖色的暗部。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "月光", symbol: "lightbulb", prompt: "把光线改成夜晚的月光：冷蓝色、柔和而微弱的顶侧光，阴影深但仍有细节，安静的夜色氛围。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "丁达尔光", symbol: "lightbulb", prompt: "在画面里加入丁达尔效应的体积光：阳光穿过空气形成一道道可见的光束，从高处斜着洒下来，空气里有薄雾感。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "直闪", symbol: "lightbulb", prompt: "把光线改成相机机顶闪光灯直闪的效果：正面硬光，人物明亮、背景明显变暗，有杂志快拍的感觉。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "低调暗光", symbol: "lightbulb", prompt: "把画面改成低调摄影的布光：大面积深沉的暗部，只有一小部分被一束柔和的侧光照亮，神秘而克制。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "高调明亮", symbol: "lightbulb", prompt: "把画面改成高调摄影的布光：整体明亮通透，阴影很浅，背景干净发亮，但高光不溢出。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，人物长相不变，结果要和原图逐像素对齐，仍然是一张真实的照片。", toneOnly: true),
                AIPreset(title: "百叶窗光影", symbol: "lightbulb", prompt: "把光线改成阳光透过百叶窗照进来：人物和背景上落着一条条平行的明暗条纹，光是暖色的，对比清楚。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "树影光斑", symbol: "lightbulb", prompt: "把光线改成阳光透过树叶洒下来：人物和背景上落着斑驳的树影和光斑，明亮清新。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
            ]
        case .remove:
            return [
                AIPreset(title: "消除", symbol: "eraser", prompt: "把涂抹区域里的东西去掉，并自然地补全背景。"),
                AIPreset(title: "去路人", symbol: "person.slash", prompt: "去掉画面里的路人和无关的人，只保留主角，自然补全背景。"),
                AIPreset(title: "去杂物", symbol: "trash", prompt: "去掉画面里分散注意力的杂物（垃圾桶、电线、标牌等），自然补全背景，主体不变。"),
                AIPreset(title: "换背景", symbol: "person.and.background.dotted", prompt: "保持人物不变，把背景换成："),
                AIPreset(title: "换天空", symbol: "cloud.sun", prompt: "保持地面和人物不变，把天空换成："),
            ]
        case .outfit:
            return []
        case .compose:
            return [
                AIPreset(title: "重新构图", symbol: "viewfinder", prompt: "你是一位摄影大师。判断这张照片的构图问题（主体位置、留白、头顶和脚下的空间、画面是否歪斜、边缘是否有干扰），然后重新构图，让主体更突出、画面更平衡。构图只是取景的要求，画面里不要画出任何网格、辅助线、取景框、文字或标记。人物长相、姿势和服装不变，画面比例不变。"),
                AIPreset(title: "三分法", symbol: "squareshape.split.3x3", prompt: "重新取景，让主体不在正中间：把主体放在画面偏左或偏右、大约三分之一宽度的位置，地平线放在偏上或偏下大约三分之一高度处，人物视线朝向的那一侧留出更多空间。构图只是取景的要求，画面里不要画出任何网格、辅助线、取景框、文字或标记。人物和场景内容不变，画面比例不变。"),
                AIPreset(title: "主体居中", symbol: "dot.viewfinder", prompt: "重新构图，让主体在画面正中、左右对称平衡。构图只是取景的要求，画面里不要画出任何网格、辅助线、取景框、文字或标记。人物和场景内容不变，画面比例不变。"),
                AIPreset(title: "拉正", symbol: "level", prompt: "把歪斜的地平线和建筑的垂直线拉正，校正镜头畸变，其他不变。"),
                AIPreset(title: "虚化背景", symbol: "drop", prompt: "保持人物清晰，把背景虚化成大光圈镜头的效果，过渡自然，发丝边缘不要出错。"),
            ]
        case .master:
            return MasterCatalog.presets
        case .camera:
            return [
                AIPreset(title: "徕卡 M", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用徕卡 M 旁轴相机配 35mm f/1.4 镜头拍出来的样子：反差扎实、暗部深而有层次，颜色克制略偏暖，微反差高、主体立体，焦外柔和，四角有一点自然的暗角。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "徕卡黑白", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用徕卡黑白旁轴相机配 50mm 镜头拍出来的样子：纯黑白，灰阶细腻丰富，黑色深沉，高光柔和不溢出，主体立体，焦外柔和。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "徕卡 Q", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用徕卡 Q 全画幅相机的 28mm f/1.7 镜头拍出来的样子：广角的现场感，近处主体清晰、背景自然虚化，颜色通透克制，反差适中。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "哈苏中画幅", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用哈苏中画幅数码相机配 80mm 镜头拍出来的样子：自然真实的色彩，肤色干净，明暗过渡极其细腻，高光不刺眼、暗部有细节，中画幅特有的浅景深和空间感。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "富士中画幅", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用富士 GFX 中画幅相机配 110mm f/2 镜头拍出来的样子：富士胶片模拟的色彩：柔和的反差、通透的绿色和蓝色、温润的肤色，中画幅的浅景深和细腻过渡。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "富士经典正片", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用富士 X 系列相机，经典正片（Classic Chrome）胶片模拟拍出来的样子：低饱和、偏冷的暗部、克制而有质感的颜色，纪实摄影的味道，反差略高。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "佳能人像", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用佳能全画幅相机配 85mm f/1.2 人像镜头拍出来的样子：肤色红润通透，奶油般化开的焦外，主体从背景里分离出来，整体明亮讨喜。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "尼康", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用尼康全画幅相机配 58mm f/1.4 镜头拍出来的样子：颜色真实、略偏冷静，细节锐利而不生硬，宽容度大，暗部干净，焦外过渡平滑。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "索尼", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用索尼全画幅微单配 35mm f/1.4 GM 镜头拍出来的样子：解析力高、画面干净通透，颜色准确略偏冷，背景虚化干净利落。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "适马", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用适马 Foveon 传感器相机拍出来的样子：颜色浓郁厚重，像反转片；细节极其锐利扎实，质感强烈，低感光度的纯净画面。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "理光 GR", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用理光 GR 便携相机的 28mm 镜头，正片负冲风格拍出来的样子：街头快拍的味道：反差高、颜色浓、暗部偏青，锐利直接。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "理光黑白", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用理光 GR 便携相机的 28mm 镜头，高对比黑白模式拍出来的样子：纯黑白，反差很高，黑白分明，街头摄影的冲击力。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "康泰时 T2", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用康泰时 T2 胶片便携相机的蔡司 38mm f/2.8 镜头配彩色负片拍出来的样子：蔡司镜头通透油润的颜色，蓝色和绿色鲜明，反差适中，高光柔和，带一点直闪或自然光的生活感。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "宾得 67", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用宾得 67 中画幅胶片相机配 105mm f/2.4 镜头和彩色负片拍出来的样子：中画幅胶片的浅景深和空气感，肤色柔和温暖，颜色淡雅，过渡细腻。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "禄来双反", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用禄来双反中画幅相机配 80mm 镜头拍出来的样子：方画幅的沉静气质（画面比例不变），柔和的反差，细腻的灰阶，怀旧而干净的颜色。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "CCD 卡片机", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用2000 年代的 CCD 数码卡片相机，开着机顶闪光灯拍出来的样子：直闪的硬光和明显的阴影，颜色浓郁偏冷，高光略微溢出，千禧年数码相机的复古感。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "大光圈人像", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用全画幅相机配 85mm f/1.2 镜头全开光圈拍出来的样子：人物清晰锐利，背景大幅虚化成柔和的光斑，发丝边缘自然，颜色自然。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
                AIPreset(title: "长焦压缩", symbol: "camera", prompt: "这是一张手机拍的照片。把它处理成用全画幅相机配 200mm f/2 长焦镜头拍出来的样子：长焦的空间压缩感，背景被拉近并完全虚化，主体突出，画面干净。去掉手机照片那种过度锐化、HDR 和涂抹感，景深、焦外和镜头的成像质感要像真的大底相机；不要加胶片颗粒。人物长相、姿势、服装和构图不变，结果仍然是一张真实的照片。"),
            ]
        case .creative:
            return CreativeKind.all
        case .body:
            if GenderSetting.shared.isMale { return MalePresets.body }
            return [
                AIPreset(title: "瘦身", symbol: "figure.stand", prompt: "让身材稍微苗条一些，比例自然，不要改变姿势、长相和背景。"),
                AIPreset(title: "长腿", symbol: "figure.walk", prompt: "把腿稍微拉长一些，让身材比例更修长，保持自然，背景不要变形。"),
                AIPreset(title: "瘦腰", symbol: "arrow.right.and.line.vertical.and.arrow.left", prompt: "让腰稍微细一点，线条自然，衣服的褶皱和背景保持合理。"),
                AIPreset(title: "瘦手臂", symbol: "figure.arms.open", prompt: "让手臂稍微纤细一些，保持自然，不要改变姿势。"),
                AIPreset(title: "肤色提亮", symbol: "sun.max", prompt: "全身肤色提亮、更均匀通透，保持自然，不要过曝。", toneOnly: true),
            ]
        case .hairStyle:
            if GenderSetting.shared.isMale { return MalePresets.hairStyles }
            return [
                AIPreset(title: "长直发", symbol: "scissors", prompt: "把发型换成又长又直、柔顺垂坠的长直发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "大波浪", symbol: "scissors", prompt: "把发型换成蓬松有光泽的大波浪长卷发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "法式卷", symbol: "scissors", prompt: "把发型换成慵懒随性的法式卷发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "羊毛卷", symbol: "scissors", prompt: "把发型换成蓬松的小卷羊毛卷。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "水波纹", symbol: "scissors", prompt: "把发型换成复古的水波纹卷发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "锁骨发", symbol: "scissors", prompt: "把发型换成发尾微微内扣、长度到锁骨的锁骨发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "波波头", symbol: "scissors", prompt: "把发型换成齐下巴的波波头短发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "短发", symbol: "scissors", prompt: "把发型换成清爽利落的齐耳短发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "精灵短发", symbol: "scissors", prompt: "把发型换成露出耳朵的精灵短发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "高马尾", symbol: "scissors", prompt: "把发型换成高高扎起、清爽利落的高马尾。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "低马尾", symbol: "scissors", prompt: "把发型换成温柔的低马尾。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "丸子头", symbol: "scissors", prompt: "把发型换成头顶扎起的丸子头，留几缕碎发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "双马尾", symbol: "scissors", prompt: "把发型换成两侧扎起的双马尾。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "公主切", symbol: "scissors", prompt: "把发型换成两侧齐切的公主切长直发。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "编发", symbol: "scissors", prompt: "把发型换成精致的侧编麻花辫。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "空气刘海", symbol: "scissors", prompt: "把发型换成轻薄的空气刘海，其余头发不变。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "八字刘海", symbol: "scissors", prompt: "把发型换成向两侧分开的八字刘海，其余头发不变。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "齐刘海", symbol: "scissors", prompt: "把发型换成整齐的齐刘海，其余头发不变。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "中分", symbol: "scissors", prompt: "把发型换成中分，露出额头。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "侧分", symbol: "scissors", prompt: "把发型换成三七侧分，发根蓬松。发色保持不变；头发要有真实的发丝细节，和头型、发际线自然贴合。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
            ]
        case .hairColor:
            if GenderSetting.shared.isMale { return MalePresets.hairColors }
            return [
                AIPreset(title: "自然黑", symbol: "paintpalette", prompt: "把头发染成自然的黑色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x1A1A1C),
                AIPreset(title: "深棕", symbol: "paintpalette", prompt: "把头发染成深棕色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x3B2A20),
                AIPreset(title: "栗棕", symbol: "paintpalette", prompt: "把头发染成栗棕色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x6B4226),
                AIPreset(title: "亚麻棕", symbol: "paintpalette", prompt: "把头发染成偏冷的亚麻棕色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x8A7257),
                AIPreset(title: "奶茶色", symbol: "paintpalette", prompt: "把头发染成柔和的奶茶色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xB89A7C),
                AIPreset(title: "蜂蜜茶", symbol: "paintpalette", prompt: "把头发染成暖调的蜂蜜茶色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xB7823F),
                AIPreset(title: "金色", symbol: "paintpalette", prompt: "把头发染成明亮的金色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xD9B56A),
                AIPreset(title: "铂金", symbol: "paintpalette", prompt: "把头发染成很浅的铂金色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xE9E1CF),
                AIPreset(title: "银灰", symbol: "paintpalette", prompt: "把头发染成银灰色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xA9ADB3),
                AIPreset(title: "雾霾蓝", symbol: "paintpalette", prompt: "把头发染成低饱和的雾霾蓝色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x6F8FA6),
                AIPreset(title: "樱花粉", symbol: "paintpalette", prompt: "把头发染成柔和的樱花粉色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xF2B6C4),
                AIPreset(title: "玫瑰金", symbol: "paintpalette", prompt: "把头发染成玫瑰金色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xD9A08C),
                AIPreset(title: "酒红", symbol: "paintpalette", prompt: "把头发染成深酒红色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x6E1F2B),
                AIPreset(title: "橘棕", symbol: "paintpalette", prompt: "把头发染成橘棕色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0xB5622E),
                AIPreset(title: "雾紫", symbol: "paintpalette", prompt: "把头发染成低饱和的雾紫色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x9A86B0),
                AIPreset(title: "薄荷绿", symbol: "paintpalette", prompt: "把头发染成浅薄荷绿色。只改头发的颜色，发型、发丝走向和长度都不变；颜色要像真的染出来的，有深浅层次和自然的高光，发根过渡自然。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true, tint: 0x9CCFB8),
                AIPreset(title: "挑染", symbol: "paintbrush.pointed", prompt: "在现有发色上加几缕浅色的挑染，层次自然。发型不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "渐变", symbol: "circle.lefthalf.filled", prompt: "把头发染成从发根深色到发尾浅色的自然渐变。发型不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
            ]
        case .hairCare:
            if GenderSetting.shared.isMale { return MalePresets.hairCare }
            return [
                AIPreset(title: "顺滑柔亮", symbol: "wand.and.stars", prompt: "让头发更顺滑、有光泽，去掉毛躁和分叉，发型和发色不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "去毛躁", symbol: "wind", prompt: "去掉头顶和发丝边缘翘起来的碎发和毛躁，轮廓干净，发型和发色不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "蓬松", symbol: "cloud", prompt: "让发根更蓬松，头发更有空气感，发型的样式和发色不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "增加发量", symbol: "plus.circle", prompt: "让头发更浓密、发量更多，看起来自然，发型的样式和发色不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "高颅顶", symbol: "arrow.up.circle", prompt: "让头顶的头发更蓬、颅顶更高更饱满，发型的样式和发色不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "填充发际线", symbol: "person.crop.circle", prompt: "把稀疏、后移的发际线和两侧鬓角补得自然饱满，新长出的头发和原来的发色、发质一致。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "AI 生发", symbol: "leaf", prompt: "让头顶、发缝和稀疏的地方长出自然的头发，遮住露出的头皮，新头发和原来的发色、发质一致。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
                AIPreset(title: "遮盖白发", symbol: "moon", prompt: "把白发和灰发染回和周围头发一样的颜色，发型不变。脸、五官、表情、肤色、妆容、衣服、姿势和背景都不变，必须还是同一个人。", hairCrop: true),
            ]
        }
    }
}

/// AI 构图时输出成什么画幅。
enum AIReframe: String, CaseIterable, Identifiable {
    case original, portrait, landscape, square

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原比例"
        case .portrait: return "竖幅"
        case .landscape: return "横幅"
        case .square: return "方形"
        }
    }

    var symbol: String {
        switch self {
        case .original: return "aspectratio"
        case .portrait: return "rectangle.portrait"
        case .landscape: return "rectangle"
        case .square: return "square"
        }
    }

    /// 输出尺寸（各家都支持的标准尺寸）。
    var size: CGSize? {
        switch self {
        case .original: return nil
        case .portrait: return CGSize(width: 1024, height: 1536)
        case .landscape: return CGSize(width: 1536, height: 1024)
        case .square: return CGSize(width: 1024, height: 1024)
        }
    }

    /// 写进指令里的说法。
    var instruction: String {
        switch self {
        case .original: return ""
        case .portrait: return "竖幅（2:3，竖着拿相机拍的）"
        case .landscape: return "横幅（3:2，横着拿相机拍的）"
        case .square: return "方形（1:1）"
        }
    }
}

/// 一次 AI 改图的结果，作为编辑历史里的一步。
/// 涂抹过区域时，只把该区域换成 AI 的结果，其余部分保持原图和原分辨率。
struct AIEdit {
    let result: CGImage
    let strokes: [MosaicStroke]
    /// 结果对应原图的哪一块（归一化坐标，原点左上角）。nil = 整张图。AI 美颜只送脸部时用它。
    var frame: CGRect? = nil
    /// 只采用这个椭圆范围内的结果（归一化坐标），边缘羽化。
    var ellipse: CGRect? = nil
    /// 0...1，AI 结果和原图的混合比例，在本机调，不用重新生成。
    var strength: CGFloat = 1
    /// 只采用 AI 的光影和颜色，细节用原图（修逆光、修过曝这类用）。
    var toneOnly = false
    /// 换了画幅的构图：结果整张替换原图，画面比例跟着 AI 的结果走。
    var reframed = false
    /// 0...1，把 AI 结果过头的锐化压下去，在本机调。
    var soften: CGFloat = 0
    /// 贴回原图的脸（整张重画的结果用）。
    var faces: [FaceKeep] = []
    /// 只在真正变了的地方用 AI 的像素（美体、去路人这类只动一部分的）。
    var changedOnly = false
    /// changedOnly 允许换的范围（人和周围一圈）；nil = 整张。
    var area: CGImage? = nil
    /// 换衣服：这一块一定用 AI 的（人身上、下巴以下）。
    var core: CGImage? = nil
    /// AI 图整体偏了多少（占宽高的比例，左上原点），对齐后再比较。
    var shift: CGVector = .zero
    /// 只取色彩时用的整图颜色表（大师、相机）：比局部跟光更自然，没有光晕。
    var lut: Data? = nil
    /// 最后再裁成这一块（归一化，左上原点）：大师构图从原图裁。
    var cropAfter: CGRect? = nil
    /// AI 的结果是黑白的：只取光影时把颜色也去掉。
    var mono = false
    /// 这一步是怎么发起的（套用到新照片时再跑一遍）；涂抹、融合出来的没有。
    var recipe: AIRecipe? = nil

    /// AI 出图常常锐化过头：和模糊过的自己混一下，边缘的白边和沙沙的纹理就下去了。
    static func softened(_ r: CIImage, amount: CGFloat) -> CIImage {
        guard amount > 0.005 else { return r }
        let e = r.extent
        let dim = max(e.width, e.height)
        let blurred = r.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: dim * (0.0006 + 0.0012 * amount)])
            .cropped(to: e)
        return FX.mix(r, blurred, t: min(1, amount * 0.9))
    }

    var hasRegion: Bool { strokes.contains { !$0.erase } }

    private func keepFaces(_ out: CIImage, original: CIImage) -> CIImage {
        var out = out
        for face in faces {
            out = face.apply(to: out, original: original)
        }
        if mono, !faces.isEmpty { out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
        return out
    }

    func apply(to image: CIImage) -> CIImage {
        let out = edited(image)
        guard let c = cropAfter else { return out }
        let e = out.extent
        let r = CGRect(x: e.minX + c.minX * e.width, y: e.maxY - c.maxY * e.height, width: c.width * e.width, height: c.height * e.height)
            .integral.intersection(e)
        return out.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
    }

    private func edited(_ image: CIImage) -> CIImage {
        let extent = image.extent
        if reframed {
            // 长边和原图一样长，比例按 AI 给的。
            let r = CIImage(cgImage: result)
            let k = max(extent.width, extent.height) / max(r.extent.width, r.extent.height)
            let w = (r.extent.width * k).rounded(), h = (r.extent.height * k).rounded()
            let out = r.transformed(by: CGAffineTransform(scaleX: w / r.extent.width, y: h / r.extent.height))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            return keepFaces(Self.softened(out, amount: soften), original: image)
        }
        var target = extent
        if let f = frame {
            target = CGRect(x: f.minX * extent.width, y: (1 - f.maxY) * extent.height,
                            width: f.width * extent.width, height: f.height * extent.height)
        }
        var r = CIImage(cgImage: result)
        r = r.transformed(by: CGAffineTransform(scaleX: target.width / r.extent.width,
                                                y: target.height / r.extent.height))
            .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            .transformed(by: CGAffineTransform(translationX: shift.dx * extent.width, y: -shift.dy * extent.height))
            .clampedToExtent()
            .cropped(to: extent)
        if changedOnly, !toneOnly {
            r = ChangeKeep.apply(original: image, ai: r, area: area.map { AIRegion.scaled(mask: $0, to: extent, feather: false) },
                                 core: core.map { AIRegion.scaled(mask: $0, to: extent, feather: false) })
        }
        if toneOnly {
            r = lut.map { StyleLUT.apply($0, to: image, strength: 1) } ?? ToneTransfer.apply(original: image, graded: r)
            if mono { r = r.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
            if let area {
                r = r.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: AIRegion.scaled(mask: area, to: extent, feather: false),
                ]).cropped(to: extent)
            }
        }
        if !(toneOnly && lut != nil) { r = Self.softened(r, amount: soften) }
        if !toneOnly { r = keepFaces(r, original: image) }

        var mask: CIImage?
        if let ellipse {
            mask = AIRegion.ellipseMask(ellipse, extent: extent)
        } else if hasRegion {
            mask = AIRegion.mask(strokes: strokes, extent: extent, feather: true)
        }
        guard var m = mask else {
            return strength >= 1 ? r : FX.mix(image, r, t: strength)
        }
        if strength < 1 {
            m = m.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
            ])
        }
        return r.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: m,
        ]).cropped(to: extent)
    }
}

/// 涂抹区域相关的图像处理。
enum AIRegion {
    /// AI 区域的笔画统一用这个样式，这样蒙版只有一张。
    static func stroke(points: [CGPoint], width: CGFloat, erase: Bool) -> MosaicStroke {
        MosaicStroke(points: points, width: width, erase: erase, style: .pixel, strength: 1)
    }

    static func maskImage(strokes: [MosaicStroke], width: Int, height: Int) -> CGImage? {
        let set = MosaicMaskSet(width: width, height: height)
        set.rebuild(strokes)
        return set.snapshot().first?.image
    }

    /// 白色 = 涂抹过的区域，已经缩放到 extent。
    static func mask(strokes: [MosaicStroke], extent: CGRect, feather: Bool) -> CIImage? {
        let scale = min(1, 2048 / max(extent.width, extent.height))
        guard let cg = maskImage(strokes: strokes,
                                 width: Int((extent.width * scale).rounded()),
                                 height: Int((extent.height * scale).rounded())) else { return nil }
        return scaled(mask: cg, to: extent, feather: feather)
    }

    static func scaled(mask cg: CGImage, to extent: CGRect, feather: Bool) -> CIImage {
        var m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        m = m.transformed(by: CGAffineTransform(scaleX: extent.width / m.extent.width,
                                                y: extent.height / m.extent.height))
        if feather {
            // 边缘羽化一点，AI 结果和原图的接缝才不明显。
            let radius = max(extent.width, extent.height) * 0.006
            m = m.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: extent)
        }
        return m
    }

    /// 羽化的椭圆蒙版：AI 美颜贴回脸部时用，接缝落在头发和脖子上才看不出来。
    static func ellipseMask(_ ellipse: CGRect, extent: CGRect) -> CIImage? {
        let scale = min(1, 1024 / max(extent.width, extent.height))
        let w = max(1, Int((extent.width * scale).rounded()))
        let h = max(1, Int((extent.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: ellipse.minX * CGFloat(w), y: (1 - ellipse.maxY) * CGFloat(h),
                                   width: ellipse.width * CGFloat(w), height: ellipse.height * CGFloat(h)))
        guard let cg = ctx.makeImage() else { return nil }
        var m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        m = m.transformed(by: CGAffineTransform(scaleX: extent.width / m.extent.width, y: extent.height / m.extent.height))
        let radius = min(ellipse.width * extent.width, ellipse.height * extent.height) * 0.08
        return m.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
    }

    /// 把涂抹区域用半透明红色标出来：既是屏幕上的预览，也是发给不支持蒙版的服务商的参考图。
    static func overlay(base: CIImage, mask cg: CGImage) -> CIImage {
        let extent = base.extent
        let red = CIImage(color: CIColor(red: 1, green: 0.1, blue: 0.2, alpha: 0.55)).cropped(to: extent)
        let tinted = red.composited(over: base)
        return tinted.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: base,
            kCIInputMaskImageKey: scaled(mask: cg, to: extent, feather: false),
        ]).cropped(to: extent)
    }
}

/// 准备请求 → 调接口 → 把结果对齐回原图。全部在后台线程跑。
enum AIRunner {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// OpenAI 固定支持的三种输出尺寸，选和原图比例最接近的。
    private static func openAISize(for extent: CGRect) -> CGSize {
        let sizes = [CGSize(width: 1024, height: 1024), CGSize(width: 1536, height: 1024), CGSize(width: 1024, height: 1536)]
        let aspect = extent.width / extent.height
        return sizes.min { abs(log(aspect / ($0.width / $0.height))) < abs(log(aspect / ($1.width / $1.height))) } ?? sizes[0]
    }

    /// crop 不为空时只把这一块（归一化坐标，原点左上角）发出去，返回的也是这一块的结果。
    /// 自定义输出尺寸：两边都是 16 的倍数，长边不超过 2048，总像素不少于接口下限。图本来就小的话返回 nil。
    private static func customSize(for extent: CGRect) -> CGSize? {
        let long = max(extent.width, extent.height)
        guard long > 1100 else { return nil }
        let scale = min(1, 2048 / long)
        func round16(_ v: CGFloat) -> CGFloat { max(16, (v * scale / 16).rounded() * 16) }
        let size = CGSize(width: round16(extent.width), height: round16(extent.height))
        let ratio = size.width / size.height
        guard size.width * size.height >= 655_360, ratio <= 3, ratio >= 1.0 / 3 else { return nil }
        return size
    }

    static func run(endpoint: AIEndpoint, prompt: String, proxy: CIImage, ops: [EditOp],
                    strokes: [MosaicStroke], crop: CGRect? = nil, appendGuidance: Bool = true,
                    reframe: AIReframe = .original, references: [UIImage] = []) async throws -> CGImage {
        var current = EditOp.apply(ops, to: proxy)
        if let target = reframe.size {
            return try await runReframed(endpoint: endpoint, prompt: prompt, image: current, target: target, reframe: reframe)
        }
        if let crop {
            let e = current.extent
            let r = CGRect(x: crop.minX * e.width, y: (1 - crop.maxY) * e.height,
                           width: crop.width * e.width, height: crop.height * e.height).integral.intersection(e)
            current = current.cropped(to: r).transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
        }
        let extent = current.extent
        let hasRegion = strokes.contains { !$0.erase }
        let context = Renderer.shared.context

        var text = prompt
        if appendGuidance {
            text += "\n\nEdit the provided photo as instructed above. Keep everything that is not mentioned unchanged: same framing, composition, people, pose and details. The result must look like a real photograph."
        }

        var endpoint = endpoint
        if endpoint.provider.supportsMask {
            // 把图补成接口要的尺寸（四周用边缘像素延伸），拿到结果后再把补的部分裁掉，
            // 这样结果和原图逐像素对齐，才能只替换涂抹的那一块。
            func attempt(_ target: CGSize) async throws -> CGImage {
                let s = min(target.width / extent.width, target.height / extent.height)
                let cw = (extent.width * s).rounded()
                let ch = (extent.height * s).rounded()
                let ox = ((target.width - cw) / 2).rounded(.down)
                let oy = ((target.height - ch) / 2).rounded(.down)
                let placed = current
                    .transformed(by: CGAffineTransform(scaleX: cw / extent.width, y: ch / extent.height))
                    .transformed(by: CGAffineTransform(translationX: ox, y: oy))
                let canvas = placed.clampedToExtent().cropped(to: CGRect(origin: .zero, size: target))
                guard let png = context.pngRepresentation(of: canvas, format: .RGBA8, colorSpace: sRGB) else {
                    throw AIError(text: "图片编码失败。")
                }
                // 上下左右对称留边，所以左上角坐标系里的内容区域也是 (ox, oy)。
                let content = CGRect(x: ox, y: oy, width: cw, height: ch)
                var mask: Data?
                var request = text
                if hasRegion {
                    mask = maskPNG(strokes: strokes, size: target, content: content)
                    request += " Apply the change only inside the masked (transparent) area and blend it seamlessly with the surroundings."
                }
                var payload = AIPayload(prompt: request, image: png, imageMime: "image/png", maskPNG: mask, markedJPEG: nil,
                                        size: "\(Int(target.width))x\(Int(target.height))")
                payload.extraImages = references.compactMap { AIOneShot.prepared($0, maxSide: 1024).pngData() }
                let data = try await AIClient.edit(endpoint, payload)
                guard let image = UIImage(data: data)?.cgImage else { throw AIError(text: "服务商返回的不是有效图片。") }
                let fx = CGFloat(image.width) / target.width
                let fy = CGFloat(image.height) / target.height
                let crop = CGRect(x: content.minX * fx, y: content.minY * fy,
                                  width: content.width * fx, height: content.height * fy).integral
                return try standalone(image.cropping(to: crop) ?? image)
            }

            // 高清输出：按这块图本身的大小要结果（长边最多 2048），脸贴回去才不会比周围糊。
            // 如果这个型号不接受自定义尺寸，就退回三种标准尺寸再发一次（被拒的那次不计费）。
            // 有的型号不认"高保真"这个参数：被拒就去掉它再发一次（被拒的那次不计费）。
            func attemptSafely(_ target: CGSize) async throws -> CGImage {
                do {
                    return try await attempt(target)
                } catch let error as AIError where endpoint.highFidelity && error.status == 400
                    && error.raw.lowercased().contains("fidelity") {
                    endpoint.highFidelity = false
                    return try await attempt(target)
                }
            }
            if endpoint.hires, endpoint.provider == .openai, let custom = customSize(for: extent) {
                do {
                    return try await attemptSafely(custom)
                } catch let error as AIError where error.status == 400 && error.raw.lowercased().contains("size") {
                    // 继续走标准尺寸
                }
            }
            return try await attemptSafely(openAISize(for: extent))
        }

        let small = Renderer.shared.downscaled(current, maxDimension: 2048)
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: small, colorSpace: sRGB, options: [quality: 0.92]) else {
            throw AIError(text: "图片编码失败。")
        }
        var marked: Data?
        if hasRegion, let cg = AIRegion.maskImage(strokes: strokes, width: Int(small.extent.width), height: Int(small.extent.height)) {
            marked = context.jpegRepresentation(of: AIRegion.overlay(base: small, mask: cg), colorSpace: sRGB, options: [quality: 0.9])
            text += " The second image is the same photo with the region to edit highlighted in red. Change only that region, and return the first photo edited, without any red marking."
        }
        var payload = AIPayload(prompt: text, image: jpeg, imageMime: "image/jpeg", maskPNG: nil, markedJPEG: marked, size: "auto")
        payload.extraImages = references.compactMap { AIOneShot.prepared($0, maxSide: 1024).jpegData(compressionQuality: 0.92) }
        let data = try await AIClient.edit(endpoint, payload)
        guard let image = UIImage(data: data)?.cgImage else { throw AIError(text: "服务商返回的不是有效图片。") }
        return try standalone(image)
    }

    /// 换画幅的构图：把原图居中放进新画幅，空出来的地方先用虚化放大的原图垫着，让 AI 整张重新构图。
    private static func runReframed(endpoint: AIEndpoint, prompt: String, image: CIImage, target: CGSize,
                                    reframe: AIReframe) async throws -> CGImage {
        let source = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let e = source.extent
        let canvasRect = CGRect(origin: .zero, size: target)
        // 垫底：原图放大铺满、虚化、压暗一点。
        let fill = max(target.width / e.width, target.height / e.height)
        let back = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            .transformed(by: CGAffineTransform(translationX: (target.width - e.width * fill) / 2,
                                               y: (target.height - e.height * fill) / 2))
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(target.width, target.height) * 0.03])
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08])
            .cropped(to: canvasRect)
        let fit = min(target.width / e.width, target.height / e.height)
        let front = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
            .transformed(by: CGAffineTransform(translationX: (target.width - e.width * fit) / 2,
                                               y: (target.height - e.height * fit) / 2))
        let canvas = front.composited(over: back).cropped(to: canvasRect)
        let text = prompt + "\n\n【画幅】输出一张\(reframe.instruction)的照片。给你的图里只有中间清楚的那一块是原照片，四周虚化的部分只是占位，不要保留虚化。" +
            "按上面的构图要求，在新画幅里重新安排画面：原图边缘以外缺的部分，按原场景合理地补全延伸（天空、地面、建筑、背景都要连贯真实）。" +
            "人物的长相、身材、姿势和服装不变，不要拉伸或压扁任何东西。结果必须是一张完整、清晰、真实的照片。"
        let context = Renderer.shared.context
        let data: Data?
        let mime: String
        if endpoint.provider.supportsMask {
            data = context.pngRepresentation(of: canvas, format: .RGBA8, colorSpace: sRGB)
            mime = "image/png"
        } else {
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            data = context.jpegRepresentation(of: canvas, colorSpace: sRGB, options: [quality: 0.92])
            mime = "image/jpeg"
        }
        guard let data else { throw AIError(text: "图片编码失败。") }
        let payload = AIPayload(prompt: text, image: data, imageMime: mime, maskPNG: nil, markedJPEG: nil,
                                size: "\(Int(target.width))x\(Int(target.height))")
        let out = try await AIClient.edit(endpoint, payload)
        guard let result = UIImage(data: out)?.cgImage else { throw AIError(text: "服务商返回的不是有效图片。") }
        return try standalone(result)
    }

    /// 把解码出来的图重新画成一张独立的 8 位 sRGB 位图。
    /// 服务商返回的图可能是延迟解码、16 位、带调色板，或者是裁剪出来的子图；
    /// 真机上 Core Image 直接读这类图时会读到无效内存而闪退，所以先规整成最普通的格式。
    private static func standalone(_ image: CGImage) throws -> CGImage {
        let w = image.width, h = image.height
        // 有的时候服务商会把蒙版区域原样留成透明，没有画任何东西。这种结果贴回去就是一块黑，直接当失败处理。
        if image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst, w > 0, h > 0 {
            let sw = min(w, 96), sh = min(h, 96)
            var pixels = [UInt8](repeating: 0, count: sw * sh * 4)
            let empty: Int = pixels.withUnsafeMutableBytes { buffer in
                guard let probe = CGContext(data: buffer.baseAddress, width: sw, height: sh, bitsPerComponent: 8,
                                            bytesPerRow: sw * 4, space: sRGB,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
                probe.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
                var n = 0
                for i in stride(from: 3, to: sw * sh * 4, by: 4) where buffer[i] < 128 { n += 1 }
                return n
            }
            if empty * 50 > sw * sh {
                throw AIError(text: "AI 返回的图片里有一块是空的，没有画上内容。可以再生成一次，或者换个说法、换一家服务商。")
            }
        }
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AIError(text: "服务商返回的图片无法处理。")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw AIError(text: "服务商返回的图片无法处理。") }
        return out
    }

    /// OpenAI 的蒙版：不透明 = 保持不动，透明 = 要修改。content 是原图在补边后画布里的位置（左上角坐标系）。
    private static func maskPNG(strokes: [MosaicStroke], size: CGSize, content: CGRect) -> Data? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: content.minX + p.x * content.width, y: CGFloat(h) - (content.minY + p.y * content.height))
        }
        for stroke in strokes {
            guard let first = stroke.points.first else { continue }
            let lw = max(1, stroke.width * max(content.width, content.height))
            ctx.setBlendMode(stroke.erase ? .normal : .clear)
            ctx.setStrokeColor(red: 0, green: 0, blue: 0, alpha: 1)
            ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
            if stroke.points.count == 1 {
                let c = map(first)
                ctx.fillEllipse(in: CGRect(x: c.x - lw / 2, y: c.y - lw / 2, width: lw, height: lw))
            } else {
                ctx.setLineWidth(lw)
                ctx.beginPath()
                ctx.move(to: map(first))
                for p in stroke.points.dropFirst() { ctx.addLine(to: map(p)) }
                ctx.strokePath()
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return UIImage(cgImage: image).pngData()
    }
}
