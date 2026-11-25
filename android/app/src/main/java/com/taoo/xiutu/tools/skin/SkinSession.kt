package com.taoo.xiutu.tools.skin

import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Fill
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.onPlaced
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.FaceRescue
import com.taoo.xiutu.editor.FaceSeeker
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin

/** 皮肤面板里当前选中的那一项。 */
sealed interface SkinItem {
    /** 带滑块的项目。 */
    data class Key(val key: SkinKey) : SkinItem
    /** 肤色统一（作用在全身，不属于某一张脸）。 */
    object Unify : SkinItem
    /** 点痘：点哪里修哪里。 */
    object Heal : SkinItem
    /** 遮瑕笔。 */
    object Conceal : SkinItem
    /** 修容笔的高光、阴影、橡皮。 */
    object Highlight : SkinItem
    object Shadow : SkinItem
    object Erase : SkinItem

    val isBrush: Boolean get() = this === Conceal || this === Highlight || this === Shadow || this === Erase
}

/** 皮肤：磨皮、肤色、祛皱祛痘、丰盈、提拉、眼部牙齿、修容笔。 */
class SkinSession(model: EditorModel) : ToolSession(model, Tool.SKIN), FaceSeeker {
    var tab by mutableStateOf(SkinTab.SKIN)
        private set
    var item by mutableStateOf<SkinItem>(SkinItem.Key(SkinKey.SMOOTH))
    var params by mutableStateOf(SkinParams())
        private set
    /** 正在调哪张脸。 */
    var faceIndex by mutableIntStateOf(0)
        private set
    var detecting by mutableStateOf(false)
        private set
    /** 画笔在屏幕上的粗细（dp）和力度。 */
    var brush by mutableFloatStateOf(34f)
    var strength by mutableFloatStateOf(0.6f)
    /** 点痘的大小，相对脸宽。 */
    var healSize by mutableFloatStateOf(0.07f)
    /** 正在识别人像（肤色统一第一次用时要等一下）。 */
    var unifyBusy by mutableStateOf(false)
        private set

    private var focus by mutableStateOf<RectF?>(null)
    /** 这次进工具有没有找过人像蒙版。 */
    private var askedBody = false
    private var closed = false
    /** 最近一笔的粗细（以图片长边为 1）。 */
    private var lastWidth = 0.02f
    private val density = model.context.resources.displayMetrics.density

    private val face: SkinFace? get() = params.faces.getOrNull(faceIndex)
    /** 当前这张脸的五官关键点可不可信。不可信时只有磨皮、肤色这几项能用。 */
    private val reliable: Boolean get() = face?.face?.hasReliableLandmarks ?: false
    private fun value(key: SkinKey): Float = face?.get(key) ?: 0f
    private fun isOn(preset: SkinPreset): Boolean = face?.matches(preset) ?: false
    private fun usable(key: SkinKey): Boolean = face != null && (reliable || !key.needsLandmarks)
    private val hasStrokes: Boolean get() = params.strokes.isNotEmpty()

    override val drawing: Boolean get() = item.isBrush
    override val wantsTap: Boolean get() = true
    override val focusRect: RectF? get() = focus

    override fun start() {
        val b = model.base ?: return
        detecting = true
        model.scope.launch {
            val list = model.faceSearch.find()
            val found = withContext(Dispatchers.Default) {
                runCatching {
                    list.map { f ->
                        // 量不出来（脸贴着画面边缘之类）就用一个常见的肤色顶上。
                        SkinFace(f, SkinEngine.measureTone(b, f) ?: SkinTone.DEFAULT)
                    }
                }.onFailure { it.printStackTrace() }.getOrElse { emptyList() }
            }
            if (closed) return@launch
            params = params.copy(faces = found)
            faceIndex = 0
            detecting = false
            updateFocus()
        }
    }

    override fun close() {
        closed = true
    }

    override fun commitOps(): List<EditOp> = if (params.isIdentity) emptyList() else listOf(SkinOp(params))

    // MARK: 画面上的操作

    /** 涂抹和点痘不用脸，照常能点。 */
    override val lacksFace: Boolean get() = !detecting && params.faces.isEmpty() && !item.isBrush && item != SkinItem.Heal

    override fun redetectFaces() = start()

    override fun onTap(p: PointF) {
        if (model.faceSearch.tap(p)) return
        if (detecting) return
        when (item) {
            SkinItem.Heal -> {
                params = params.copy(strokes = params.strokes + SkinStroke(SkinStroke.Kind.CONCEAL, listOf(p), healWidth(p), 1f))
                render()
            }
            SkinItem.Conceal, SkinItem.Highlight, SkinItem.Shadow, SkinItem.Erase -> {
                // 画笔模式下轻点一下 = 点一笔（刚才那一点已经留在画面上了就不重复点）。
                val last = params.strokes.lastOrNull()
                val q = last?.points?.firstOrNull()
                if (last != null && last.points.size == 1 && q != null && hypot(q.x - p.x, q.y - p.y) < 0.01f) return
                params = params.copy(strokes = params.strokes + SkinStroke(strokeKind(), listOf(p), lastWidth, strokeStrength()))
                render()
            }
            else -> selectFace(p)
        }
    }

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (!item.isBrush || displayScale <= 0f) return
        val w = brush * density / displayScale
        lastWidth = w
        params = params.copy(strokes = params.strokes + SkinStroke(strokeKind(), listOf(p), w, strokeStrength()))
        render()
    }

    override fun strokeMoved(p: PointF) {
        if (!item.isBrush) return
        val last = params.strokes.lastOrNull() ?: return
        params = params.copy(strokes = params.strokes.dropLast(1) + last.copy(points = last.points + p))
        render()
    }

    /** 第二根手指落下、手势被取消：撤掉刚开始的这一笔。 */
    override fun strokeCancelled() = undoStroke()

    private fun strokeKind(): SkinStroke.Kind = when (item) {
        SkinItem.Highlight -> SkinStroke.Kind.HIGHLIGHT
        SkinItem.Shadow -> SkinStroke.Kind.SHADOW
        SkinItem.Erase -> SkinStroke.Kind.ERASE
        else -> SkinStroke.Kind.CONCEAL
    }

    private fun strokeStrength(): Float = if (item === SkinItem.Conceal) 1f else strength

    /** 点痘的笔触粗细（以图片长边为 1）：按离得最近的那张脸的宽度算。 */
    private fun healWidth(p: PointF): Float {
        val b = model.base ?: return 0.012f
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val nearest = params.faces.minByOrNull { hypot(it.face.box.centerX() - p.x, it.face.box.centerY() - p.y) } ?: return 0.012f
        return healSize * SkinFrame(nearest.face, w, h).fw / max(w, h)
    }

    // MARK: 面板用的操作

    private fun render() {
        val p = params
        model.liveOnBase { p.apply(it) }
    }

    fun selectTab(t: SkinTab) {
        if (t == tab) return
        tab = t
        item = if (t == SkinTab.BRUSH) SkinItem.Highlight else SkinItem.Key(SkinKey.keys(t).firstOrNull() ?: SkinKey.SMOOTH)
    }

    private fun updateFace(change: (SkinFace) -> SkinFace) {
        val i = faceIndex
        val f = params.faces.getOrNull(i) ?: return
        params = params.copy(faces = params.faces.toMutableList().also { it[i] = change(f) })
        render()
    }

    fun setSkin(key: SkinKey, v: Float) = updateFace { it.with(key, v) }

    fun togglePreset(preset: SkinPreset) = updateFace { it.set(preset, !it.matches(preset)) }

    fun applyTone(preset: SkinTonePreset) = updateFace {
        it.with(SkinKey.WHITE, preset.white).with(SkinKey.WARMTH, preset.warmth).with(SkinKey.ROSY, preset.rosy)
    }

    /** 肤色统一。第一次用时先在本机认一下人像，之后就只动人身上的皮肤。 */
    fun setUnify(v: Float) {
        params = params.copy(unify = if (v < 0.01f) 0f else min(v, 1f))
        render()
        val b = model.base
        if (v <= 0f || askedBody || b == null) return
        askedBody = true
        unifyBusy = true
        model.scope.launch {
            val mask = withContext(Dispatchers.Default) {
                runCatching { PersonSegmenter.mask(b)?.let { Img.downscale(it, 1024) } }.getOrNull()
            }
            if (closed) return@launch
            unifyBusy = false
            params = params.copy(bodyMask = mask)
            render()
        }
    }

    fun undoStroke() {
        if (params.strokes.isEmpty()) return
        params = params.copy(strokes = params.strokes.dropLast(1))
        render()
    }

    fun clearStrokes() {
        if (params.strokes.isEmpty()) return
        params = params.copy(strokes = emptyList())
        render()
    }

    fun selectFace(index: Int) {
        if (index !in params.faces.indices) return
        faceIndex = index
        updateFocus()
    }

    private fun selectFace(p: PointF) {
        if (params.faces.size <= 1) return
        var bestIndex = -1
        var bestDistance = Float.MAX_VALUE
        params.faces.forEachIndexed { i, f ->
            val box = f.face.box
            val grown = RectF(
                box.left - box.width() * 0.35f, box.top - box.height() * 0.45f,
                box.right + box.width() * 0.35f, box.bottom + box.height() * 0.45f,
            )
            if (!grown.contains(p.x, p.y)) return@forEachIndexed
            val d = hypot(p.x - box.centerX(), p.y - box.centerY())
            if (d < bestDistance) { bestDistance = d; bestIndex = i }
        }
        if (bestIndex >= 0) selectFace(bestIndex)
    }

    /** 把画面放大到当前这张脸（连额头和脖子）。 */
    private fun updateFocus() {
        val f = face?.face
        val b = model.base
        if (f == null || b == null) { focus = null; return }
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val side = max(f.box.width() * w, f.box.height() * h) * 2.1f
        val cx = f.box.centerX() * w
        val cy = f.box.centerY() * h
        val r = RectF(max(0f, cx - side / 2), max(0f, cy - side / 2), min(w, cx + side / 2), min(h, cy + side / 2))
        focus = if (r.width() > 0 && r.height() > 0) RectF(r.left / w, r.top / h, r.right / w, r.bottom / h) else null
    }

    // MARK: 面板

    /** 只在真的用不了的时候说明原因。 */
    private fun errorText(): String? = when (val it = item) {
        SkinItem.Unify -> if (params.faces.isEmpty()) "这张图里没有找到人脸，没法统一肤色。" else null
        is SkinItem.Key -> when {
            params.faces.isEmpty() -> "这张图里没有找到人脸，只有遮瑕笔、点痘和修容笔能用。"
            !usable(it.key) -> "这张脸的五官识别不清，这一项用不了。"
            else -> null
        }
        else -> null
    }

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            if (detecting) {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 26.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    Text("正在找人脸…", fontSize = 14.sp, color = Color.White)
                }
            } else {
                val message = errorText()
                if (message != null && params.faces.isEmpty()) {
                    FaceRescue(model, "这张图里没有找到人脸")
                } else message?.let {
                    Text(it, fontSize = 12.sp, color = WARNING, modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
                }
                if (params.faces.size > 1) FacePicker()
                Box(Modifier.padding(horizontal = 16.dp)) { Controls() }
                Tiles()
            }
        }
    }

    @Composable
    private fun FacePicker() {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            params.faces.forEachIndexed { i, f ->
                Chip(if (f.isIdentity) "第 ${i + 1} 张" else "第 ${i + 1} 张 ✓", selected = faceIndex == i) { selectFace(i) }
            }
            Chip("看全图", selected = false) { focus = null }
        }
    }

    // MARK: 滑块 / 画笔

    @Composable
    private fun Controls() {
        when (val it = item) {
            is SkinItem.Key -> {
                val key = it.key
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (key == SkinKey.WHITE || key == SkinKey.WARMTH || key == SkinKey.ROSY) {
                        val has = face != null
                        Row(
                            Modifier.fillMaxWidth().alpha(if (has) 1f else 0.35f).horizontalScroll(rememberScrollState()),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            for (preset in SkinTonePreset.all) {
                                Chip(preset.title, selected = matches(preset)) { if (has) applyTone(preset) }
                            }
                        }
                    }
                    ValueSlider(value(key), if (key.bipolar) -1f..1f else 0f..1f, usable(key)) { v -> setSkin(key, v) }
                }
            }
            SkinItem.Unify -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.weight(1f)) { ValueSlider(params.unify, 0f..1f, params.faces.isNotEmpty()) { v -> setUnify(v) } }
                if (unifyBusy) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            }
            SkinItem.Heal -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Label("大小")
                XSlider(healSize, { v -> healSize = v }, 0.03f..0.14f, Modifier.weight(1f))
                StrokeButtons()
            }
            SkinItem.Conceal, SkinItem.Erase -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Label("大小")
                XSlider(brush, { v -> brush = v }, 12f..100f, Modifier.weight(1f))
                StrokeButtons()
            }
            SkinItem.Highlight, SkinItem.Shadow -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Label("大小")
                XSlider(brush, { v -> brush = v }, 12f..100f, Modifier.weight(1f))
                Label("力度")
                XSlider(strength, { v -> strength = v }, 0.2f..1f, Modifier.weight(1f))
                StrokeButtons()
            }
        }
    }

    private fun matches(preset: SkinTonePreset): Boolean {
        if (face == null) return false
        return abs(value(SkinKey.WHITE) - preset.white) < 0.005f && abs(value(SkinKey.WARMTH) - preset.warmth) < 0.005f &&
            abs(value(SkinKey.ROSY) - preset.rosy) < 0.005f
    }

    @Composable
    private fun Label(text: String) {
        Text(text, fontSize = 13.sp, color = Theme.dim)
    }

    /** 数值 + 滑块 + 还原。 */
    @Composable
    private fun ValueSlider(value: Float, range: ClosedFloatingPointRange<Float>, enabled: Boolean, set: (Float) -> Unit) {
        Row(
            Modifier.alpha(if (enabled) 1f else 0.35f),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "${(value * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                modifier = Modifier.width(44.dp),
            )
            XSlider(value, set, range, Modifier.weight(1f), enabled = enabled)
            Box(Modifier.size(36.dp).tap(enabled) { set(0f) }, contentAlignment = Alignment.Center) {
                Icon(sym("arrow.counterclockwise"), null, tint = if (value == 0f) Theme.dim else Color.White, modifier = Modifier.size(16.dp))
            }
        }
    }

    @Composable
    private fun StrokeButtons() {
        val on = hasStrokes
        Row(Modifier.alpha(if (on) 1f else 0.35f), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            RoundButton("arrow.uturn.backward", on) { undoStroke() }
            RoundButton("trash", on) { clearStrokes() }
        }
    }

    @Composable
    private fun RoundButton(symbol: String, enabled: Boolean, action: () -> Unit) {
        Box(
            Modifier.size(36.dp).clip(CircleShape).background(Theme.chip).tap(enabled, action),
            contentAlignment = Alignment.Center,
        ) { Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(15.dp)) }
    }

    // MARK: 项目

    @Composable
    private fun Tiles() {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.Top,
        ) {
            when (tab) {
                SkinTab.SKIN -> {
                    PresetTile(SkinPreset.SKIN)
                    for (k in SkinKey.keys(SkinTab.SKIN)) KeyTile(k)
                    IconTile(
                        "bandage", "遮瑕笔", selected = item === SkinItem.Conceal,
                        modified = params.strokes.any { it.kind == SkinStroke.Kind.CONCEAL && it.points.size > 1 },
                    ) { item = SkinItem.Conceal }
                    IconTile("figure.stand", "肤色统一", selected = item === SkinItem.Unify, modified = params.unify > 0f) {
                        item = SkinItem.Unify
                    }
                }
                SkinTab.REPAIR -> {
                    for (k in SkinKey.keys(SkinTab.REPAIR)) KeyTile(k)
                    IconTile(
                        "hand.tap", "点痘", selected = item === SkinItem.Heal,
                        modified = params.strokes.any { it.kind == SkinStroke.Kind.CONCEAL && it.points.size == 1 },
                    ) { item = SkinItem.Heal }
                    IconTile(SkinAI.wrinkles.symbol, SkinAI.wrinkles.title, badge = "AI") {
                        model.startAIPreset(SkinAI.wrinkles, AIPresetGroup.FIX)
                    }
                    IconTile(SkinAI.acne.symbol, SkinAI.acne.title, badge = "AI") {
                        model.startAIPreset(SkinAI.acne, AIPresetGroup.FIX)
                    }
                }
                SkinTab.PLUMP -> {
                    PresetTile(SkinPreset.PLUMP)
                    for (k in SkinKey.keys(SkinTab.PLUMP)) RegionTile(k)
                }
                SkinTab.LIFT -> {
                    PresetTile(SkinPreset.LIFT)
                    for (k in SkinKey.keys(SkinTab.LIFT)) RegionTile(k)
                }
                SkinTab.EYES -> for (k in SkinKey.keys(SkinTab.EYES)) KeyTile(k)
                SkinTab.BRUSH -> {
                    IconTile(
                        "sun.max", "高光", selected = item === SkinItem.Highlight,
                        modified = params.strokes.any { it.kind == SkinStroke.Kind.HIGHLIGHT },
                    ) { item = SkinItem.Highlight }
                    IconTile(
                        "moon", "阴影", selected = item === SkinItem.Shadow,
                        modified = params.strokes.any { it.kind == SkinStroke.Kind.SHADOW },
                    ) { item = SkinItem.Shadow }
                    IconTile("eraser", "橡皮", selected = item === SkinItem.Erase) { item = SkinItem.Erase }
                }
            }
        }
    }

    @Composable
    private fun PresetTile(preset: SkinPreset) {
        val on = isOn(preset)
        IconTile(if (on) "checkmark.circle.fill" else preset.symbol, preset.title, selected = on, enabled = face != null) {
            togglePreset(preset)
        }
    }

    @Composable
    private fun KeyTile(key: SkinKey) {
        Box(Modifier.alpha(if (usable(key)) 1f else 0.35f)) {
            IconTile(key.symbol, key.title, selected = item == SkinItem.Key(key), modified = value(key) != 0f) {
                item = SkinItem.Key(key)
            }
        }
    }

    @Composable
    private fun RegionTile(key: SkinKey) {
        val selected = item == SkinItem.Key(key)
        val fg = if (selected) Theme.accent else Color.White
        Column(
            Modifier.widthIn(min = 58.dp).alpha(if (usable(key)) 1f else 0.35f).tap { item = SkinItem.Key(key) }.padding(vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(Modifier.size(width = 44.dp, height = 36.dp)) {
                SkinRegionIcon(key, fg, Modifier.size(width = 44.dp, height = 36.dp))
                if (value(key) != 0f) Box(Modifier.align(Alignment.TopEnd).size(6.dp).background(Theme.accent, CircleShape))
            }
            Text(key.title, fontSize = 12.sp, color = fg, maxLines = 1)
        }
    }

    /** 底部确认栏中间：一排分类标签，放不下可以左右滑，点了滚到中间。 */
    @Composable
    override fun Title() {
        val scroll = rememberScrollState()
        val scope = rememberCoroutineScope()
        val places = remember { HashMap<SkinTab, Pair<Float, Int>>() }
        val viewport = remember { intArrayOf(0) }
        val pad = with(LocalDensity.current) { 8.dp.toPx() }
        Row(
            Modifier.height(44.dp).onSizeChanged { viewport[0] = it.width }.horizontalScroll(scroll).padding(horizontal = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(20.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            for (t in SkinTab.entries) {
                val on = tab == t
                Column(
                    Modifier
                        .onPlaced { places[t] = it.positionInParent().x to it.size.width }
                        .tap {
                            selectTab(t)
                            val p = places[t]
                            if (p != null) {
                                val target = (pad + p.first + p.second / 2f - viewport[0] / 2f).roundToInt().coerceIn(0, scroll.maxValue)
                                scope.launch { scroll.animateScrollTo(target) }
                            }
                        },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(
                        t.title, fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                        color = if (on) Color.White else Theme.dim, maxLines = 1,
                    )
                    Box(Modifier.size(18.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
                }
            }
        }
    }

    companion object {
        private val WARNING = Color(1f, 0.45f, 0.4f)
    }
}

/** 每个区域：中心 (u, v) 和半径 (ru, rv)，以脸的半宽、半高为 1；mirrored = 左右各一个。 */
private class SkinRegion(val u: Float, val v: Float, val ru: Float, val rv: Float, val mirrored: Boolean)

private fun skinRegions(key: SkinKey): List<SkinRegion> = when (key) {
    SkinKey.PLUMP_FOREHEAD, SkinKey.LIFT_FOREHEAD -> listOf(SkinRegion(0f, -0.62f, 0.6f, 0.22f, false))
    SkinKey.PLUMP_TEAR -> listOf(SkinRegion(0.36f, 0.0f, 0.24f, 0.09f, true))
    SkinKey.PLUMP_APPLE -> listOf(SkinRegion(0.5f, 0.2f, 0.25f, 0.17f, true))
    SkinKey.PLUMP_CHEEK -> listOf(SkinRegion(0.56f, 0.5f, 0.2f, 0.22f, true))
    SkinKey.PLUMP_NOSE_BASE -> listOf(SkinRegion(0.25f, 0.3f, 0.13f, 0.1f, true))
    SkinKey.PLUMP_TEMPLE -> listOf(SkinRegion(0.78f, -0.3f, 0.13f, 0.2f, true))
    SkinKey.LIFT_EYE -> listOf(SkinRegion(0.42f, -0.12f, 0.32f, 0.19f, true))
    SkinKey.LIFT_MID -> listOf(SkinRegion(0.42f, 0.24f, 0.32f, 0.2f, true))
    SkinKey.LIFT_MOUTH -> listOf(SkinRegion(0f, 0.56f, 0.42f, 0.2f, false))
    else -> emptyList()
}

/** 丰盈 / 提拉各项的小图：一张简笔的脸，用虚线圈出这一项作用的位置。 */
@Composable
fun SkinRegionIcon(key: SkinKey, tint: Color, modifier: Modifier = Modifier) {
    val regions = skinRegions(key)
    Canvas(modifier) {
        val u1 = 1.dp.toPx()
        val cx = size.width / 2
        val cy = size.height / 2
        val hw = size.height * 0.38f
        val hh = size.height * 0.47f
        fun point(u: Float, v: Float) = Offset(cx + u * hw, cy + v * hh)
        // 脸
        drawOval(tint.copy(alpha = 0.85f), Offset(cx - hw, cy - hh), Size(hw * 2, hh * 2), style = Stroke(1.2f * u1))
        // 眼睛、鼻子、嘴
        val features = Path()
        for (s in listOf(-1f, 1f)) {
            val a = point(s * 0.26f, -0.12f)
            val c = point(s * 0.42f, -0.2f)
            val b = point(s * 0.58f, -0.12f)
            features.moveTo(a.x, a.y)
            features.quadraticTo(c.x, c.y, b.x, b.y)
        }
        point(0f, 0f).let { features.moveTo(it.x, it.y) }
        point(-0.06f, 0.26f).let { features.lineTo(it.x, it.y) }
        point(0.06f, 0.26f).let { features.lineTo(it.x, it.y) }
        point(-0.22f, 0.54f).let { features.moveTo(it.x, it.y) }
        val mc = point(0f, 0.64f)
        val me = point(0.22f, 0.54f)
        features.quadraticTo(mc.x, mc.y, me.x, me.y)
        drawPath(features, tint.copy(alpha = 0.55f), style = Stroke(u1, cap = StrokeCap.Round, join = StrokeJoin.Round))

        val dash = Stroke(1.2f * u1, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.4f * u1, 2f * u1)))
        if (key == SkinKey.LIFT_CONTOUR) {
            // 下颌线：沿着脸的下半圈。
            val jaw = Path()
            for (step in 0..14) {
                val a = (20 + step * 10) * Math.PI.toFloat() / 180
                val x = cx + cos(a) * hw * 1.14f
                val y = cy + sin(a) * hh * 1.12f
                if (step == 0) jaw.moveTo(x, y) else jaw.lineTo(x, y)
            }
            drawPath(
                jaw, Theme.accent,
                style = Stroke(1.6f * u1, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.6f * u1, 2.2f * u1))),
            )
        }
        for (r in regions) {
            for (s in if (r.mirrored) listOf(-1f, 1f) else listOf(1f)) {
                val c = point(r.u * s, r.v)
                val tl = Offset(c.x - r.ru * hw, c.y - r.rv * hh)
                val sz = Size(r.ru * hw * 2, r.rv * hh * 2)
                drawOval(Theme.accent.copy(alpha = 0.3f), tl, sz, style = Fill)
                drawOval(Theme.accent, tl, sz, style = dash)
            }
        }
    }
}
