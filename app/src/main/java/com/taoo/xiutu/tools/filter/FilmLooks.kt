package com.taoo.xiutu.tools.filter

import android.graphics.Bitmap
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.tools.color.ColorFx
import com.taoo.xiutu.tools.color.ColorParams
import com.taoo.xiutu.tools.color.Look
import com.taoo.xiutu.tools.color.V3

enum class LookCategory(val title: String) {
    CAMERA("相机"), FILMCAM("胶片相机"), INSTANT("拍立得"), NEGATIVE("彩色负片"), SLIDE("反转片"),
    MONO("黑白"), CINEMA("电影"), VINTAGE("复古"), MASTER("大师 AI"),
}

/**
 * 一款胶片风格：颜色部分在着色器里算，再叠加暗角、柔光。都是自己调的参数，不是任何厂商的官方配方。
 * 滤镜不自带颗粒：想要颗粒，用户自己在"调色 → 颗粒"里加。
 */
class FilmLook(
    val id: String,
    val name: String,
    val category: LookCategory,
    val color: ColorParams,
    val vignette: Float = 0f,
    val bloom: Float = 0f,
) {
    val look: Look get() = Look(color, vignette, bloom)

    fun apply(src: Bitmap, intensity: Float): Bitmap = ColorFx.apply(src, look, intensity)

    companion object {
        internal fun make(
            id: String, name: String, category: LookCategory, vignette: Float = 0f, bloom: Float = 0f,
            configure: ColorParams.() -> Unit,
        ) = FilmLook(id, name, category, ColorParams().apply(configure), vignette, bloom)

        val all: List<FilmLook> = listOf(
            // 相机风格：按各家相机公认的成像特点自己调的近似效果，不是厂商的官方色彩配置。
            make("leica", "徕卡风", LookCategory.CAMERA, vignette = 0.22f) {
                // 反差扎实、暗部深、颜色克制偏暖。
                contrast = 0.38f; saturation = -0.12f; shadows = -0.18f; highlights = -0.12f; temperature = 0.06f
                shadowTint = V3(-0.008f, 0.0f, 0.012f); highlightTint = V3(0.02f, 0.012f, -0.012f)
            },
            make("leicabw", "徕卡黑白", LookCategory.CAMERA, vignette = 0.25f) {
                mono = true; monoWeights = V3(0.36f, 0.52f, 0.12f); contrast = 0.6f; shadows = -0.25f; highlights = -0.1f
            },
            make("hassel", "哈苏风", LookCategory.CAMERA) {
                // 自然色彩：干净、过渡柔和、高光不刺眼。
                contrast = 0.1f; saturation = 0.04f; vibrance = 0.1f; highlights = -0.3f; shadows = 0.18f; temperature = 0.03f
                highlightTint = V3(0.008f, 0.006f, 0.0f)
            },
            make("contax", "康泰时 T2 风", LookCategory.CAMERA, vignette = 0.18f) {
                // 蔡司味：通透偏冷、蓝色浓、反差高。
                contrast = 0.32f; saturation = 0.14f; temperature = -0.08f; tint = -0.03f
                shadowTint = V3(-0.015f, 0.0f, 0.03f); highlightTint = V3(0.012f, 0.01f, 0.0f)
            },
            make("grpos", "理光 GR 正片", LookCategory.CAMERA, vignette = 0.15f) {
                contrast = 0.48f; saturation = 0.22f; shadows = -0.22f; temperature = -0.04f
                shadowTint = V3(-0.01f, 0.005f, 0.025f)
            },
            make("grbw", "理光 GR 黑白", LookCategory.CAMERA, vignette = 0.3f) {
                mono = true; monoWeights = V3(0.45f, 0.45f, 0.1f); contrast = 0.9f; shadows = -0.5f; highlights = 0.2f
            },
            make("fujicn", "富士经典负片", LookCategory.CAMERA) {
                contrast = 0.3f; saturation = -0.18f; highlights = -0.2f; tint = -0.05f; fade = 0.03f
                shadowTint = V3(-0.012f, 0.018f, 0.02f); highlightTint = V3(0.03f, 0.012f, -0.02f)
            },
            make("rollei", "禄来双反", LookCategory.CAMERA, vignette = 0.3f, bloom = 0.25f) {
                contrast = -0.05f; saturation = -0.2f; fade = 0.1f; temperature = 0.1f; brightness = 0.06f
                shadowTint = V3(0.012f, 0.006f, -0.01f); highlightTint = V3(0.025f, 0.018f, -0.015f)
            },
            make("seagull", "海鸥老相机", LookCategory.CAMERA, vignette = 0.42f, bloom = 0.2f) {
                contrast = -0.12f; saturation = -0.35f; fade = 0.2f; temperature = 0.2f; tint = 0.06f
                shadowTint = V3(0.02f, 0.01f, -0.015f); highlightTint = V3(0.04f, 0.03f, -0.03f)
            },
            make("lomo", "LOMO", LookCategory.CAMERA, vignette = 0.7f) {
                contrast = 0.5f; saturation = 0.38f; tint = -0.08f
                shadowTint = V3(-0.02f, 0.01f, 0.05f); highlightTint = V3(0.05f, 0.04f, -0.04f)
            },
            make("ccd", "CCD 数码", LookCategory.CAMERA, bloom = 0.2f) {
                // 2000f 年代小数码：偏冷、偏亮、颜色艳、高光容易溢出。
                exposure = 0.12f; contrast = 0.22f; saturation = 0.2f; temperature = -0.14f; highlights = 0.25f
                shadowTint = V3(-0.01f, 0.0f, 0.025f)
            },
            make("disposable", "一次性相机", LookCategory.CAMERA, vignette = 0.35f) {
                contrast = 0.25f; saturation = 0.12f; temperature = 0.16f; tint = -0.06f; fade = 0.1f
                shadowTint = V3(-0.01f, 0.02f, 0.01f); highlightTint = V3(0.04f, 0.02f, -0.03f)
            },
            // 胶片相机：按这些老相机常见的成片感觉调的近似效果。只能模拟色彩、影调和暗角，镜头的虚化模拟不了。
            make("nikonf", "尼康 F", LookCategory.FILMCAM, vignette = 0.22f) {
                // 60f 年代新闻纪实的味道：扎实的反差，偏暖。
                contrast = 0.36f; saturation = 0.06f; temperature = 0.1f; shadows = -0.15f; fade = 0.04f
                shadowTint = V3(0.0f, 0.004f, 0.012f); highlightTint = V3(0.03f, 0.015f, -0.02f)
            },
            make("nikonfm2", "尼康 FM2", LookCategory.FILMCAM, vignette = 0.12f) {
                contrast = 0.26f; saturation = 0.14f; temperature = 0.03f
                shadowTint = V3(-0.008f, 0.004f, 0.015f); highlightTint = V3(0.015f, 0.01f, -0.008f)
            },
            make("canonae1", "佳能 AE-1", LookCategory.FILMCAM, vignette = 0.15f, bloom = 0.15f) {
                // 暖、柔、红色讨喜。
                contrast = 0.12f; saturation = 0.1f; temperature = 0.16f; fade = 0.07f; highlights = -0.1f
                highlightTint = V3(0.035f, 0.015f, -0.02f)
            },
            make("minoltax700", "美能达 X-700", LookCategory.FILMCAM, vignette = 0.14f) {
                contrast = 0.15f; saturation = 0.05f; temperature = 0.08f; tint = -0.04f; fade = 0.06f
                shadowTint = V3(-0.006f, 0.012f, 0.008f); highlightTint = V3(0.02f, 0.015f, -0.01f)
            },
            make("olympusom1", "奥林巴斯 OM-1", LookCategory.FILMCAM, vignette = 0.1f) {
                contrast = 0.22f; saturation = 0.02f; temperature = -0.05f; highlights = -0.12f
                shadowTint = V3(-0.01f, 0.0f, 0.02f)
            },
            make("mju", "奥林巴斯 mju", LookCategory.FILMCAM, vignette = 0.32f) {
                // 傻瓜机直闪：亮、硬、四角暗。
                exposure = 0.08f; contrast = 0.32f; saturation = 0.16f; temperature = 0.06f; tint = -0.05f
                shadowTint = V3(-0.01f, 0.015f, 0.02f)
            },
            make("yashicat4", "雅西卡 T4", LookCategory.FILMCAM, vignette = 0.26f) {
                contrast = 0.4f; saturation = 0.22f; temperature = -0.04f
                shadowTint = V3(-0.015f, 0.005f, 0.03f); highlightTint = V3(0.02f, 0.012f, -0.01f)
            },
            make("pentax67", "宾得 67", LookCategory.FILMCAM, vignette = 0.1f, bloom = 0.12f) {
                // 中画幅：过渡细腻，肤色奶油感。
                contrast = 0.08f; saturation = 0.02f; temperature = 0.08f; highlights = -0.28f; shadows = 0.16f; fade = 0.05f
                shadowTint = V3(0.0f, 0.008f, 0.01f); highlightTint = V3(0.025f, 0.015f, -0.01f)
            },
            make("rz67", "玛米亚 RZ67", LookCategory.FILMCAM, bloom = 0.1f) {
                contrast = 0.02f; saturation = -0.06f; brightness = 0.1f; highlights = -0.25f; shadows = 0.2f; fade = 0.08f
                shadowTint = V3(-0.004f, 0.01f, 0.014f); highlightTint = V3(0.02f, 0.012f, 0.0f)
            },
            make("holga", "Holga 玩具机", LookCategory.FILMCAM, vignette = 0.8f, bloom = 0.45f) {
                contrast = 0.3f; saturation = 0.25f; fade = 0.1f; tint = 0.05f
                shadowTint = V3(0.01f, -0.005f, 0.035f); highlightTint = V3(0.04f, 0.03f, -0.03f)
            },
            make("lf45", "大画幅 4×5", LookCategory.FILMCAM, vignette = 0.18f) {
                // 抽插片的座机：影调极其平滑，颜色沉稳。
                contrast = 0.1f; saturation = -0.04f; highlights = -0.35f; shadows = 0.25f; vibrance = 0.08f; temperature = 0.03f
                shadowTint = V3(0.0f, 0.004f, 0.008f); highlightTint = V3(0.012f, 0.008f, 0.0f)
            },
            make("lf810bw", "大画幅黑白", LookCategory.FILMCAM, vignette = 0.22f) {
                mono = true; monoWeights = V3(0.3f, 0.55f, 0.15f); contrast = 0.3f; highlights = -0.25f; shadows = 0.18f
                shadowTint = V3(0.004f, 0.002f, 0.0f); highlightTint = V3(0.01f, 0.008f, 0.0f)
            },
            make("wetplate", "湿版老照片", LookCategory.FILMCAM, vignette = 0.75f, bloom = 0.2f) {
                // 19f 世纪火棉胶湿版：只对蓝光敏感，肤色发深，反差硬，四角很暗。
                mono = true; monoWeights = V3(0.08f, 0.32f, 0.6f); contrast = 0.55f; fade = 0.08f; shadows = -0.2f
                shadowTint = V3(0.02f, 0.012f, 0.0f); highlightTint = V3(0.03f, 0.025f, 0.01f)
            },
            // 彩色负片
            make("ektar", "柯达 Ektar 风", LookCategory.NEGATIVE) {
                contrast = 0.3f; saturation = 0.32f; vibrance = 0.15f
                shadowTint = V3(-0.012f, 0.0f, 0.025f); highlightTint = V3(0.02f, 0.008f, -0.01f)
            },
            make("gold200", "暖金 200", LookCategory.NEGATIVE) {
                temperature = 0.25f; contrast = 0.2f; saturation = 0.12f; fade = 0.08f
                shadowTint = V3(0.01f, 0.0f, -0.02f); highlightTint = V3(0.03f, 0.015f, -0.03f)
            },
            make("portrait160", "人像 160", LookCategory.NEGATIVE) {
                contrast = -0.1f; saturation = -0.08f; fade = 0.1f; temperature = 0.08f; brightness = 0.1f
                shadowTint = V3(0.0f, 0.01f, 0.015f); highlightTint = V3(0.02f, 0.01f, 0.0f)
            },
            make("portrait400", "人像 400", LookCategory.NEGATIVE) {
                contrast = 0.1f; saturation = 0.02f; temperature = 0.12f; fade = 0.06f; shadows = 0.2f
                shadowTint = V3(-0.005f, 0.008f, 0.012f); highlightTint = V3(0.025f, 0.012f, -0.01f)
            },
            make("green400", "翠绿 400", LookCategory.NEGATIVE) {
                temperature = -0.08f; tint = -0.12f; contrast = 0.25f; saturation = 0.1f
                shadowTint = V3(-0.015f, 0.02f, 0.01f); highlightTint = V3(0.01f, 0.01f, -0.01f)
            },
            make("fresh", "清新日系", LookCategory.NEGATIVE) {
                brightness = 0.25f; contrast = -0.2f; fade = 0.14f; saturation = -0.12f; temperature = -0.1f
                shadowTint = V3(-0.01f, 0.015f, 0.03f)
            },
            make("night800", "夜景 800", LookCategory.NEGATIVE, bloom = 0.5f) {
                temperature = -0.3f; contrast = 0.25f; saturation = 0.1f
                shadowTint = V3(-0.02f, 0.01f, 0.04f); highlightTint = V3(0.05f, 0.0f, -0.01f)
            },
            // 反转片
            make("kchrome", "柯达克罗姆风", LookCategory.SLIDE, vignette = 0.15f) {
                // 红和黄浓郁、反差大、暗部深。
                contrast = 0.42f; saturation = 0.2f; temperature = 0.1f; shadows = -0.25f; highlights = -0.1f
                shadowTint = V3(-0.005f, -0.005f, 0.02f); highlightTint = V3(0.035f, 0.015f, -0.025f)
            },
            make("vivid50", "浓郁 50", LookCategory.SLIDE) {
                contrast = 0.45f; saturation = 0.4f; vibrance = 0.2f; shadows = -0.2f
                shadowTint = V3(0.0f, 0.0f, 0.015f)
            },
            make("slide100", "正片 100", LookCategory.SLIDE) {
                contrast = 0.3f; saturation = 0.15f; temperature = -0.04f
            },
            make("chrome", "经典铬", LookCategory.SLIDE) {
                contrast = 0.3f; saturation = -0.25f; fade = 0.04f; highlights = -0.3f
                shadowTint = V3(-0.01f, 0.01f, 0.02f); highlightTint = V3(0.015f, 0.01f, -0.01f)
            },
            // 黑白
            make("trix", "柯达 Tri-X 风", LookCategory.MONO, vignette = 0.15f) {
                mono = true; monoWeights = V3(0.34f, 0.5f, 0.16f); contrast = 0.62f; shadows = -0.2f
            },
            make("hp5", "伊尔福 HP5 风", LookCategory.MONO) {
                mono = true; contrast = 0.25f; shadows = 0.15f; highlights = -0.15f; fade = 0.03f
            },
            make("bw400", "黑白 400", LookCategory.MONO) {
                mono = true; contrast = 0.45f
            },
            make("bwsoft", "柔和黑白", LookCategory.MONO) {
                mono = true; contrast = -0.05f; fade = 0.1f; brightness = 0.1f
            },
            make("bwhard", "高反差", LookCategory.MONO) {
                mono = true; monoWeights = V3(0.5f, 0.4f, 0.1f); contrast = 0.8f; shadows = -0.4f
            },
            make("sepia", "棕褐", LookCategory.MONO) {
                mono = true; fade = 0.06f; contrast = 0.1f
                shadowTint = V3(0.03f, 0.01f, -0.02f); highlightTint = V3(0.04f, 0.02f, -0.03f)
            },
            // 电影
            make("cine800t", "电影卷 800T", LookCategory.CINEMA, bloom = 0.6f) {
                // 灯光片：整体偏青蓝，亮部带一点红晕。
                temperature = -0.22f; tint = -0.04f; contrast = 0.2f; saturation = 0.08f; fade = 0.05f
                shadowTint = V3(-0.025f, 0.012f, 0.04f); highlightTint = V3(0.06f, 0.01f, 0.0f)
            },
            make("tealorange", "青橙", LookCategory.CINEMA) {
                contrast = 0.3f; saturation = 0.05f
                shadowTint = V3(-0.04f, 0.01f, 0.045f); highlightTint = V3(0.05f, 0.02f, -0.04f)
            },
            make("print", "影院拷贝", LookCategory.CINEMA, vignette = 0.25f) {
                contrast = 0.4f; saturation = -0.1f; fade = 0.03f
                shadowTint = V3(-0.02f, 0.0f, 0.03f); highlightTint = V3(0.03f, 0.02f, -0.03f)
            },
            make("lowkey", "暗调", LookCategory.CINEMA, vignette = 0.4f) {
                exposure = -0.2f; contrast = 0.35f; saturation = -0.2f
                shadowTint = V3(-0.01f, 0.015f, 0.02f)
            },
            // 复古
            make("faded", "褪色", LookCategory.VINTAGE) {
                fade = 0.22f; contrast = -0.15f; saturation = -0.25f; temperature = 0.1f
            },
            make("expired", "过期胶片", LookCategory.VINTAGE, vignette = 0.3f) {
                tint = 0.2f; temperature = 0.1f; fade = 0.15f
                shadowTint = V3(0.02f, -0.01f, 0.03f); highlightTint = V3(0.02f, 0.03f, -0.02f)
            },
            make("instant", "拍立得", LookCategory.VINTAGE, vignette = 0.2f) {
                contrast = -0.1f; fade = 0.12f; brightness = 0.1f; saturation = -0.05f
                shadowTint = V3(-0.02f, 0.01f, 0.03f); highlightTint = V3(0.04f, 0.03f, -0.02f)
            },
        )

        val byID: Map<String, FilmLook> = all.associateBy { it.id }
    }
}

/** 滤镜确认后的一步。 */
class LookOp(val id: String, val intensity: Float) : EditOp {
    override val colors: Boolean get() = true
    override fun apply(src: Bitmap): Bitmap = FilmLook.byID[id]?.apply(src, intensity) ?: src
}
