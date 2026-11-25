package com.taoo.xiutu.ai

import android.content.Context
import com.taoo.xiutu.tools.color.ColorParams
import com.taoo.xiutu.tools.color.V3
import com.taoo.xiutu.tools.filter.FilmLook
import com.taoo.xiutu.tools.filter.LookCategory
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/** 一位大师的资料（assets/masters.json，和 iOS 共用一份）。 */
@Serializable
data class MasterInfo(
    val group: String,
    val title: String,
    val note: String,
    /** 发给 AI 的影调要求（只描述手法，不写名字）。 */
    val tone: String,
    /** 界面上介绍风格的三句话。 */
    val color: String,
    val light: String,
    val compose: String,
    val frames: List<Frame>,
    val look: Look? = null,
) {
    /** 一种取景：有人和没人的照片各一套要求。 */
    @Serializable
    data class Frame(val title: String, val person: String, val scene: String)

    /** 小图的色调（没有的沿用 MasterPreview 里写好的）。 */
    @Serializable
    data class Look(
        val exposure: Float? = null, val contrast: Float? = null, val highlights: Float? = null, val shadows: Float? = null,
        val saturation: Float? = null, val vibrance: Float? = null, val temperature: Float? = null, val tint: Float? = null,
        val fade: Float? = null, val vignette: Float? = null, val bloom: Float? = null,
        val mono: Boolean? = null,
        val shadowTint: List<Float>? = null, val highlightTint: List<Float>? = null,
    )

    val prompt: String get() = "给这张照片做专业调色，风格是：$tone。${MasterCompose.KEEP_TAIL}"
}

object MasterCatalog {
    private val json = Json { ignoreUnknownKeys = true }

    var all: List<MasterInfo> = emptyList()
        private set
    var byTitle: Map<String, MasterInfo> = emptyMap()
        private set
    /** 按出现的先后排好的组名。 */
    var groups: List<String> = emptyList()
        private set
    var presets: List<AIPreset> = emptyList()
        private set

    /** App 启动时调用一次。 */
    fun init(context: Context) {
        if (all.isNotEmpty()) return
        runCatching { load(context.assets.open("masters.json").use { it.readBytes().toString(Charsets.UTF_8) }) }
            .onFailure { it.printStackTrace() }
    }

    internal fun load(text: String) {
        all = json.decodeFromString<List<MasterInfo>>(text)
        byTitle = all.associateBy { it.title }
        groups = all.map { it.group }.distinct()
        presets = all.map { AIPreset(title = it.title, prompt = it.prompt) }
    }

    /** 资料里带了色调的那几位的小图。 */
    val looks: List<Pair<String, FilmLook>>
        get() = all.mapNotNull { master ->
            val l = master.look ?: return@mapNotNull null
            fun v3(list: List<Float>?) = if (list != null && list.size == 3) V3(list[0], list[1], list[2]) else V3.ZERO
            val c = ColorParams(
                exposure = l.exposure ?: 0f, contrast = l.contrast ?: 0f, highlights = l.highlights ?: 0f, shadows = l.shadows ?: 0f,
                saturation = l.saturation ?: 0f, vibrance = l.vibrance ?: 0f, temperature = l.temperature ?: 0f, tint = l.tint ?: 0f,
                fade = l.fade ?: 0f, mono = l.mono ?: false, shadowTint = v3(l.shadowTint), highlightTint = v3(l.highlightTint),
            )
            master.title to FilmLook("master-${master.title}", master.title, LookCategory.MASTER, c, l.vignette ?: 0f, l.bloom ?: 0f)
        }
}
