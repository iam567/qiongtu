import CoreImage
import simd

/// 大师风格按钮上的缩略图：在本机用一组调色参数模拟出这位摄影师大致的色调，只是给个印象。
/// 真正点下去是把图交给 AI 按指令重新处理光线和色彩，结果不会和缩略图完全一样。
enum MasterPreview {
    private static func make(_ title: String, vignette: CGFloat = 0, bloom: CGFloat = 0,
                             _ configure: (inout ColorParams) -> Void) -> (String, FilmLook) {
        var color = ColorParams()
        configure(&color)
        return (title, FilmLook(id: "master-" + title, name: title, category: .master, color: color,
                                vignette: vignette, bloom: bloom))
    }

    /// 按 AIPresetGroup.master 里的名字对应。
    static let looks: [String: FilmLook] = Dictionary(uniqueKeysWithValues: [
        make("滨田英明", bloom: 0.15) { c in
            c.exposure = 0.22; c.contrast = -0.25; c.shadows = 0.35; c.highlights = -0.1; c.saturation = -0.12
            c.temperature = -0.03; c.fade = 0.25
            c.shadowTint = SIMD3(-0.01, 0.012, 0.02); c.highlightTint = SIMD3(0.02, 0.012, -0.01)
        },
        make("川内伦子", bloom: 0.3) { c in
            c.exposure = 0.3; c.contrast = -0.3; c.shadows = 0.4; c.saturation = -0.18; c.fade = 0.35
            c.temperature = -0.05; c.tint = 0.05
            c.shadowTint = SIMD3(0.0, 0.01, 0.03); c.highlightTint = SIMD3(0.015, 0.0, 0.02)
        },
        make("蜷川实花") { c in
            c.saturation = 0.55; c.vibrance = 0.3; c.contrast = 0.3; c.tint = 0.12
            c.shadowTint = SIMD3(0.02, -0.01, 0.04); c.highlightTint = SIMD3(0.03, 0.0, 0.01)
        },
        make("上田义彦", vignette: 0.3) { c in
            c.exposure = -0.15; c.contrast = 0.12; c.saturation = -0.35; c.shadows = -0.1; c.highlights = -0.2
            c.temperature = 0.04; c.fade = 0.12; c.shadowTint = SIMD3(0.0, 0.006, 0.01)
        },
        make("森山大道", vignette: 0.3) { c in
            c.contrast = 0.55; c.shadows = -0.35; c.highlights = 0.15; c.saturation = 0.15
        },
        make("何藩", vignette: 0.35) { c in
            c.contrast = 0.5; c.shadows = -0.45; c.temperature = 0.1; c.shadowTint = SIMD3(-0.02, 0.005, 0.02); c.highlightTint = SIMD3(0.04, 0.02, -0.02)
        },
        make("布列松") { c in
            c.contrast = 0.16; c.saturation = -0.18; c.shadows = 0.04
        },
        make("薇薇安·迈尔") { c in
            c.contrast = 0.14; c.saturation = 0.1; c.fade = 0.1; c.temperature = 0.06; c.highlightTint = SIMD3(0.02, 0.01, -0.015)
        },
        make("萨尔加多", vignette: 0.3) { c in
            c.contrast = 0.4; c.saturation = -0.12; c.highlights = -0.25; c.shadows = -0.12; c.highlightTint = SIMD3(0.035, 0.02, -0.015)
        },
        make("安塞尔·亚当斯") { c in
            c.contrast = 0.3; c.highlights = -0.15; c.shadows = 0.1; c.saturation = 0.08; c.vibrance = 0.2
        },
        make("莱博维茨", vignette: 0.35) { c in
            c.contrast = 0.3; c.saturation = -0.1; c.shadows = -0.2; c.temperature = 0.06
            c.shadowTint = SIMD3(0.0, 0.01, 0.02); c.highlightTint = SIMD3(0.025, 0.012, -0.01)
        },
        make("林德伯格", vignette: 0.15) { c in
            c.contrast = 0.1; c.saturation = -0.28; c.fade = 0.08; c.highlights = -0.08
        },
        make("阿维顿") { c in
            c.exposure = 0.2; c.contrast = 0.22; c.saturation = -0.05; c.highlights = 0.2
        },
        make("欧文·佩恩", vignette: 0.2) { c in
            c.saturation = -0.55; c.contrast = 0.2; c.fade = 0.1; c.temperature = 0.03
            c.highlightTint = SIMD3(0.01, 0.008, 0.0)
        },
        make("牛顿") { c in
            c.contrast = 0.5; c.shadows = -0.2; c.saturation = 0.1; c.highlights = 0.15
        },
        make("麦柯里", vignette: 0.2) { c in
            c.saturation = 0.3; c.vibrance = 0.25; c.contrast = 0.25; c.temperature = 0.08; c.shadows = -0.05
        },
        make("索尔·雷特", bloom: 0.2) { c in
            c.fade = 0.3; c.saturation = -0.1; c.contrast = -0.1; c.temperature = 0.1
            c.shadowTint = SIMD3(0.015, 0.0, 0.01); c.highlightTint = SIMD3(0.03, 0.01, -0.02)
        },
        make("埃格尔斯顿") { c in
            c.saturation = 0.35; c.contrast = 0.2; c.temperature = 0.05; c.tint = 0.03
            c.highlightTint = SIMD3(0.02, 0.0, -0.01)
        },
        make("蒂姆·沃克", bloom: 0.35) { c in
            c.exposure = 0.15; c.contrast = -0.15; c.saturation = 0.05; c.fade = 0.2; c.temperature = 0.06; c.tint = 0.06
            c.highlightTint = SIMD3(0.03, 0.01, 0.01)
        },
        make("王家卫", vignette: 0.35) { c in
            c.exposure = -0.1; c.contrast = 0.35; c.saturation = 0.2
            c.shadowTint = SIMD3(-0.03, 0.03, 0.02); c.highlightTint = SIMD3(0.05, 0.015, -0.03)
        },
        make("岩井俊二", bloom: 0.4) { c in
            c.exposure = 0.3; c.contrast = -0.3; c.fade = 0.4; c.saturation = -0.15
            c.shadowTint = SIMD3(-0.005, 0.015, 0.025); c.highlightTint = SIMD3(0.02, 0.012, -0.005)
        },
        make("韦斯·安德森") { c in
            c.exposure = 0.1; c.contrast = -0.05; c.saturation = 0.15; c.temperature = 0.1; c.tint = 0.06; c.fade = 0.18
            c.shadowTint = SIMD3(0.02, 0.0, 0.01); c.highlightTint = SIMD3(0.03, 0.015, 0.0)
        },
    ] + cameraLooks + lightLooks)

    /// 相机质感按钮上的小图：沿用本机"相机"滤镜里对应的色调（没有对应的就单独配一组）。
    private static let cameraLooks: [(String, FilmLook)] = {
        var out: [(String, FilmLook)] = []
        let mapped: [(String, String)] = [
            ("徕卡 M", "leica"), ("徕卡黑白", "leicabw"), ("徕卡 Q", "leica"), ("哈苏中画幅", "hassel"),
            ("富士经典正片", "fujicn"), ("理光 GR", "grpos"), ("理光黑白", "grbw"), ("康泰时 T2", "contax"),
            ("宾得 67", "pentax67"), ("禄来双反", "rollei"), ("CCD 卡片机", "ccd"),
        ]
        for (title, id) in mapped {
            if let look = FilmLook.byID[id] { out.append((title, look)) }
        }
        out.append(make("富士中画幅") { c in
            c.contrast = 0.05; c.saturation = 0.08; c.highlights = -0.2; c.shadows = 0.12; c.temperature = 0.03
            c.shadowTint = SIMD3(-0.004, 0.006, 0.01)
        })
        out.append(make("佳能人像", bloom: 0.1) { c in
            c.exposure = 0.08; c.contrast = 0.08; c.saturation = 0.1; c.temperature = 0.07; c.tint = 0.03; c.shadows = 0.1
        })
        out.append(make("尼康") { c in
            c.contrast = 0.18; c.saturation = 0.05; c.temperature = -0.04; c.highlights = -0.15; c.shadows = 0.1
        })
        out.append(make("索尼") { c in
            c.contrast = 0.12; c.vibrance = 0.12; c.temperature = -0.06; c.highlights = -0.1
        })
        out.append(make("适马") { c in
            c.contrast = 0.3; c.saturation = 0.3; c.shadows = -0.1; c.temperature = 0.02
        })
        out.append(make("大光圈人像", vignette: 0.18, bloom: 0.12) { c in
            c.contrast = 0.1; c.saturation = 0.05; c.shadows = 0.08; c.temperature = 0.03
        })
        out.append(make("长焦压缩", vignette: 0.12) { c in
            c.contrast = 0.2; c.saturation = 0.08; c.highlights = -0.1
        })
        return out
    }()

    /// 光线按钮上的小图：只能模拟出大致的明暗和冷暖，光的方向和形状要 AI 生成后才有。
    private static let lightLooks: [(String, FilmLook)] = [
        make("自然补光", vignette: 0, bloom: 0) { c in c.shadows = 0.3; c.exposure = 0.08 },
        make("窗边柔光", vignette: 0, bloom: 0.1) { c in c.contrast = -0.1; c.shadows = 0.15; c.temperature = -0.02 },
        make("伦勃朗光", vignette: 0.4, bloom: 0) { c in c.contrast = 0.3; c.shadows = -0.3; c.exposure = -0.1 },
        make("蝴蝶光", vignette: 0, bloom: 0) { c in c.exposure = 0.12; c.contrast = 0.1; c.highlights = 0.1 },
        make("侧光", vignette: 0.15, bloom: 0) { c in c.contrast = 0.4; c.shadows = -0.25 },
        make("轮廓光", vignette: 0.2, bloom: 0.15) { c in c.contrast = 0.2; c.highlights = 0.2 },
        make("日落逆光", vignette: 0, bloom: 0.35) { c in c.temperature = 0.2; c.exposure = 0.1; c.fade = 0.15; c.highlightTint = SIMD3(0.04, 0.015, -0.02) },
        make("黄金时刻", vignette: 0, bloom: 0.1) { c in c.temperature = 0.22; c.saturation = 0.1; c.shadowTint = SIMD3(-0.005, 0.0, 0.015); c.highlightTint = SIMD3(0.04, 0.02, -0.02) },
        make("蓝调时刻", vignette: 0.15, bloom: 0) { c in c.temperature = -0.25; c.exposure = -0.15; c.saturation = -0.05; c.shadowTint = SIMD3(-0.01, 0.0, 0.03) },
        make("阴天柔光", vignette: 0, bloom: 0) { c in c.contrast = -0.2; c.saturation = -0.08; c.temperature = -0.04; c.shadows = 0.15 },
        make("正午阳光", vignette: 0, bloom: 0) { c in c.contrast = 0.25; c.saturation = 0.15; c.exposure = 0.08 },
        make("棚拍柔光", vignette: 0, bloom: 0) { c in c.exposure = 0.1; c.contrast = 0.05; c.shadows = 0.15; c.saturation = -0.03 },
        make("环形灯", vignette: 0, bloom: 0) { c in c.exposure = 0.18; c.shadows = 0.3; c.contrast = -0.05 },
        make("电影青橙", vignette: 0.1, bloom: 0) { c in c.contrast = 0.2; c.shadowTint = SIMD3(-0.03, 0.02, 0.04); c.highlightTint = SIMD3(0.05, 0.02, -0.03) },
        make("霓虹夜色", vignette: 0.3, bloom: 0) { c in c.exposure = -0.15; c.contrast = 0.25; c.saturation = 0.3; c.shadowTint = SIMD3(0.0, 0.02, 0.07); c.highlightTint = SIMD3(0.07, -0.01, 0.05) },
        make("舞台聚光", vignette: 0.8, bloom: 0) { c in c.exposure = -0.2; c.contrast = 0.45; c.shadows = -0.5 },
        make("烛光", vignette: 0.6, bloom: 0) { c in c.temperature = 0.35; c.exposure = -0.2; c.contrast = 0.2 },
        make("月光", vignette: 0.3, bloom: 0) { c in c.temperature = -0.3; c.exposure = -0.3; c.saturation = -0.25; c.contrast = 0.1 },
        make("丁达尔光", vignette: 0, bloom: 0.4) { c in c.fade = 0.2; c.temperature = 0.08; c.exposure = 0.05 },
        make("直闪", vignette: 0.45, bloom: 0) { c in c.exposure = 0.15; c.contrast = 0.35; c.shadows = -0.2; c.temperature = -0.05 },
        make("低调暗光", vignette: 0.5, bloom: 0) { c in c.exposure = -0.3; c.contrast = 0.35; c.shadows = -0.4 },
        make("高调明亮", vignette: 0, bloom: 0.1) { c in c.exposure = 0.3; c.contrast = -0.15; c.shadows = 0.3; c.fade = 0.1 },
        make("百叶窗光影", vignette: 0.1, bloom: 0) { c in c.contrast = 0.3; c.temperature = 0.12; c.shadows = -0.15 },
        make("树影光斑", vignette: 0, bloom: 0.1) { c in c.contrast = 0.2; c.saturation = 0.1; c.temperature = 0.05; c.exposure = 0.05 },
    ]
}
