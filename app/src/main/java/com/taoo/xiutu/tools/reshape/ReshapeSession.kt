package com.taoo.xiutu.tools.reshape

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
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
import kotlin.math.max
import kotlin.math.roundToInt

private val ERROR_RED = Color(1f, 0.45f, 0.4f)

/** 面部重塑：按五官关键点做局部变形，另有调颜色的三项和交给 AI 的项目。 */
class ReshapeSession(model: EditorModel) : ToolSession(model, Tool.RESHAPE), FaceSeeker {
    // 每张脸的数值、背景保护的蒙版、变形还原的笔画
    private var faces by mutableStateOf<List<ReshapeFace>>(emptyList())
    private var lockMask by mutableStateOf<Bitmap?>(null)
    private var restore by mutableStateOf<List<ReshapeRestoreStroke>>(emptyList())

    var detecting by mutableStateOf(false)
    /** 找不到脸、五官不可信、识别不到人物这类错误提示。 */
    var error by mutableStateOf<String?>(null)
    var faceIndex by mutableIntStateOf(0)
    var category by mutableStateOf(ReshapeCategory.SHAPE)
    /** 当前在调的项目；这一类里只有 AI 项目时是 null。 */
    var current by mutableStateOf<ReshapeKey?>(ReshapeKey.FACE_WIDTH)
    var side by mutableStateOf(ReshapeSide.BOTH)

    /** 背景保护：变形只动人，背景不动。 */
    var protect by mutableStateOf(false)
    var protectBusy by mutableStateOf(false)
    /** 变形还原：用手指把涂过的地方恢复成没变形的样子。 */
    var restoring by mutableStateOf(false)
    /** 还原笔刷的直径（dp）。 */
    var brush by mutableFloatStateOf(70f)

    /** 每张脸的关键点能不能用（和 faces 一一对应）；当前这张脸上哪几类因为关键点不对而调不了。 */
    var usable by mutableStateOf<List<Boolean>>(emptyList())
    var missing by mutableStateOf<Set<ReshapeCategory>>(emptySet())

    private var focus by mutableStateOf<RectF?>(null)
    @Volatile private var closed = false
    /** 提前算好的人像蒙版和"没有人的背景"（实时预览用）。 */
    private var personMask: Bitmap? = null
    private var plate: ReshapePlate? = null
    private var strokeRadius = 0f
    private val density = model.context.resources.displayMetrics.density

    private val params: ReshapeParams get() = ReshapeParams(faces, lockMask, restore)
    private val face: ReshapeFace? get() = faces.getOrNull(faceIndex)

    /** 当前项目显示在滑块上的数值（-1...1）。 */
    val value: Float
        get() {
            val k = current ?: return 0f
            val f = face ?: return 0f
            return f.value(k, if (k.paired) side else ReshapeSide.BOTH)
        }

    fun isModified(k: ReshapeKey) = face?.values?.containsKey(k) == true

    val hasChanges: Boolean get() = !params.isIdentity

    override val focusRect: RectF? get() = focus
    override val drawing: Boolean get() = restoring
    override val wantsTap: Boolean get() = true

    override fun start() {
        val base = model.base ?: return
        detecting = true
        model.scope.launch {
            val found = model.faceSearch.find()
            if (closed) return@launch
            detecting = false
            error = null
            faces = found.map { ReshapeFace(it) }
            usable = found.map { ReshapeParams.usable(it, base.width, base.height) }
            if (found.isEmpty()) {
                error = "这张图里没有找到人脸。"
            } else {
                val index = usable.indexOf(true)
                if (index >= 0) selectFace(index)
                else error = "找到了脸，但五官位置认不准（脸太小、太糊或者侧得太多），没法做面部重塑。"
            }
        }
    }

    override fun close() {
        closed = true
    }

    /** 点 ✓ 时要写进历史的那一步；没改返回空。 */
    override fun commitOps(): List<EditOp> {
        val p = params
        return if (p.isIdentity) emptyList() else listOf(p)
    }

    /** 单击了画面：还原模式下在这里点一下还原一小片；否则点哪张脸就选哪张脸。 */
    override val lacksFace: Boolean get() = !detecting && !usable.contains(true)

    override fun redetectFaces() = start()

    override fun onTap(p: PointF) {
        if (model.faceSearch.tap(p)) return
        if (detecting) return
        val base = model.base ?: return
        if (restoring) {
            val f = face ?: return
            if (!hasChanges) return
            val long = max(max(base.width, base.height), 1).toFloat()
            val radius = max(f.info.box.width() * base.width / long * 0.22f, 0.01f)
            restore = restore + ReshapeRestoreStroke(listOf(p), radius)
            render()
            return
        }
        val hits = faces.indices.filter { i ->
            val b = faces[i].info.box
            usable.getOrElse(i) { false } &&
                RectF(b.left - b.width() * 0.2f, b.top - b.height() * 0.3f, b.right + b.width() * 0.2f, b.bottom + b.height() * 0.3f)
                    .contains(p.x, p.y)
        }
        val index = hits.minByOrNull { faces[it].info.box.width() } ?: return
        selectFace(index)
    }

    fun selectFace(index: Int) {
        if (index !in faces.indices) return
        faceIndex = index
        // 这张脸上嘴唇、鼻子、眉毛的关键点各自对不对，不对的那一类不让调。
        val info = faces[index].info
        val base = model.base
        val w = base?.width ?: 1
        val h = base?.height ?: 1
        missing = listOf(ReshapeCategory.LIPS, ReshapeCategory.NOSE, ReshapeCategory.BROWS)
            .filter { !ReshapeParams.supports(it, info, w, h) }.toSet()
        updateFocus()
    }

    /** 把画面放大到当前这张脸。 */
    private fun updateFocus() {
        val f = face
        val base = model.base
        if (f == null || base == null || base.width <= 0 || base.height <= 0) { focus = null; return }
        val sw = base.width.toFloat()
        val sh = base.height.toFloat()
        val bw = f.info.box.width() * sw
        val bh = f.info.box.height() * sh
        val s = max(bw, bh) * 2.1f
        val cx = f.info.box.centerX() * sw
        // 人脸框不含额头上半部分，往上挪一点把头顶也框进来。
        val cy = f.info.box.centerY() * sh - bh * 0.12f
        val r = RectF(cx - s / 2, cy - s / 2, cx + s / 2, cy + s / 2)
        if (!r.intersect(0f, 0f, sw, sh)) { focus = null; return }
        focus = RectF(r.left / sw, r.top / sh, r.right / sw, r.bottom / sh)
    }

    // MARK: 调数值

    fun selectCategory(c: ReshapeCategory) {
        category = c
        current = c.keys.firstOrNull()
        side = ReshapeSide.BOTH
    }

    fun selectKey(k: ReshapeKey) {
        current = k
        if (!k.paired) side = ReshapeSide.BOTH
    }

    /** 改当前项目的数值（-1...1）。 */
    fun setValue(v: Float) {
        val k = current ?: return
        if (faceIndex !in faces.indices) return
        val snapped = if (abs(v) < 0.02f) 0f else v
        faces = faces.toMutableList().also { it[faceIndex] = it[faceIndex].set(k, side, snapped) }
        render()
    }

    /** 全部还原：所有脸的数值和还原笔画都清掉。 */
    fun resetAll() {
        faces = faces.map { it.copy(values = emptyMap()) }
        restore = emptyList()
        render()
    }

    private fun render() {
        val p = params
        val pl = plate
        model.liveOnBase { p.apply(it, pl) }
    }

    // MARK: 背景保护

    /** 开关背景保护。第一次打开时在本机识别一次人像，并把"没有人的背景"提前补好。 */
    fun switchProtect(on: Boolean) {
        if (protectBusy) return
        if (!on) {
            protect = false
            lockMask = null
            render()
            return
        }
        personMask?.let {
            protect = true
            lockMask = it
            render()
            return
        }
        val base = model.base ?: return
        protectBusy = true
        error = null
        model.scope.launch {
            val found = withContext(Dispatchers.Default) {
                runCatching {
                    val mask = PersonSegmenter.mask(base) ?: return@runCatching null
                    mask to ReshapePlate.make(base, mask)
                }.onFailure { it.printStackTrace() }.getOrNull()
            }
            if (closed) return@launch
            protectBusy = false
            if (found == null) {
                error = "这张图里没有识别到人物，没法保护背景。"
                return@launch
            }
            personMask = found.first
            plate = found.second
            protect = true
            lockMask = found.first
            render()
        }
    }

    // MARK: 变形还原

    fun undoRestore() {
        if (restore.isEmpty()) return
        restore = restore.dropLast(1)
        render()
    }

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (!restoring || displayScale <= 0) return
        strokeRadius = brush * density / 2 / displayScale
        restore = restore + ReshapeRestoreStroke(listOf(p), strokeRadius)
        render()
    }

    override fun strokeMoved(p: PointF) {
        if (!restoring || restore.isEmpty()) return
        val last = restore.last()
        restore = restore.dropLast(1) + last.copy(points = last.points + p)
        render()
    }

    /** 第二根手指落下、手势被取消：撤掉刚开始的这一笔。 */
    override fun strokeCancelled() = undoRestore()

    // MARK: AI 项目

    /** 点了带 AI 角标的项目：已经调好的先保留成一步，再把脸部发给 AI。 */
    fun runAI(item: ReshapeAIItem) {
        model.startAIPreset(item.preset, AIPresetGroup.FIX)
    }

    // MARK: 界面

    /** 面部重塑面板：上面是背景保护、变形还原和重置，中间一根滑块，下面一排项目。 */
    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            TopRow()
            val err = error
            if (detecting) {
                Row(
                    Modifier.fillMaxWidth().padding(vertical = 26.dp),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(10.dp))
                    Text("正在找人脸…", fontSize = 14.sp, color = Color.White)
                }
            } else if (err != null && !usable.contains(true)) {
                FaceRescue(model, err.trim('。'))
            } else {
                if (err != null) Text(err, fontSize = 12.sp, color = ERROR_RED, modifier = Modifier.fillMaxWidth())
                if (category in missing) {
                    Text("这张脸的${category.title}位置认不准，这一组调不了。", fontSize = 12.sp, color = ERROR_RED, modifier = Modifier.fillMaxWidth())
                } else if (restoring) {
                    BrushRow()
                } else if (current != null) {
                    SliderRow()
                }
                Tiles()
            }
        }
    }

    @Composable
    private fun TopRow() {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("背景保护", selected = protect, symbol = if (protectBusy) "hourglass" else "person.and.background.dotted") {
                switchProtect(!protect)
            }
            Chip("变形还原", selected = restoring, symbol = "bandage") { restoring = !restoring }
            Spacer(Modifier.weight(1f))
            if (usable.count { it } > 1) {
                Row(
                    Modifier.widthIn(max = 130.dp).horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    for (i in faces.indices) {
                        if (!usable.getOrElse(i) { false }) continue
                        Chip(if (faces[i].isIdentity) "脸${i + 1}" else "脸${i + 1} ✓", selected = faceIndex == i) { selectFace(i) }
                    }
                }
            }
            val changed = hasChanges
            Box(
                Modifier.size(36.dp, 34.dp).clip(CircleShape).background(Theme.chip).tap(changed) { resetAll() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(sym("arrow.counterclockwise"), "全部还原", tint = if (changed) Color.White else Theme.dim, modifier = Modifier.size(17.dp))
            }
        }
    }

    @Composable
    private fun SliderRow() {
        val k = current ?: ReshapeKey.FACE_WIDTH
        val v = value
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("${(v * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.width(44.dp))
            XSlider(v, { setValue(it) }, if (k.bipolar) -1f..1f else 0f..1f, Modifier.weight(1f))
            if (k.paired) {
                var open by remember { mutableStateOf(false) }
                Box {
                    Row(
                        Modifier.height(30.dp).clip(CircleShape).border(1.dp, Color(0.45f, 0.45f, 0.45f), CircleShape)
                            .tap { open = true }.padding(horizontal = 10.dp),
                        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(side.title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                        Icon(sym("chevron.up.chevron.down"), null, tint = Color.White, modifier = Modifier.size(12.dp))
                    }
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        for (s in ReshapeSide.entries) {
                            DropdownMenuItem(
                                text = { Text(s.title) },
                                leadingIcon = if (side == s) ({ Icon(sym("checkmark"), null) }) else null,
                                onClick = { side = s; open = false },
                            )
                        }
                    }
                }
            }
            Box(Modifier.size(32.dp, 36.dp).tap { setValue(0f) }, contentAlignment = Alignment.Center) {
                Icon(sym("arrow.counterclockwise"), null, tint = if (v == 0f) Theme.dim else Color.White, modifier = Modifier.size(18.dp))
            }
        }
    }

    /** 变形还原时：笔刷大小和撤销一笔。 */
    @Composable
    private fun BrushRow() {
        val canUndo = restore.isNotEmpty()
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Box(Modifier.width(44.dp)) { Icon(sym("circle.dashed"), null, tint = Theme.dim, modifier = Modifier.size(18.dp)) }
            XSlider(brush, { brush = it }, 30f..160f, Modifier.weight(1f))
            Box(Modifier.size(36.dp).tap(canUndo) { undoRestore() }, contentAlignment = Alignment.Center) {
                Icon(sym("arrow.uturn.backward"), "撤销一笔", tint = if (canUndo) Color.White else Theme.dim, modifier = Modifier.size(18.dp))
            }
        }
    }

    @Composable
    private fun Tiles() {
        androidx.compose.runtime.key(category) {
            Row(
                Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                for (item in ReshapeAIItem.items(category)) {
                    IconTile(item.symbol, item.title, badge = "AI") { runAI(item) }
                }
                if (category !in missing) {
                    for (k in category.keys) {
                        IconTile(k.symbol, k.title, selected = !restoring && current == k, modified = isModified(k)) {
                            restoring = false
                            selectKey(k)
                        }
                    }
                }
            }
        }
    }

    /** 底部确认栏（✕ 和 ✓ 之间）：表情管理 / 3D塑颜 / 比例 / 脸型 / 眼睛 …… 可以横着滑。 */
    @Composable
    override fun Title() {
        val state = rememberLazyListState()
        val scope = rememberCoroutineScope()
        val all = ReshapeCategory.entries
        suspend fun center(index: Int, animate: Boolean) {
            val info = state.layoutInfo
            val item = info.visibleItemsInfo.firstOrNull { it.index == index }
            if (item == null) {
                if (animate) state.animateScrollToItem(index) else state.scrollToItem(index)
                return
            }
            val viewport = info.viewportEndOffset - info.viewportStartOffset
            val delta = item.offset + item.size / 2f - viewport / 2f
            if (animate) state.animateScrollBy(delta) else state.scrollBy(delta)
        }
        LaunchedEffect(Unit) { center(all.indexOf(category), animate = false) }
        LazyRow(
            state = state,
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(22.dp),
            contentPadding = PaddingValues(horizontal = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            itemsIndexed(all) { index, c ->
                val on = c == category
                Column(
                    Modifier.tap {
                        selectCategory(c)
                        scope.launch { center(index, animate = true) }
                    },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Text(c.title, fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) Color.White else Theme.dim, maxLines = 1)
                    Box(Modifier.size(18.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
                }
            }
        }
    }
}
