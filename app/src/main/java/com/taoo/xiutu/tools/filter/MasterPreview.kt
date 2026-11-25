package com.taoo.xiutu.tools.filter

import android.graphics.Bitmap
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.tools.color.ColorFx
import com.taoo.xiutu.tools.color.ColorParams
import com.taoo.xiutu.tools.color.V3

/**
 * 大师风格（以及 AI 相机质感、光线）按钮上的缩略图：在本机用一组调色参数模拟出大致的色调，只是给个印象。
 * 真正点下去是交给 AI 重新处理，结果不会和缩略图完全一样。按 AIPreset 的 title 对应。
 */
object MasterPreview {
    private fun make(title: String, vignette: Float = 0f, bloom: Float = 0f, configure: ColorParams.() -> Unit): Pair<String, FilmLook> =
        title to FilmLook("master-$title", title, LookCategory.MASTER, ColorParams().apply(configure), vignette, bloom)

    /** 相机质感按钮上的小图：沿用本机"相机"滤镜里对应的色调（没有对应的就单独配一组）。 */
    private val cameraLooks: List<Pair<String, FilmLook>> = run {
        val out = ArrayList<Pair<String, FilmLook>>()
        val mapped = listOf(
            "徕卡 M" to "leica", "徕卡黑白" to "leicabw", "徕卡 Q" to "leica", "哈苏中画幅" to "hassel",
            "富士经典正片" to "fujicn", "理光 GR" to "grpos", "理光黑白" to "grbw", "康泰时 T2" to "contax",
            "宾得 67" to "pentax67", "禄来双反" to "rollei", "CCD 卡片机" to "ccd",
        )
        for ((title, id) in mapped) FilmLook.byID[id]?.let { out += title to it }
        out += make("富士中画幅") {
            contrast = 0.05f; saturation = 0.08f; highlights = -0.2f; shadows = 0.12f; temperature = 0.03f
            shadowTint = V3(-0.004f, 0.006f, 0.01f)
        }
        out += make("佳能人像", bloom = 0.1f) {
            exposure = 0.08f; contrast = 0.08f; saturation = 0.1f; temperature = 0.07f; tint = 0.03f; shadows = 0.1f
        }
        out += make("尼康") {
            contrast = 0.18f; saturation = 0.05f; temperature = -0.04f; highlights = -0.15f; shadows = 0.1f
        }
        out += make("索尼") {
            contrast = 0.12f; vibrance = 0.12f; temperature = -0.06f; highlights = -0.1f
        }
        out += make("适马") {
            contrast = 0.3f; saturation = 0.3f; shadows = -0.1f; temperature = 0.02f
        }
        out += make("大光圈人像", vignette = 0.18f, bloom = 0.12f) {
            contrast = 0.1f; saturation = 0.05f; shadows = 0.08f; temperature = 0.03f
        }
        out += make("长焦压缩", vignette = 0.12f) {
            contrast = 0.2f; saturation = 0.08f; highlights = -0.1f
        }

        out
    }

    /** 光线按钮上的小图：只能模拟出大致的明暗和冷暖。 */
    private val lightLooks: List<Pair<String, FilmLook>> = listOf(
        make("自然补光", vignette = 0f, bloom = 0f) { shadows = 0.3f; exposure = 0.08f },
        make("窗边柔光", vignette = 0f, bloom = 0.1f) { contrast = -0.1f; shadows = 0.15f; temperature = -0.02f },
        make("伦勃朗光", vignette = 0.4f, bloom = 0f) { contrast = 0.3f; shadows = -0.3f; exposure = -0.1f },
        make("蝴蝶光", vignette = 0f, bloom = 0f) { exposure = 0.12f; contrast = 0.1f; highlights = 0.1f },
        make("侧光", vignette = 0.15f, bloom = 0f) { contrast = 0.4f; shadows = -0.25f },
        make("轮廓光", vignette = 0.2f, bloom = 0.15f) { contrast = 0.2f; highlights = 0.2f },
        make("日落逆光", vignette = 0f, bloom = 0.35f) { temperature = 0.2f; exposure = 0.1f; fade = 0.15f; highlightTint = V3(0.04f, 0.015f, -0.02f) },
        make("黄金时刻", vignette = 0f, bloom = 0.1f) { temperature = 0.22f; saturation = 0.1f; shadowTint = V3(-0.005f, 0.0f, 0.015f); highlightTint = V3(0.04f, 0.02f, -0.02f) },
        make("蓝调时刻", vignette = 0.15f, bloom = 0f) { temperature = -0.25f; exposure = -0.15f; saturation = -0.05f; shadowTint = V3(-0.01f, 0.0f, 0.03f) },
        make("阴天柔光", vignette = 0f, bloom = 0f) { contrast = -0.2f; saturation = -0.08f; temperature = -0.04f; shadows = 0.15f },
        make("正午阳光", vignette = 0f, bloom = 0f) { contrast = 0.25f; saturation = 0.15f; exposure = 0.08f },
        make("棚拍柔光", vignette = 0f, bloom = 0f) { exposure = 0.1f; contrast = 0.05f; shadows = 0.15f; saturation = -0.03f },
        make("环形灯", vignette = 0f, bloom = 0f) { exposure = 0.18f; shadows = 0.3f; contrast = -0.05f },
        make("电影青橙", vignette = 0.1f, bloom = 0f) { contrast = 0.2f; shadowTint = V3(-0.03f, 0.02f, 0.04f); highlightTint = V3(0.05f, 0.02f, -0.03f) },
        make("霓虹夜色", vignette = 0.3f, bloom = 0f) { exposure = -0.15f; contrast = 0.25f; saturation = 0.3f; shadowTint = V3(0.0f, 0.02f, 0.07f); highlightTint = V3(0.07f, -0.01f, 0.05f) },
        make("舞台聚光", vignette = 0.8f, bloom = 0f) { exposure = -0.2f; contrast = 0.45f; shadows = -0.5f },
        make("烛光", vignette = 0.6f, bloom = 0f) { temperature = 0.35f; exposure = -0.2f; contrast = 0.2f },
        make("月光", vignette = 0.3f, bloom = 0f) { temperature = -0.3f; exposure = -0.3f; saturation = -0.25f; contrast = 0.1f },
        make("丁达尔光", vignette = 0f, bloom = 0.4f) { fade = 0.2f; temperature = 0.08f; exposure = 0.05f },
        make("直闪", vignette = 0.45f, bloom = 0f) { exposure = 0.15f; contrast = 0.35f; shadows = -0.2f; temperature = -0.05f },
        make("低调暗光", vignette = 0.5f, bloom = 0f) { exposure = -0.3f; contrast = 0.35f; shadows = -0.4f },
        make("高调明亮", vignette = 0f, bloom = 0.1f) { exposure = 0.3f; contrast = -0.15f; shadows = 0.3f; fade = 0.1f },
        make("百叶窗光影", vignette = 0.1f, bloom = 0f) { contrast = 0.3f; temperature = 0.12f; shadows = -0.15f },
        make("树影光斑", vignette = 0f, bloom = 0.1f) { contrast = 0.2f; saturation = 0.1f; temperature = 0.05f; exposure = 0.05f },

    )

    val looks: Map<String, FilmLook> = (listOf(
            make("滨田英明", bloom = 0.15f) {
                exposure = 0.22f; contrast = -0.25f; shadows = 0.35f; highlights = -0.1f; saturation = -0.12f
                temperature = -0.03f; fade = 0.25f
                shadowTint = V3(-0.01f, 0.012f, 0.02f); highlightTint = V3(0.02f, 0.012f, -0.01f)
            },
            make("川内伦子", bloom = 0.3f) {
                exposure = 0.3f; contrast = -0.3f; shadows = 0.4f; saturation = -0.18f; fade = 0.35f
                temperature = -0.05f; tint = 0.05f
                shadowTint = V3(0.0f, 0.01f, 0.03f); highlightTint = V3(0.015f, 0.0f, 0.02f)
            },
            make("蜷川实花") {
                saturation = 0.55f; vibrance = 0.3f; contrast = 0.3f; tint = 0.12f
                shadowTint = V3(0.02f, -0.01f, 0.04f); highlightTint = V3(0.03f, 0.0f, 0.01f)
            },
            make("上田义彦", vignette = 0.3f) {
                exposure = -0.15f; contrast = 0.12f; saturation = -0.35f; shadows = -0.1f; highlights = -0.2f
                temperature = 0.04f; fade = 0.12f; shadowTint = V3(0.0f, 0.006f, 0.01f)
            },
            make("森山大道", vignette = 0.3f) {
                contrast = 0.55f; shadows = -0.35f; highlights = 0.15f; saturation = 0.15f
            },
            make("何藩", vignette = 0.35f) {
                contrast = 0.5f; shadows = -0.45f; temperature = 0.1f; shadowTint = V3(-0.02f, 0.005f, 0.02f); highlightTint = V3(0.04f, 0.02f, -0.02f)
            },
            make("布列松") {
                contrast = 0.16f; saturation = -0.18f; shadows = 0.04f
            },
            make("薇薇安·迈尔") {
                contrast = 0.14f; saturation = 0.1f; fade = 0.1f; temperature = 0.06f; highlightTint = V3(0.02f, 0.01f, -0.015f)
            },
            make("萨尔加多", vignette = 0.3f) {
                contrast = 0.4f; saturation = -0.12f; highlights = -0.25f; shadows = -0.12f; highlightTint = V3(0.035f, 0.02f, -0.015f)
            },
            make("安塞尔·亚当斯") {
                contrast = 0.3f; highlights = -0.15f; shadows = 0.1f; saturation = 0.08f; vibrance = 0.2f
            },
            make("莱博维茨", vignette = 0.35f) {
                contrast = 0.3f; saturation = -0.1f; shadows = -0.2f; temperature = 0.06f
                shadowTint = V3(0.0f, 0.01f, 0.02f); highlightTint = V3(0.025f, 0.012f, -0.01f)
            },
            make("林德伯格", vignette = 0.15f) {
                contrast = 0.1f; saturation = -0.28f; fade = 0.08f; highlights = -0.08f
            },
            make("阿维顿") {
                exposure = 0.2f; contrast = 0.22f; saturation = -0.05f; highlights = 0.2f
            },
            make("欧文·佩恩", vignette = 0.2f) {
                saturation = -0.55f; contrast = 0.2f; fade = 0.1f; temperature = 0.03f
                highlightTint = V3(0.01f, 0.008f, 0.0f)
            },
            make("牛顿") {
                contrast = 0.5f; shadows = -0.2f; saturation = 0.1f; highlights = 0.15f
            },
            make("麦柯里", vignette = 0.2f) {
                saturation = 0.3f; vibrance = 0.25f; contrast = 0.25f; temperature = 0.08f; shadows = -0.05f
            },
            make("索尔·雷特", bloom = 0.2f) {
                fade = 0.3f; saturation = -0.1f; contrast = -0.1f; temperature = 0.1f
                shadowTint = V3(0.015f, 0.0f, 0.01f); highlightTint = V3(0.03f, 0.01f, -0.02f)
            },
            make("埃格尔斯顿") {
                saturation = 0.35f; contrast = 0.2f; temperature = 0.05f; tint = 0.03f
                highlightTint = V3(0.02f, 0.0f, -0.01f)
            },
            make("蒂姆·沃克", bloom = 0.35f) {
                exposure = 0.15f; contrast = -0.15f; saturation = 0.05f; fade = 0.2f; temperature = 0.06f; tint = 0.06f
                highlightTint = V3(0.03f, 0.01f, 0.01f)
            },
            make("王家卫", vignette = 0.35f) {
                exposure = -0.1f; contrast = 0.35f; saturation = 0.2f
                shadowTint = V3(-0.03f, 0.03f, 0.02f); highlightTint = V3(0.05f, 0.015f, -0.03f)
            },
            make("岩井俊二", bloom = 0.4f) {
                exposure = 0.3f; contrast = -0.3f; fade = 0.4f; saturation = -0.15f
                shadowTint = V3(-0.005f, 0.015f, 0.025f); highlightTint = V3(0.02f, 0.012f, -0.005f)
            },
            make("韦斯·安德森") {
                exposure = 0.1f; contrast = -0.05f; saturation = 0.15f; temperature = 0.1f; tint = 0.06f; fade = 0.18f
                shadowTint = V3(0.02f, 0.0f, 0.01f); highlightTint = V3(0.03f, 0.015f, 0.0f)
            },
    
    ) + cameraLooks + lightLooks).toMap()

    /** 缩略图：居中裁成 68:84、长边 260，套上每个标题对应的色调。在后台线程调。 */
    fun thumbs(base: Bitmap, titles: Collection<String>): Map<String, Bitmap> {
        val small = Img.downscale(Img.centerCrop(base, 68f / 84f), 260)
        val list = titles.mapNotNull { t -> looks[t]?.let { t to it.look } }
        if (list.isEmpty()) return emptyMap()
        return ColorFx.thumbs(small, list)
    }
}
