package com.taoo.xiutu.tools.filter

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.tools.color.ColorFx
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.ImageTile
import com.taoo.xiutu.ui.XSlider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.min
import kotlin.math.roundToInt

/** 滤镜：胶片风格、拍立得、大师 AI。 */
class FilterSession(model: EditorModel) : ToolSession(model, Tool.FILTER) {
    var lookID by mutableStateOf<String?>(null)
        private set
    var intensity by mutableFloatStateOf(1f)
        private set
    var category by mutableStateOf(LookCategory.CAMERA)

    var lookThumbs by mutableStateOf<Map<String, Bitmap>>(emptyMap())
        private set
    var lookThumbOriginal by mutableStateOf<Bitmap?>(null)
        private set
    var masterThumbs by mutableStateOf<Map<String, Bitmap>>(emptyMap())
        private set
    private var masterStarted = false

    // 拍立得
    var instant by mutableStateOf(InstantParams())
        private set
    var instantThumbs by mutableStateOf<Map<String, Bitmap>>(emptyMap())
        private set
    private var instantRequested = false
    var instantTab by mutableStateOf(InstantTab.STOCK)

    private val jobs = ArrayList<Job>()

    override fun start() {
        makeLookThumbs()
    }

    override fun close() {
        jobs.forEach { it.cancel() }
        jobs.clear()
    }

    /** 选了拍立得时普通滤镜不生效（lookID 是 null）。 */
    override fun commitOps(): List<EditOp> {
        val id = lookID
        if (id != null && intensity > 0f) return listOf(LookOp(id, intensity))
        if (!instant.isIdentity) return listOf(InstantOp(instant))
        return emptyList()
    }

    // MARK: 滤镜

    fun selectLook(id: String?) {
        // 选了普通滤镜（或"原图"）：拍立得要取消选中。
        if (!instant.isIdentity) instant = instant.copy(format = InstantFormat.NONE)
        lookID = id
        intensity = 1f
        renderLook()
    }

    fun changeIntensity(v: Float) {
        intensity = v
        renderLook()
    }

    private fun renderLook() {
        val look = lookID?.let { FilmLook.byID[it] }
        val k = intensity
        model.liveOnBase { base -> look?.apply(base, k) ?: base }
    }

    private fun background(block: suspend () -> Unit) {
        jobs += model.scope.launch { block() }
    }

    private fun makeLookThumbs() {
        val base = model.base ?: return
        background {
            val r = withContext(Dispatchers.Default) {
                runCatching {
                    val small = Img.downscale(base, 220)
                    small to ColorFx.thumbs(small, FilmLook.all.map { it.id to it.look })
                }.getOrNull()
            } ?: return@background
            lookThumbOriginal = r.first
            lookThumbs = r.second
        }
    }

    /** 大师风格缩略图：第一次翻到这一类时在后台算一遍。 */
    fun prepareMasterThumbs() {
        if (masterStarted) return
        val base = model.base ?: return
        masterStarted = true
        val titles = AIPresetGroup.MASTER.presets.map { it.title }
        background {
            val r = withContext(Dispatchers.Default) { runCatching { MasterPreview.thumbs(base, titles) }.getOrNull() } ?: return@background
            masterThumbs = r
        }
    }

    // MARK: 拍立得

    /** 选一种相纸；null = 不要拍立得。 */
    fun selectInstant(preset: InstantPreset?) {
        instant = if (preset != null) {
            // 换了相纸，裁掉的方向可能也变了，取景回到正中。
            val reset = instant.format != preset.format || instant.rotated != preset.rotated
            instant.copy(format = preset.format, rotated = preset.rotated, shift = if (reset) 0f else instant.shift)
        } else {
            instant.copy(format = InstantFormat.NONE)
        }
        renderInstant()
    }

    fun updateInstant(change: (InstantParams) -> InstantParams) {
        instant = change(instant)
        renderInstant()
    }

    private fun renderInstant() {
        val p = instant
        if (p.isIdentity) { renderLook(); return }
        // 拍立得和普通滤镜二选一。
        if (lookID != null) lookID = null
        model.liveOnBase { base -> InstantRender.apply(base, p) }
    }

    /** 相纸缩略图：用当前照片做，整张相纸放进按钮里，四周垫深色底。 */
    fun prepareInstantThumbs() {
        if (instantRequested) return
        val base = model.base ?: return
        instantRequested = true
        background {
            val r = withContext(Dispatchers.Default) {
                runCatching {
                    val small = Img.downscale(base, 240)
                    val tw = 204
                    val th = 252
                    InstantPreset.all.associate { preset ->
                        val made = InstantRender.apply(small, InstantParams(format = preset.format, rotated = preset.rotated))
                        val tile = Bitmap.createBitmap(tw, th, Bitmap.Config.ARGB_8888)
                        val c = Canvas(tile)
                        c.drawColor(0xFF242424.toInt())
                        val k = min((tw - 24f) / made.width, (th - 24f) / made.height)
                        val dw = made.width * k
                        val dh = made.height * k
                        val x = ((tw - dw) / 2).roundToInt().toFloat()
                        val y = ((th - dh) / 2).roundToInt().toFloat()
                        c.drawBitmap(made, null, RectF(x, y, x + dw, y + dh), Paint(Paint.FILTER_BITMAP_FLAG))
                        preset.id to tile
                    }
                }.getOrNull()
            } ?: return@background
            instantThumbs = r
        }
    }

    // MARK: 界面

    @Composable
    override fun Panel() {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 14.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            // 拍立得有自己的强度，不用上面这条。
            if (category != LookCategory.INSTANT) {
                val on = lookID != null
                Row(Modifier.alpha(if (on) 1f else 0.3f), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("${(intensity * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.width(44.dp))
                    XSlider(intensity, { changeIntensity(it) }, 0f..1f, Modifier.weight(1f), enabled = on)
                }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (c in LookCategory.entries) Chip(c.title, category == c) { category = c }
            }
            when (category) {
                LookCategory.MASTER -> {
                    LaunchedEffect(Unit) { prepareMasterThumbs() }
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top) {
                        for (preset in AIPresetGroup.MASTER.presets) {
                            ImageTile(preset.title, masterThumbs[preset.title], symbol = "camera.aperture", badge = "AI") {
                                model.startAIPreset(preset, AIPresetGroup.MASTER)
                            }
                        }
                    }
                }
                LookCategory.INSTANT -> InstantFilmRow(this@FilterSession)
                else -> {
                    val cat = category
                    androidx.compose.runtime.key(cat) {
                        Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            ImageTile("原图", lookThumbOriginal, selected = lookID == null) { selectLook(null) }
                            for (look in FilmLook.all) {
                                if (look.category != cat) continue
                                ImageTile(look.name, lookThumbs[look.id], selected = lookID == look.id) { selectLook(look.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}
