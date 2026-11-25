package com.taoo.xiutu.tools.shape

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.AIRunner
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.MalePresets
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.ModeSelectable
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.FeatureTile
import com.taoo.xiutu.ui.GenderSetting
import com.taoo.xiutu.ui.GenderToggle
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.LabeledSlider
import com.taoo.xiutu.ui.SegmentBar
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 美体塑形（一键美体、各部位塑形、增高 / 瘦身 / 缩放），iOS EditorModel+Shape + ShapePanel。
 * 菜单入口用 selectMode 指定做法："preset" "shape" "tall" "slim" "zoom"。
 */
class ShapeSession(model: EditorModel) : ToolSession(model, Tool.SHAPE), ModeSelectable {
    var mode by mutableStateOf(ShapeMode.PRESET)
        private set

    // 人体识别
    var body by mutableStateOf<ShapeBody?>(null)
        private set
    var detecting by mutableStateOf(false)
        private set
    private var detected = false

    // 塑形
    var values by mutableStateOf<Map<ShapeItem, ShapeAmount>>(emptyMap())
        private set
    var group by mutableStateOf(ShapeGroup.SLIM)
    var item by mutableStateOf(ShapeItem.WAIST)
        private set
    var side by mutableStateOf(ShapeSide.BOTH)
    // 一键美体
    var preset by mutableStateOf<String?>(null)
        private set
    var presetStrength by mutableFloatStateOf(0.7f)
        private set

    // 增高：一条一条做，最后一条是正在调的。
    var talls by mutableStateOf<List<ShapeTall>>(emptyList())
        private set
    var headProtect by mutableStateOf(false)
        private set
    var headBusy by mutableStateOf(false)
        private set
    private var headSearched = false
    /** 头的位置（原图上的单位坐标）。 */
    private var headBox by mutableStateOf<URect?>(null)
    // 瘦身 / 缩放：最后一个是正在调的。
    var boxes by mutableStateOf<List<ShapeBox>>(emptyList())
        private set
    var spots by mutableStateOf<List<ShapeSpot>>(emptyList())
        private set
    /** 正在拖辅助线（增高时把拉伸区域以外的地方压暗）。 */
    var guideDragging by mutableStateOf(false)
        private set

    // 背景保护
    var protect by mutableStateOf(false)
        private set
    var protectBusy by mutableStateOf(false)
        private set
    private var lockMask: Bitmap? = null
    private var plate: Warp.Plate? = null
    /** AI 补背景：开关、正在生成、补好的背景（留着，再打开不用重新花钱）。 */
    var aiFill by mutableStateOf(false)
        private set
    var aiFillBusy by mutableStateOf(false)
        private set
    private var aiPlate: Bitmap? = null
    // 变形还原
    var restoring by mutableStateOf(false)
        private set
    var restoreBrush by mutableFloatStateOf(0.06f)
    var restore by mutableStateOf<List<ShapeRestoreStroke>>(emptyList())
        private set

    var error by mutableStateOf<String?>(null)
        private set

    private val alive get() = model.session === this

    override fun start() {
        prepareMode()
    }

    /** 从主菜单进来时指定做法（紧跟在 start 之后调用）。 */
    override fun selectMode(mode: String) {
        ShapeMode.entries.firstOrNull { it.key == mode }?.let { changeMode(it) }
    }

    fun changeMode(m: ShapeMode) {
        mode = m
        restoring = false
        error = null
        prepareMode()
        render()
    }

    /** 面板里换一种做法：这边已经做出来的修改先保留成一步，再换过去。 */
    fun switchMode(m: ShapeMode) {
        if (m == mode || model.isBusy) return
        if (params().isIdentity) {
            changeMode(m)
        } else {
            model.commitTool { (model.begin(Tool.SHAPE) as? ShapeSession)?.changeMode(m) }
        }
    }

    override fun commitOps(): List<EditOp> {
        val p = params()
        return if (p.isIdentity) emptyList() else listOf(ShapeOp(p))
    }

    @Composable
    override fun Title() {
        Text(mode.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }

    override val customCanvas: Boolean get() = true

    @Composable
    override fun Canvas(modifier: Modifier) {
        ShapeCanvas(this, modifier)
    }

    // MARK: 画面尺寸

    /** 当前这张图的大小（单位坐标：长边为 1）。 */
    val unitSize: V2
        get() {
            val b = model.base ?: return V2(1f, 1f)
            val long = max(b.width, b.height).toFloat()
            if (long <= 0) return V2(1f, 1f)
            return V2(b.width / long, b.height / long)
        }

    /** 增高的各条带子（头部保护已经换算到各自的画面上），以及最后一条带子所在画面的大小。 */
    private fun resolvedTalls(): Pair<List<ShapeTall>, V2> {
        var size = unitSize
        val maps = ArrayList<ShapeTallMap>()
        val bands = ArrayList<ShapeTall>()
        var lastInput = size
        val head = headBox
        for (b in talls) {
            var band = b.copy(head = null)
            if (headProtect && head != null) {
                // 头的位置跟着前面几条带子的拉伸一起挪。
                var box: URect? = null
                for (corner in listOf(V2(head.minX, head.minY), V2(head.maxX, head.minY), V2(head.minX, head.maxY), V2(head.maxX, head.maxY))) {
                    var p = corner
                    for (map in maps) p = map.output(p)
                    val r = URect.point(p)
                    box = box?.union(r) ?: r
                }
                band = band.copy(head = box)
            }
            lastInput = size
            bands += band
            if (band.amount != 0f) {
                val map = ShapeTallMap(band, size)
                maps += map
                size = map.outSize
            }
        }
        return bands to lastInput
    }

    /** 变形之后画面的大小（单位坐标）。只有增高会改它。 */
    val outputSize: V2
        get() {
            if (mode != ShapeMode.TALL) return unitSize
            return ShapeEngine.tallMaps(resolvedTalls().first, unitSize).second
        }

    // MARK: 参数和预览

    fun params(): ShapeParams {
        var p = ShapeParams()
        when (mode) {
            ShapeMode.TALL -> return ShapeParams(talls = resolvedTalls().first)
            ShapeMode.SLIM -> p = p.copy(boxes = boxes)
            ShapeMode.ZOOM -> p = p.copy(spots = spots)
            ShapeMode.SHAPE -> p = p.copy(body = body, values = values)
            ShapeMode.PRESET -> {
                val v = HashMap<ShapeItem, ShapeAmount>()
                ShapePreset.all.firstOrNull { it.id == preset }?.let { pr ->
                    for ((k, value) in pr.values) v[k] = ShapeAmount(both = value * presetStrength)
                }
                p = p.copy(body = body, values = v)
            }
        }
        p = p.copy(restore = restore)
        if (protect) p = p.copy(lockMask = lockMask, aiPlate = if (aiFill) aiPlate else null)
        return p
    }

    fun render() {
        if (!alive) return
        val p = params()
        val pl = plate
        model.liveOnBase { b -> if (p.isIdentity) b else p.apply(b, pl) }
    }

    /** 进到某一种做法时的准备：需要识别人体的先识别，需要辅助线的先摆一个默认位置。 */
    private fun prepareMode() {
        val unit = unitSize
        when (mode) {
            ShapeMode.PRESET, ShapeMode.SHAPE -> detectBody()
            ShapeMode.TALL -> if (talls.isEmpty()) {
                talls = listOf(ShapeTall(center = V2(unit.x / 2, unit.y * 0.66f), halfGap = unit.y * 0.13f))
            }
            ShapeMode.SLIM -> if (boxes.isEmpty()) {
                val w = minOf(unit.x, unit.y) * 0.46f
                boxes = listOf(ShapeBox(center = V2(unit.x / 2, unit.y / 2), width = w, height = w * 1.15f))
            }
            ShapeMode.ZOOM -> if (spots.isEmpty()) {
                spots = listOf(ShapeSpot(center = V2(unit.x / 2, unit.y * 0.35f), radius = minOf(unit.x, unit.y) * 0.17f))
            }
        }
    }

    private fun detectBody() {
        if (detected || detecting) return
        val base = model.base ?: return
        detecting = true
        model.scope.launch {
            val found = withContext(Dispatchers.Default) { ShapeBodyDetector.detect(base) }
            if (!alive) return@launch
            detecting = false
            detected = true
            val b = found.firstOrNull()
            body = b
            if (b != null) {
                if (!item.available(b)) {
                    ShapeItem.entries.firstOrNull { !it.isAI && it.available(b) }?.let {
                        item = it
                        group = it.group
                    }
                }
            } else if (mode == ShapeMode.PRESET || mode == ShapeMode.SHAPE) {
                error = "没有识别到人体。可以用带 AI 的，或者改用增高、瘦身、缩放。"
            }
            render()
        }
    }

    // MARK: 滑块

    /** 当前滑块对应的数值。 */
    val amount: Float
        get() = when (mode) {
            ShapeMode.TALL -> talls.lastOrNull()?.amount ?: 0f
            ShapeMode.SLIM -> boxes.lastOrNull()?.amount ?: 0f
            ShapeMode.ZOOM -> spots.lastOrNull()?.amount ?: 0f
            ShapeMode.SHAPE -> values[item]?.get(side) ?: 0f
            ShapeMode.PRESET -> presetStrength
        }

    fun setAmount(raw: Float) {
        val value = if (abs(raw) < 0.02f) 0f else raw.coerceIn(-1f, 1f)
        when (mode) {
            ShapeMode.TALL -> if (talls.isNotEmpty()) talls = talls.dropLast(1) + talls.last().copy(amount = value)
            ShapeMode.SLIM -> if (boxes.isNotEmpty()) boxes = boxes.dropLast(1) + boxes.last().copy(amount = value)
            ShapeMode.ZOOM -> if (spots.isNotEmpty()) spots = spots.dropLast(1) + spots.last().copy(amount = value)
            ShapeMode.SHAPE -> {
                val a = (values[item] ?: ShapeAmount()).with(side, value)
                values = if (a.isZero) values - item else values + (item to a)
            }
            ShapeMode.PRESET -> presetStrength = max(value, 0f)
        }
        render()
    }

    fun selectItem(si: ShapeItem) {
        ShapeAI.preset(si)?.let { p ->
            model.startAIPreset(p, AIPresetGroup.BODY)
            return
        }
        item = si
        if (!si.hasSides) side = ShapeSide.BOTH
    }

    fun selectPreset(id: String?) {
        preset = id
        render()
    }

    /** 撤掉最近的一步：还原笔的一笔、最后摆的那条带子 / 框 / 圈，或者当前这一项的数值。 */
    fun undo() {
        if (restoring) {
            if (restore.isNotEmpty()) restore = restore.dropLast(1)
            render()
            return
        }
        when (mode) {
            ShapeMode.TALL -> if (talls.size > 1) talls = talls.dropLast(1) else if (talls.isNotEmpty()) talls = listOf(talls[0].copy(amount = 0f))
            ShapeMode.SLIM -> if (boxes.size > 1) boxes = boxes.dropLast(1) else if (boxes.isNotEmpty()) boxes = listOf(boxes[0].copy(amount = 0f))
            ShapeMode.ZOOM -> if (spots.size > 1) spots = spots.dropLast(1) else if (spots.isNotEmpty()) spots = listOf(spots[0].copy(amount = 0f))
            ShapeMode.SHAPE -> values = values - item
            ShapeMode.PRESET -> preset = null
        }
        render()
    }

    /** 这一种做法里的修改全部还原。 */
    fun reset() {
        restore = emptyList()
        when (mode) {
            ShapeMode.TALL -> talls = emptyList()
            ShapeMode.SLIM -> boxes = emptyList()
            ShapeMode.ZOOM -> spots = emptyList()
            ShapeMode.SHAPE -> values = emptyMap()
            ShapeMode.PRESET -> preset = null
        }
        prepareMode()
        render()
    }

    // MARK: 辅助线

    class TallGuide(val center: V2, val angle: Float, val halfGap: Float)

    /** 增高那两条线现在显示在哪里（变形之后的画面上的单位坐标）。 */
    val tallGuide: TallGuide?
        get() {
            val (bands, lastInput) = resolvedTalls()
            val band = bands.lastOrNull() ?: return null
            if (band.amount == 0f) return TallGuide(band.center, band.angle, band.halfGap)
            val map = ShapeTallMap(band, lastInput)
            val a = map.output(band.center - map.n * band.halfGap)
            val b = map.output(band.center + map.n * band.halfGap)
            return TallGuide((a + b) / 2f, band.angle, (b - a).length / 2)
        }

    /** 开始拖辅助线。上一处已经调过数值的话，先把它定下来，在现在的画面上另起一处。 */
    fun guideBegan() {
        guideDragging = true
        when (mode) {
            ShapeMode.TALL -> {
                val last = talls.lastOrNull()
                val g = tallGuide
                if (last != null && last.amount != 0f && g != null) {
                    talls = talls + ShapeTall(center = g.center, angle = g.angle, halfGap = g.halfGap)
                }
            }
            ShapeMode.SLIM -> boxes.lastOrNull()?.let { if (it.amount != 0f) boxes = boxes + it.copy(amount = 0f) }
            ShapeMode.ZOOM -> spots.lastOrNull()?.let { if (it.amount != 0f) spots = spots + it.copy(amount = 0f) }
            else -> {}
        }
    }

    fun guideEnded() {
        guideDragging = false
    }

    fun setTall(center: V2, angle: Float, halfGap: Float) {
        val last = talls.lastOrNull() ?: return
        val size = outputSize
        talls = talls.dropLast(1) + last.copy(
            center = V2(center.x.coerceIn(0f, size.x), center.y.coerceIn(0f, size.y)),
            angle = angle,
            halfGap = halfGap.coerceIn(0.02f, 1f),
        )
    }

    fun setBox(center: V2, width: Float, height: Float, angle: Float) {
        val last = boxes.lastOrNull() ?: return
        val size = unitSize
        boxes = boxes.dropLast(1) + last.copy(
            center = V2(center.x.coerceIn(0f, size.x), center.y.coerceIn(0f, size.y)),
            width = width.coerceIn(0.06f, 1.5f),
            height = height.coerceIn(0.06f, 1.5f),
            angle = angle,
        )
    }

    fun setSpot(center: V2, radius: Float) {
        val last = spots.lastOrNull() ?: return
        val size = unitSize
        spots = spots.dropLast(1) + last.copy(
            center = V2(center.x.coerceIn(0f, size.x), center.y.coerceIn(0f, size.y)),
            radius = radius.coerceIn(0.03f, 0.8f),
        )
    }

    // MARK: 背景保护 / 头部保护 / 变形还原

    /** 开关背景保护。第一次打开时在本机识别一次人像，并算好背景变形的权重。 */
    fun changeProtect(on: Boolean) {
        if (protectBusy) return
        error = null
        if (!on) {
            protect = false
            render()
            return
        }
        if (lockMask != null) {
            protect = true
            render()
            return
        }
        val base = model.base ?: return
        protectBusy = true
        model.scope.launch {
            val found = withContext(Dispatchers.Default) {
                runCatching {
                    val mask = PersonSegmenter.mask(base) ?: return@runCatching null
                    mask to Warp.plate(base, mask)
                }.getOrNull()
            }
            if (!alive) return@launch
            protectBusy = false
            lockMask = found?.first
            plate = found?.second
            protect = found != null
            if (found == null) error = "这张图里没有识别到人物，没法保护背景。"
            render()
        }
    }

    /**
     * AI 补背景：让 AI 把人从照片里去掉、补出后面的背景（计一次费），之后人让出来的地方都用它。
     * 关掉就回到本机的做法（拉旁边的背景）。
     */
    fun changeAIFill(on: Boolean) {
        if (aiFillBusy) return
        error = null
        if (!on) {
            aiFill = false
            render()
            return
        }
        // 先确保背景保护开着（要用到人像蒙版）。
        if (lockMask == null) {
            changeProtect(true)
            model.scope.launch {
                while (protectBusy) kotlinx.coroutines.delay(100)
                if (alive && lockMask != null) changeAIFill(true)
            }
            return
        }
        protect = true
        if (aiPlate != null) {
            aiFill = true
            render()
            return
        }
        val base = model.base ?: return
        val endpoint = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        aiFillBusy = true
        model.scope.launch {
            var made: Bitmap? = null
            var failure: String? = null
            try {
                AIClient.takeLastUsage()
                made = AIRunner.run(endpoint, FILL_PROMPT, base, emptyList(), emptyList(), null, appendGuidance = false)
                AIClient.takeLastUsage()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                failure = (e as? AIError)?.text ?: e.message ?: "请求失败。"
            }
            if (!alive) return@launch
            aiFillBusy = false
            if (made != null) {
                aiPlate = made
                aiFill = true
            } else {
                error = failure ?: "AI 没有补出背景，可以再试一次。"
            }
            render()
        }
    }

    /** 增高时的头部保护：拉伸区域盖到头的时候，头这一段不跟着拉长。 */
    fun changeHeadProtect(on: Boolean) {
        if (headBusy) return
        error = null
        if (!on) {
            headProtect = false
            render()
            return
        }
        if (headSearched) {
            headProtect = headBox != null
            if (headBox == null) error = "没有识别到头部。"
            render()
            return
        }
        val base = model.base ?: return
        val unit = unitSize
        headBusy = true
        model.scope.launch {
            val box = withContext(Dispatchers.Default) {
                runCatching {
                    val face = FaceDetector.detect(base).firstOrNull()
                    if (face != null) {
                        // 人脸框只到眉毛上面一点，往上、往两边放大到包住整个头和头发。
                        val b = face.box
                        val x = b.left - b.width() * 0.35f
                        val y = b.top - b.height() * 0.65f
                        URect.of(x * unit.x, y * unit.y, b.width() * 1.7f * unit.x, b.height() * 1.85f * unit.y)
                    } else {
                        val found = ShapeBodyDetector.detect(base).firstOrNull()
                        val head = found?.head
                        if (found != null && head != null) {
                            val r = found.headRadius * 1.3f
                            URect.of(head.x - r, head.y - r, r * 2, r * 2)
                        } else null
                    }
                }.getOrNull()
            }
            if (!alive) return@launch
            headBusy = false
            headSearched = true
            headBox = box
            headProtect = box != null
            if (box == null) error = "没有识别到头部。"
            render()
        }
    }

    fun changeRestoring(on: Boolean) {
        restoring = on && mode != ShapeMode.TALL
    }

    /** 变形还原：手指落下。point 是画面上的单位坐标。 */
    fun restoreBegan(p: V2) {
        if (!restoring) return
        restore = restore + ShapeRestoreStroke(listOf(p), restoreBrush)
        render()
    }

    fun restoreMoved(p: V2) {
        if (!restoring) return
        val s = restore.lastOrNull() ?: return
        val last = s.points.lastOrNull() ?: return
        // 挪得太近的点不记，免得一笔里攒下几千个点。
        if (hypot(p.x - last.x, p.y - last.y) <= restoreBrush * 0.15f) return
        restore = restore.dropLast(1) + s.copy(points = s.points + p)
        render()
    }

    // MARK: 面板

    /** 塑形和一键美体要先认出人来。 */
    private val needsBody: Boolean get() = (mode == ShapeMode.PRESET || mode == ShapeMode.SHAPE) && body == null

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SegmentBar(ShapeMode.entries, mode, { it.short }) { switchMode(it) }
            Options()
            SliderRow()
            when (mode) {
                ShapeMode.PRESET -> Presets()
                ShapeMode.SHAPE -> Items()
                else -> {}
            }
            if (detecting && (mode == ShapeMode.PRESET || mode == ShapeMode.SHAPE)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                    Text("正在识别人体…", fontSize = 13.sp, color = Color.White)
                }
            }
            error?.let { Text(it, fontSize = 12.sp, color = Color(1f, 0.45f, 0.4f), modifier = Modifier.fillMaxWidth()) }
        }
    }

    @Composable
    private fun Options() {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (mode == ShapeMode.TALL) {
                Chip("头部保护", selected = headProtect, symbol = if (headBusy) "hourglass" else "person.crop.circle") { changeHeadProtect(!headProtect) }
            } else {
                Chip("背景保护", selected = protect, symbol = if (protectBusy) "hourglass" else null) {
                    if (protect) aiFill = false
                    changeProtect(!protect)
                }
                // AI 补背景：打开时让 AI 补一张没有人的背景（计一次费），人让出来的地方用它。
                Chip("补背景", selected = aiFill && protect, symbol = if (aiFillBusy) "hourglass" else null, badge = "AI") {
                    changeAIFill(!(aiFill && protect))
                }
                Chip("变形还原", selected = restoring) { changeRestoring(!restoring) }
            }
            Spacer(Modifier.weight(1f))
            RoundButton("arrow.uturn.backward") { undo() }
            RoundButton("arrow.counterclockwise") { reset() }
        }
    }

    @Composable
    private fun RoundButton(symbol: String, onClick: () -> Unit) {
        Box(Modifier.size(36.dp).clip(CircleShape).background(Theme.chip).tap(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(18.dp))
        }
    }

    @Composable
    private fun SliderRow() {
        if (restoring) {
            LabeledSlider("笔刷", restoreBrush, { restoreBrush = it }, 0.02f..0.15f)
            return
        }
        val value = amount
        val single = mode == ShapeMode.PRESET
        val disabled = needsBody || (single && preset == null)
        Row(
            Modifier.alpha(if (disabled) 0.35f else 1f),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("${(value * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.width(44.dp))
            XSlider(value, { if (!disabled) setAmount(it) }, if (single) 0f..1f else -1f..1f, Modifier.weight(1f), enabled = !disabled)
            if (mode == ShapeMode.SHAPE && item.hasSides) SideMenu(disabled)
        }
    }

    @Composable
    private fun SideMenu(disabled: Boolean) {
        var open by remember { mutableStateOf(false) }
        Box {
            Row(
                Modifier.clip(CircleShape).border(1.dp, Color.White.copy(alpha = 0.7f), CircleShape)
                    .tap(!disabled) { open = true }.padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(side.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Icon(sym("chevron.up"), null, tint = Color.White, modifier = Modifier.size(12.dp))
            }
            DropdownMenu(open, { open = false }, containerColor = Theme.panel) {
                for (s in ShapeSide.entries) {
                    DropdownMenuItem(
                        text = { Text(s.title, color = Color.White) },
                        trailingIcon = if (side == s) ({ Icon(sym("checkmark"), null, tint = Color.White) }) else null,
                        onClick = { side = s; open = false },
                    )
                }
            }
        }
    }

    /** 一键美体：本机的两套 + 交给 AI 的几套。 */
    @Composable
    private fun Presets() {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Top,
        ) {
            FeatureTile("photo", "原图", selected = preset == null) { selectPreset(null) }
            for (p in ShapePreset.all) {
                val usable = body != null
                Box(Modifier.alpha(if (usable) 1f else 0.35f)) {
                    FeatureTile(if (p.title == "超模") "figure.walk" else "figure.stand", p.title, selected = preset == p.id) {
                        if (usable) selectPreset(p.id)
                    }
                }
            }
            GenderToggle(Modifier.padding(top = 14.dp).padding(horizontal = 4.dp))
            for (look in if (GenderSetting.isMale) MalePresets.shapeLooks else ShapeAI.looks) {
                FeatureTile(look.symbol, look.title, badge = "AI") { model.startAIPreset(look, AIPresetGroup.BODY) }
            }
        }
    }

    /** 塑形：上面一排部位，下面是这个部位能调的各项。 */
    @Composable
    private fun Items() {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (g in ShapeGroup.entries) {
                    Chip(g.title, selected = group == g) {
                        group = g
                        val b = body
                        if (b != null) g.items.firstOrNull { !it.isAI && it.available(b) }?.let { selectItem(it) }
                    }
                }
            }
            key(group) {
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    // 认不出人体、本机的项用不了时，AI 的排在前面。
                    val tiles = if (detected && body == null) group.items.sortedBy { !it.isAI } else group.items
                    for (si in tiles) {
                        val b = body
                        val usable = si.isAI || (b != null && si.available(b))
                        IconTile(
                            si.symbol, si.title,
                            selected = !si.isAI && item == si,
                            badge = if (si.isAI) "AI" else null,
                            modified = values[si]?.isZero == false,
                            enabled = usable,
                        ) { selectItem(si) }
                    }
                }
            }
        }
    }
}

private val FILL_PROMPT =
    "Remove every person from this photo completely, including their hair, clothes, shadows and anything they are holding. " +
        "Fill the area where they were with the background that would naturally be behind them: continue the walls, floor, " +
        "railings, buildings, lights and textures with the same perspective, lighting, color and sharpness as the rest of the photo. " +
        "Do not add any new people or objects. Keep every other part of the photo exactly the same, same framing and size."
