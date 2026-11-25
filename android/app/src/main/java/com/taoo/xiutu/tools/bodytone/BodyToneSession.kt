package com.taoo.xiutu.tools.bodytone

import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.AIRegion
import com.taoo.xiutu.ai.bleed
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.tools.color.V3
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt

enum class BodyToneMode(val title: String, val symbol: String) {
    AUTO("自动", "wand.and.stars"),
    PICK("选色", "eyedropper"),
    PAINT("涂抹", "paintbrush"),
    ERASE("擦除", "eraser"),
}

/** 身体提亮：脸白身体暗的时候，把身体的皮肤调到和脸一致。 */
class BodyToneSession(model: EditorModel) : ToolSession(model, Tool.BODY_TONE) {
    private var params by mutableStateOf(BodyToneParams())
    private var key by mutableStateOf(BodyToneKey.BRIGHT)
    private var mode by mutableStateOf(BodyToneMode.AUTO)
    private var brush by mutableFloatStateOf(40f)
    /** 正在识别。 */
    private var detecting by mutableStateOf(false)
    /** 一直显示选中的范围（红色）。 */
    private var showMask by mutableStateOf(false)
    /** 刚涂完、刚改完范围：先把范围亮出来一下。 */
    private var flash = false
    private var error by mutableStateOf<String?>(null)
    private var autoTone: V3? = null
    private var measureJob: Job? = null
    private var flashJob: Job? = null
    private var closed = false
    private val density = model.context.resources.displayMetrics.density

    private val wantsStrokes get() = mode == BodyToneMode.PAINT || mode == BodyToneMode.ERASE
    override val drawing: Boolean get() = wantsStrokes
    override val wantsTap: Boolean get() = mode == BodyToneMode.PICK

    override fun start() {
        val b = model.base ?: return
        detecting = true
        model.scope.launch {
            val found = withContext(Dispatchers.Default) { BodyToneDetector.detect(b) }
            if (closed) return@launch
            detecting = false
            params = params.copy(person = found.person, face = found.face, faceMean = found.faceMean)
            val tone = found.faceMean
            if (tone != null) {
                params = params.copy(tone = tone)
                autoTone = tone
            } else {
                params = params.copy(useColor = false)
                mode = BodyToneMode.PICK
            }
            measure()
            render()
        }
    }

    override fun close() {
        closed = true
        measureJob?.cancel()
        flashJob?.cancel()
    }

    override fun commitOps(): List<EditOp> = if (params.isIdentity) emptyList() else listOf(BodyToneOp(params))

    private fun render() {
        val p = params.frozen()
        val red = showMask || flash
        model.liveOnBase { p.apply(it, red) }
    }

    /** 范围变了，重新算身体的平均颜色。 */
    private fun measure() {
        val b = model.base ?: return
        val p = params.frozen()
        measureJob?.cancel()
        measureJob = model.scope.launch {
            val mean = withContext(Dispatchers.Default) { runCatching { BodyToneDetector.mean(b, p) }.getOrNull() } ?: return@launch
            if (closed) return@launch
            params = params.copy(bodyMean = mean)
            render()
        }
    }

    private fun setValue(value: Float) {
        var v = value.coerceIn(if (key.signed) -1f else 0f, 1f)
        if (abs(v) < 0.02f) v = 0f
        params = params.copy(values = if (v == 0f) params.values - key else params.values + (key to v))
        flash = false
        render()
    }

    private fun setRange(value: Float, editing: Boolean) {
        params = params.copy(range = value)
        flash = editing
        if (!editing) measure()
        render()
    }

    private fun changeMode(m: BodyToneMode) {
        mode = m
        error = null
        if (m == BodyToneMode.AUTO) {
            val tone = autoTone
            if (tone != null) params = params.copy(tone = tone, useColor = true)
            else error = "没有认出人脸，用选色或涂抹指定要提亮的地方。"
            measure()
        }
        render()
    }

    /** 选色：点一下身体上的皮肤。 */
    override fun onTap(p: PointF) {
        val b = model.base ?: return
        if (mode != BodyToneMode.PICK) return
        val r = 0.006f
        val tone = BodyToneDetector.mean(b, RectF(p.x - r, p.y - r, p.x + r, p.y + r)) ?: return
        params = params.copy(tone = tone, useColor = true)
        error = null
        measure()
        flashOnce()
    }

    /** 把范围亮一下再收回去。 */
    private fun flashOnce() {
        flash = true
        render()
        flashJob?.cancel()
        flashJob = model.scope.launch {
            delay(900)
            if (closed || !flash) return@launch
            flash = false
            render()
        }
    }

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (!wantsStrokes || displayScale <= 0) return
        flashJob?.cancel()
        params = params.copy(
            strokes = params.strokes + AIRegion.stroke(listOf(p), brush * density / displayScale, mode == BodyToneMode.ERASE),
        )
        flash = true
        render()
    }

    override fun strokeMoved(p: PointF) {
        val s = params.strokes.lastOrNull() ?: return
        s.points += p
        render()
    }

    override fun strokeEnded() {
        measure()
        flashOnce()
    }

    override fun strokeCancelled() {
        if (params.strokes.isEmpty()) return
        params = params.copy(strokes = params.strokes.dropLast(1))
        flash = false
        render()
    }

    private fun undoStroke() {
        if (params.strokes.isEmpty()) return
        params = params.copy(strokes = params.strokes.dropLast(1))
        measure()
        render()
    }

    private fun reset() {
        params = params.copy(values = emptyMap(), strokes = emptyList(), range = 0.45f)
        changeMode(BodyToneMode.AUTO)
    }

    // MARK: 界面

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (m in BodyToneMode.entries) Chip(m.title, selected = mode == m, symbol = m.symbol) { changeMode(m) }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("看范围", selected = showMask, symbol = "eye") { showMask = !showMask; render() }
                if (params.useColor) {
                    val t = params.tone
                    Box(
                        Modifier.size(24.dp).clip(CircleShape).background(Color(t.x.coerceIn(0f, 1f), t.y.coerceIn(0f, 1f), t.z.coerceIn(0f, 1f)))
                            .border(1.5.dp, Color.White.copy(alpha = 0.6f), CircleShape),
                    )
                }
                if (detecting) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Spacer(Modifier.weight(1f))
                RoundButton("arrow.uturn.backward", Modifier.alpha(if (params.strokes.isEmpty()) 0.35f else 1f)) { undoStroke() }
                RoundButton("arrow.counterclockwise") { reset() }
            }
            if (wantsStrokes) {
                Line("笔刷", null) { XSlider(brush, { brush = it }, 12f..120f, it) }
            } else if (params.useColor) {
                Line("范围", "${(params.range * 100).roundToInt()}") {
                    XSlider(params.range, { v -> setRange(v, true) }, 0f..1f, it, onFinished = { setRange(params.range, false) })
                }
            }
            val value = params[key]
            Line(key.title, "${(value * 100).roundToInt()}") {
                XSlider(value, { v -> setValue(v) }, (if (key.signed) -1f else 0f)..1f, it, enabled = !(key == BodyToneKey.MATCH && params.faceMean == null))
            }
            Row(
                Modifier.bleed(16.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (k in BodyToneKey.entries) IconTile(k.symbol, k.title, selected = key == k, modified = params[k] != 0f) { key = k }
                IconTile("sparkles", "AI 提亮", badge = "AI") { model.startAIPreset(AI_PRESET, AIPresetGroup.BODY) }
            }
            error?.let { Text(it, fontSize = 12.sp, color = Color(1f, 0.45f, 0.4f), modifier = Modifier.fillMaxWidth()) }
        }
    }

    @Composable
    private fun Line(title: String, value: String?, slider: @Composable (Modifier) -> Unit) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, fontSize = 13.sp, color = Theme.dim, modifier = Modifier.width(56.dp))
            slider(Modifier.weight(1f))
            if (value != null) {
                Text(
                    value, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    textAlign = TextAlign.End, modifier = Modifier.width(40.dp),
                )
            }
        }
    }

    @Composable
    private fun RoundButton(symbol: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
        Box(modifier.size(34.dp).clip(CircleShape).background(Theme.chip).tap(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(16.dp))
        }
    }

    companion object {
        val AI_PRESET = AIPreset(
            title = "身体提亮", symbol = "sun.max",
            prompt = "这张照片里脸比身体白很多。把露出来的身体皮肤（脖子、肩膀、胸口、手臂、手、腰腹、腿）提亮，让它的明暗和颜色与脸自然一致、过渡均匀；" +
                "脸、头发、衣服和背景的明暗颜色都不变。只改光线、明暗和颜色；不要移动、裁剪、旋转或改变画面里任何东西的形状和位置，结果要和原图逐像素对齐，仍然是一张真实的照片。",
            toneOnly = true,
        )
    }
}
