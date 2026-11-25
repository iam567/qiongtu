package com.taoo.xiutu.tools.retouch

import android.graphics.Bitmap
import android.graphics.PointF
import androidx.compose.foundation.background
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
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.AIRegion
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.tools.mosaic.MosaicStroke
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class RetouchMode(val title: String, val symbol: String) {
    SMART("智能消除", "wand.and.stars"),
    CLONE("仿制", "doc.on.doc"),
    RESTORE("还原", "clock.arrow.circlepath"),
}

/** 手动消除：涂一笔补一块，全部在本机完成。 */
class RetouchSession(model: EditorModel) : ToolSession(model, Tool.RETOUCH) {
    private var mode by mutableStateOf(RetouchMode.SMART)
    private var brush by mutableFloatStateOf(46f)
    private var patches by mutableStateOf<List<RetouchPatch>>(emptyList())
    /** 正在涂的这一笔。 */
    private var stroke: MosaicStroke? = null
    /** 仿制：取样的地方；取样和涂抹起点的偏移（定下来以后接着涂不变）。 */
    private var source: PointF? = null
    private var offset: PointF? = null
    private var sampling by mutableStateOf(false)
    private var working by mutableStateOf(false)
    private var error by mutableStateOf<String?>(null)
    /** 进工具时整张大图算一次，之后每一笔都在它上面裁。 */
    private var full: Bitmap? = null
    private var originalImage: Bitmap? = null
    private var closed = false
    private val density = model.context.resources.displayMetrics.density

    override val drawing: Boolean get() = !sampling && !working
    override val wantsTap: Boolean get() = sampling
    /** 这一笔还没补完：先别确认。 */
    override val busy: Boolean get() = working

    override fun close() {
        closed = true
    }

    override fun commitOps(): List<EditOp> = if (patches.isEmpty()) emptyList() else listOf(RetouchOp(patches))

    /** 还原用的"原照片"：打开时的样子；中间裁过、重画过构图的，用那一步之后的样子。没有可还原的返回 null。 */
    private val originalOps: List<EditOp>?
        get() {
            val ops = model.ops
            if (ops.isEmpty()) return null
            val last = ops.indexOfLast { it.changesCanvas }
            if (last < 0) return emptyList()
            return if (last == ops.size - 1) null else ops.subList(0, last + 1).toList()
        }

    private fun render() {
        val list = patches
        val s = stroke?.copy()
        model.liveOnBase { b ->
            val out = RetouchOp(list).apply(b)
            if (s == null) out else AIRegion.overlay(out, RetouchEngine.previewMask(s, b.width, b.height))
        }
    }

    private fun changeMode(m: RetouchMode) {
        mode = m
        error = null
        sampling = m == RetouchMode.CLONE && source == null
        if (m == RetouchMode.RESTORE && originalOps == null) {
            error = if (model.ops.isEmpty()) "还没有改过，没有可还原的。" else "最后一步换过构图，没法从原照片还原。"
        }
    }

    override fun onTap(p: PointF) {
        if (!sampling) return
        source = p
        offset = null
        sampling = false
        error = null
    }

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (!drawing || displayScale <= 0) return
        if (mode == RetouchMode.RESTORE && originalOps == null) return
        if (mode == RetouchMode.CLONE && offset == null) {
            val s = source
            if (s == null) {
                sampling = true
                return
            }
            offset = PointF(s.x - p.x, s.y - p.y)
        }
        error = null
        stroke = AIRegion.stroke(listOf(p), brush * density / displayScale, erase = false)
        render()
    }

    override fun strokeMoved(p: PointF) {
        val s = stroke ?: return
        s.points += p
        render()
    }

    override fun strokeCancelled() {
        stroke = null
        render()
    }

    override fun strokeEnded() {
        val s = stroke?.copy() ?: return
        val photo = model.source ?: return
        val m = mode
        val o = offset ?: PointF(0f, 0f)
        val ops = model.ops
        val before = patches
        val original = if (m == RetouchMode.RESTORE) originalOps else null
        working = true
        model.scope.launch {
            val patch = withContext(Dispatchers.Default) {
                runCatching {
                    // 按原图分辨率算，放大看也清楚。
                    val image = full ?: EditOp.applyAll(ops, photo).also { full = it }
                    when (m) {
                        RetouchMode.SMART -> RetouchEngine.smart(image, before, s)
                        RetouchMode.CLONE -> RetouchEngine.clone(image, before, s, o.x, o.y)
                        RetouchMode.RESTORE -> original?.let { list ->
                            val from = originalImage ?: EditOp.applyAll(list, photo).also { originalImage = it }
                            RetouchEngine.restore(image, from, s)
                        }
                    }
                }.onFailure { it.printStackTrace() }.getOrNull()
            }
            if (closed) return@launch
            working = false
            stroke = null
            if (patch != null) patches = patches + patch else error = "这一笔补不了，涂小一点再试。"
            render()
        }
    }

    private fun undo() {
        if (working || patches.isEmpty()) return
        patches = patches.dropLast(1)
        render()
    }

    private fun reset() {
        if (working) return
        patches = emptyList()
        render()
    }

    /** AI 修手：先把手动消除做的保留成一步，再去涂手。 */
    private fun startAIHand() {
        if (working || model.isBusy) return
        val m = model
        m.commitTool { m.beginAI(AIPresetGroup.FIX) { it.startHand() } }
    }

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            error?.let { Text(it, fontSize = 12.sp, color = Color(1f, 0.45f, 0.4f), modifier = Modifier.fillMaxWidth()) }
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (m in RetouchMode.entries) Chip(m.title, selected = mode == m, symbol = m.symbol) { changeMode(m) }
                Chip("修手", selected = false, symbol = "hand.raised", badge = "AI") { startAIHand() }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("笔刷", fontSize = 13.sp, color = Theme.dim)
                XSlider(brush, { brush = it }, 10f..140f, Modifier.weight(1f))
                if (working) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                RoundButton("arrow.uturn.backward") { undo() }
                RoundButton("arrow.counterclockwise") { reset() }
            }
            if (mode == RetouchMode.CLONE) {
                Chip(if (sampling) "点画面取样" else "重新取样", selected = sampling, symbol = "scope") { sampling = true }
            }
        }
    }

    @Composable
    private fun RoundButton(symbol: String, onClick: () -> Unit) {
        Box(
            Modifier.alpha(if (patches.isEmpty()) 0.35f else 1f).size(34.dp).clip(CircleShape).background(Theme.chip).tap(onClick = onClick),
            contentAlignment = Alignment.Center,
        ) { Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(16.dp)) }
    }
}
