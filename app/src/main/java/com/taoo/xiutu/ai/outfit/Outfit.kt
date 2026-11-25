package com.taoo.xiutu.ai.outfit

import android.content.Context
import androidx.compose.ui.graphics.Color
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 换衣服的一种款式（assets/outfits.json，和 iOS 共用一份）。 */
@Serializable
data class Outfit(
    val group: String,
    val title: String,
    /** 小图的剪影。 */
    val shape: String,
    val prompt: String,
    /** 推荐颜色，第一个是默认的。 */
    val colors: List<String>,
    /** 有没有裙摆可以选。 */
    val skirt: Boolean,
    val male: Boolean,
)

enum class OutfitSkirt(val title: String, val prompt: String) {
    NORMAL("正常", ""),
    TRAIN("拖尾", "裙摆在身后拖出长长的一段，自然铺在地上。"),
    OVERFLOW(
        "溢出画面",
        "裙摆做得极大，朝镜头方向铺开，占满画面下方三分之一到一半，从画面的左右两边和下边溢出去，近大远小，近处的布料褶皱和装饰清晰巨大，有强烈的视觉冲击；裙摆自然盖在地面和近处的东西上。",
    ),
}

object OutfitCatalog {
    @Serializable
    private class FileData(val colors: Map<String, String>, val outfits: List<Outfit>)

    private val json = Json { ignoreUnknownKeys = true }
    private var colors: Map<String, String> = emptyMap()
    var all: List<Outfit> = emptyList()
        private set

    /** App 启动时调用一次。 */
    fun init(context: Context) {
        if (all.isNotEmpty()) return
        runCatching { load(context.assets.open("outfits.json").use { it.readBytes().toString(Charsets.UTF_8) }) }
            .onFailure { it.printStackTrace() }
    }

    internal fun load(text: String) {
        val f = json.decodeFromString<FileData>(text)
        colors = f.colors
        all = f.outfits
    }

    fun list(male: Boolean) = all.filter { it.male == male }

    fun groups(male: Boolean) = list(male).map { it.group }.distinct()

    internal fun rgb(name: String): Int? = colors[name]?.toIntOrNull(16)

    fun color(name: String): Color = rgb(name)?.let { Color(0xFF000000.toInt() or it) } ?: Color.Gray

    /** 除了衣服什么都不许动。 */
    const val CLEAN = "原来那身衣服要完全脱掉、一点都不留：领子、领口、脖子周围、肩膀、袖子、袖口、扣子、腰带、下摆全部换成新衣服的样子，" +
        "不能新旧衣服混在一起，不能把旧领子或里面的衣服留在脖子上。新衣服的领口、肩线、袖子要完整清楚；按新款式该露出的脖子、锁骨、肩膀和手臂露出自然的皮肤，肤色和脸、脖子连贯一致；" +
        "垂在胸前的头发仍然盖在新衣服上面。"

    const val KEEP = "只换衣服（包括和它配套的鞋子），其余全部和原照片逐像素一样：人物的脸、表情、妆、发型、头饰、肤色、身材、姿势、手的位置和手里的东西都不变，还是同一个人；" +
        "背景、天空、云、建筑、地面、光线、色调和构图完全不变，不要加光斑、光晕、云、花瓣或任何新东西，不要移动、裁剪、缩放画面。" +
        "衣服要像真的穿在身上：合身，布料的厚薄、垂坠、褶皱和姿势一致，受光方向、明暗、影子和现场一致，和地面、栏杆接触的地方有自然的遮挡和投影，手和头发挡在前面的地方仍然挡在前面。" +
        "布料要有真实的织纹和细节，像真实照片，不要绘画感、塑料感和发光感。"

    fun prompt(outfit: Outfit, color: String, skirt: OutfitSkirt): String =
        "把画面里主要人物的衣服换成：${outfit.prompt}。颜色是$color。${if (outfit.skirt) skirt.prompt else ""}" + CLEAN + KEEP

    /** 照着另一张图里的衣服换。 */
    const val REFERENCE_PROMPT = "第二张图是衣服的参考。把第一张图里主要人物的衣服换成第二张图里的那身衣服：款式、颜色、图案、面料和细节都照着它来，" +
        "但不要把第二张图里的人、脸、姿势或背景搬过来。" + CLEAN + KEEP

    /** 没换干净的地方：涂抹以后只补这一块。 */
    const val PATCH_PROMPT = "涂抹区域里还留着旧衣服。把涂抹区域换成和这个人身上现在这件衣服一致的样子：领口、肩线、布料、颜色和花纹都接得上；" +
        "按现在这件衣服的款式该露出皮肤的地方就露出自然的皮肤，肤色和脸、脖子连贯一致。旧衣服的领子、扣子和颜色一点都不留。垂下来的头发和首饰保留。"

    /** 自己写的指令里说没说裙摆要溢出画面。 */
    fun saysOverflow(prompt: String) = listOf("溢出", "铺满", "铺开", "拖尾", "大裙摆", "巨大").any { it in prompt }
}
