package com.taoo.xiutu.ai

/**
 * "再生成一次"：图像接口大多没有随机种子，同一句指令出来的图几乎一样。
 * 所以重新生成时在指令后面随机加几条"这次换个方向"的要求，让每一版有明显区别。照搬 iOS AIVariation.swift。
 */
object AIVariation {
    /** 画风类（创意玩法）：可以大胆换。 */
    private val creative = listOf(
        "换一套完全不同的配色方案",
        "换一个时间段的光线（清晨、正午、黄昏或夜晚任选其一，和上一版不同）",
        "线条换一种粗细和质感",
        "上色方式换一种（平涂、渐变、厚涂、水彩感任选，和上一版不同）",
        "背景的细节重新设计，加入不一样的小元素",
        "整体氛围换一种情绪（更明快、更安静或更温暖）",
        "画风在同一大类里换一个流派",
        "光影对比更强烈一些",
        "颜色更柔和淡雅一些",
        "颜色更鲜艳饱和一些",
        "人物的表情和神态换一种细微变化",
    )

    /** 调色调光类（大师、相机、光线）：换一种诠释，构图和人不动。 */
    private val tone = listOf(
        "换一种色彩诠释，冷暖倾向和上一版不同",
        "反差换一种处理（更柔或更硬，和上一版不同）",
        "光线的方向和软硬换一种",
        "暗部和高光的色彩倾向换一种",
        "饱和度换一个取向",
        "整体明暗基调换一种（更亮或更暗，和上一版不同）",
    )

    /** 其余：在保持原意的前提下换个处理思路。 */
    private val general = listOf(
        "换一种处理思路，结果和上一版要有区别",
        "细节的处理换一种方式",
        "颜色和光影的处理换一种方式",
        "处理的力度和上一版不同",
    )

    /** 第几次重新生成（从 1 开始）对应的附加要求。 */
    fun clause(group: AIPresetGroup, round: Int, recompose: Boolean = false, hasPerson: Boolean = true): String {
        val pool = when (group) {
            AIPresetGroup.CREATIVE -> creative
            AIPresetGroup.MASTER, AIPresetGroup.CAMERA, AIPresetGroup.LIGHT -> tone
            else -> general
        }
        val picks = pool.shuffled().take(if (group == AIPresetGroup.CREATIVE) 3 else 2).toMutableList()
        if (recompose) {
            picks += if (hasPerson) "取景换一种：景别、机位或人物在画面里的位置和上一版不同" else "取景换一种：景别、机位或画面重心和上一版不同"
        }
        val keep = when {
            group == AIPresetGroup.CREATIVE -> "人物要认得出是同一个人，画面比例不变。"
            group == AIPresetGroup.MASTER && recompose && !hasPerson -> "还是同一个地方，画面里不要出现任何人。"
            group == AIPresetGroup.MASTER && recompose -> "人物长相不变，还是同一个地方。"
            group in listOf(
                AIPresetGroup.FIX, AIPresetGroup.REMOVE, AIPresetGroup.OUTFIT, AIPresetGroup.COMPOSE, AIPresetGroup.BODY,
                AIPresetGroup.HAIR_STYLE, AIPresetGroup.HAIR_COLOR, AIPresetGroup.HAIR_CARE,
            ) -> "原来的要求全部照旧，人物长相不变。"
            else -> "人物长相和构图不变。"
        }
        return "\n\n这是第 ${round + 1} 次生成，上一版不满意。这次要和上一版有明显区别：" + picks.joinToString("；") + "。" + keep
    }
}
