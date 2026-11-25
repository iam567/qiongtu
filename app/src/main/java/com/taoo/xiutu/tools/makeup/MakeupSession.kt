package com.taoo.xiutu.tools.makeup

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.currentLooks
import com.taoo.xiutu.ai.maleLooks
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.FaceRescue
import com.taoo.xiutu.editor.FaceSeeker
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 美妆：按人脸关键点上妆（口红、眉毛、眼妆、修容、腮红），美甲和装饰交给 AI。 */
class MakeupSession(model: EditorModel) : ToolSession(model, Tool.MAKEUP), FaceSeeker {
    var faces by mutableStateOf<List<FaceInfo>>(emptyList())
        private set
    var detecting by mutableStateOf(false)
        private set
    /** 找到了脸，但都太小或太侧，五官定位不可信。 */
    var unreliable by mutableStateOf(false)
        private set
    var faceIndex by mutableIntStateOf(0)
        private set
    /** 每张脸上的妆，和 faces 一一对应。 */
    var params by mutableStateOf(MakeupParams())
        private set
    var category by mutableStateOf(MakeupCategory.LOOK)
        private set
    private var tabIndex by mutableStateOf<Map<MakeupCategory, Int>>(emptyMap())
    /** 每张脸在每个槽位选了哪套预设。 */
    private var picks by mutableStateOf<Map<Int, Map<String, String>>>(emptyMap())
    /** 整套预设（妆容、眼妆、立体）的浓淡滑块位置。 */
    private var strengths by mutableStateOf<Map<Int, Map<String, Float>>>(emptyMap())
    /** 修容里正在调的高光 / 阴影分区。 */
    var zone by mutableStateOf<String?>(null)
        private set
    var placingMole by mutableStateOf(false)
        private set
    val thumbs = mutableStateMapOf<String, Bitmap>()
    private val requested = HashSet<String>()
    private var focus by mutableStateOf<RectF?>(null)
    private val jobs = ArrayList<Job>()
    @Volatile private var closed = false

    val tab: Int get() = tabIndex[category] ?: 0
    val current: FaceMakeup? get() = params.faces.getOrNull(faceIndex)
    fun pick(slot: String): String? = picks[faceIndex]?.get(slot)
    private fun strength(slot: String): Float = strengths[faceIndex]?.get(slot) ?: 0.8f

    // MARK: 工具进出

    override fun start() {
        MKMaskCache.removeAll()
        val b = model.base ?: return
        detecting = true
        jobs += model.scope.launch {
            val list = model.faceSearch.find()
            val found = withContext(Dispatchers.Default) {
                list.map { it to (runCatching { MKTone.measure(it, b) }.getOrNull() ?: MKTone()) }
            }
            if (closed) return@launch
            val usable = found.filter { it.first.hasReliableLandmarks && it.first.outerLips.size >= 6 }
            detecting = false
            unreliable = usable.isEmpty() && found.isNotEmpty()
            faces = usable.map { it.first }
            params = MakeupParams(usable.map { FaceMakeup(it.first, it.second) })
            faceIndex = 0
            focusFace()
        }
    }

    override fun close() {
        closed = true
        jobs.forEach { it.cancel() }
        jobs.clear()
    }

    /** 点 ✓ 时要写进历史的那一步；没改返回空。 */
    override fun commitOps(): List<EditOp> = if (params.isIdentity) emptyList() else listOf(params)

    override val focusRect: RectF? get() = focus

    override val wantsTap: Boolean get() = true

    /** 单击了画面：正在点痣就落一颗痣，否则点到哪张脸就切到哪张。 */
    override val lacksFace: Boolean get() = !detecting && faces.isEmpty() && category.isLocal

    override fun redetectFaces() = start()

    override fun onTap(p: PointF) {
        if (model.faceSearch.tap(p)) return
        val face = current
        if (placingMole && face != null) {
            val box = face.face.box
            val area = RectF(box.left - box.width() * 0.25f, box.top - box.height() * 0.3f,
                box.right + box.width() * 0.25f, box.bottom + box.height() * 0.3f)
            if (!area.contains(p.x, p.y)) return
            changeMakeup { m ->
                if (m.contour.moles.size < 16) {
                    val spot = MKMoleSpot.Custom((p.x * 10_000).roundToInt(), (p.y * 10_000).roundToInt())
                    m.copy(contour = m.contour.copy(moles = m.contour.moles + spot))
                } else m
            }
            return
        }
        if (faces.size <= 1) return
        var best: Pair<Int, Float>? = null
        for ((i, f) in faces.withIndex()) {
            val b = f.box
            val area = RectF(b.left - b.width() * 0.35f, b.top - b.height() * 0.45f, b.right + b.width() * 0.35f, b.bottom + b.height() * 0.45f)
            if (!area.contains(p.x, p.y)) continue
            val d = hypot(p.x - b.centerX(), p.y - b.centerY())
            if (best == null || d < best.second) best = i to d
        }
        best?.let { selectFace(it.first) }
    }

    // MARK: 选脸

    fun selectFace(index: Int) {
        if (index !in faces.indices) return
        faceIndex = index
        zone = null
        focusFace()
    }

    /** 把画布放大到正在化妆的这张脸。 */
    private fun focusFace() {
        val b = model.base
        val face = faces.getOrNull(faceIndex)
        if (face == null || b == null) { focus = null; return }
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val bw = face.box.width() * w
        val bh = face.box.height() * h
        val side = max(bw, bh) * 1.9f
        val cx = face.box.centerX() * w
        val cy = face.box.centerY() * h - bh * 0.1f
        val l = max(cx - side / 2, 0f)
        val t = max(cy - side / 2, 0f)
        val r = min(cx + side / 2, w)
        val bt = min(cy + side / 2, h)
        focus = if (r > l && bt > t) RectF(l / w, t / h, r / w, bt / h) else null
    }

    // MARK: 改妆

    /** 改当前这张脸的妆并刷新画面。 */
    fun changeMakeup(body: (FaceMakeup) -> FaceMakeup) {
        val i = faceIndex
        if (i !in params.faces.indices) return
        params = MakeupParams(params.faces.toMutableList().also { it[i] = body(it[i]) })
        render()
    }

    private fun render() {
        val p = params
        model.liveOnBase { p.apply(it) }
    }

    fun selectCategory(c: MakeupCategory) {
        category = c
        zone = null
        placingMole = false
    }

    fun selectTab(index: Int) {
        tabIndex = tabIndex + (category to index)
        zone = null
        placingMole = false
    }

    private fun setPick(slot: String, name: String?) {
        val mine = (picks[faceIndex] ?: emptyMap()).toMutableMap()
        if (name == null) mine.remove(slot) else mine[slot] = name
        picks = picks + (faceIndex to mine)
    }

    private fun remember(slot: String, v: Float) {
        strengths = strengths + (faceIndex to ((strengths[faceIndex] ?: emptyMap()) + (slot to v)))
    }

    /** 点了面板上的一个选项。 */
    fun choose(option: MakeupOption) {
        val kind = option.kind
        if (kind is MakeupOption.Kind.Ai) {
            model.startAIPreset(kind.preset, AIPresetGroup.FIX)
            return
        }
        if (option.togglesMolePlacing) {
            placingMole = !placingMole
            return
        }
        // 单独改了某一样，就不再是"一整套"了
        if (category != MakeupCategory.LOOK) setPick("look", null)
        if (category == MakeupCategory.EYE && tab != 0) setPick("eye", null)
        if (category == MakeupCategory.CONTOUR && (tab == 1 || tab == 2)) setPick("sculpt", null)
        if (category == MakeupCategory.LIP && tab != 0) setPick("lip", null)
        if (category == MakeupCategory.BLUSH && tab != 0) setPick("blush", null)
        option.slot?.let { slot ->
            setPick(slot, if (option.id == "none") null else option.id)
            remember(slot, 0.8f)
            // 换了整套妆，各部分原来单独选的预设都不算数了
            if (slot == "look") for (part in listOf("lip", "eye", "sculpt", "blush")) setPick(part, null)
        }
        if (option.zone != null) zone = option.zone else if (option.id == "none") zone = null
        changeMakeup(option.apply)
    }

    // MARK: 浓淡滑块

    /** 当前这一页的浓淡；null = 这一页现在没有可调的。 */
    val amount: Float?
        get() {
            val m = current ?: return null
            return when (category) {
                MakeupCategory.LOOK -> if (pick("look") == null) null else strength("look")
                MakeupCategory.LIP -> m.lip?.let { if (tab == 4) it.liner else it.amount }
                MakeupCategory.BROW -> m.brow?.amount
                MakeupCategory.EYE -> when (tab) {
                    0 -> if (pick("eye") == null) null else strength("eye")
                    1 -> m.eye.shadow?.amount
                    2 -> m.eye.liner?.amount
                    3 -> m.eye.lashes?.amount
                    4 -> m.eye.aegyo
                    5 -> m.eye.lens?.amount
                    6 -> m.eye.foldAmount
                    else -> m.eye.catchlightAmount
                }
                MakeupCategory.CONTOUR -> when (tab) {
                    0 -> if (pick("sculpt") == null) null else strength("sculpt")
                    1, 2 -> zone?.let { zoneValue(it, m.contour) }
                    3 -> m.contour.freckleAmount
                    else -> null
                }
                MakeupCategory.BLUSH -> m.blush?.amount
                MakeupCategory.NAIL, MakeupCategory.DECOR -> null
            }
        }

    fun setAmount(value: Float) {
        val v = value.coerceIn(0f, 1f)
        val t = tab
        fun FaceMakeup.eye(change: (EyeMakeup) -> EyeMakeup) = copy(eye = change(eye))
        when (category) {
            MakeupCategory.LOOK -> {
                val name = pick("look") ?: return
                val look = (MakeupCatalog.currentLooks + MakeupCatalog.looks + MakeupCatalog.maleLooks).firstOrNull { it.name == name } ?: return
                remember("look", v)
                changeMakeup { it.applying(look, v / 0.8f) }
            }
            MakeupCategory.LIP -> changeMakeup { m -> m.copy(lip = m.lip?.let { if (t == 4) it.copy(liner = v) else it.copy(amount = v) }) }
            MakeupCategory.BROW -> changeMakeup { m -> m.copy(brow = m.brow?.copy(amount = v)) }
            MakeupCategory.EYE -> when (t) {
                0 -> {
                    val name = pick("eye") ?: return
                    remember("eye", v)
                    changeMakeup { it.copy(eye = MakeupCatalog.eyePreset(name).scaled(v / 0.8f)) }
                }
                1 -> changeMakeup { m -> m.eye { it.copy(shadow = it.shadow?.copy(amount = v)) } }
                2 -> changeMakeup { m -> m.eye { it.copy(liner = it.liner?.copy(amount = v)) } }
                3 -> changeMakeup { m -> m.eye { it.copy(lashes = it.lashes?.copy(amount = v)) } }
                4 -> changeMakeup { m -> m.eye { it.copy(aegyo = v) } }
                5 -> changeMakeup { m -> m.eye { it.copy(lens = it.lens?.copy(amount = v)) } }
                6 -> changeMakeup { m -> m.eye { it.copy(foldAmount = v) } }
                else -> changeMakeup { m -> m.eye { it.copy(catchlightAmount = v) } }
            }
            MakeupCategory.CONTOUR -> when (t) {
                0 -> {
                    val name = pick("sculpt") ?: return
                    remember("sculpt", v)
                    changeMakeup { m -> m.copy(contour = m.contour.withSculpt(MakeupCatalog.contourPreset(name).scaledSculpt(v / 0.8f))) }
                }
                1, 2 -> {
                    val z = zone ?: return
                    changeMakeup { m -> m.copy(contour = setZone(z, v, m.contour)) }
                }
                3 -> changeMakeup { m -> m.copy(contour = m.contour.copy(freckleAmount = v)) }
                else -> {}
            }
            MakeupCategory.BLUSH -> changeMakeup { m -> m.copy(blush = m.blush?.copy(amount = v)) }
            MakeupCategory.NAIL, MakeupCategory.DECOR -> {}
        }
    }

    // MARK: 自选颜色

    /** 这一页能不能自己选颜色，以及现在是什么颜色。 */
    val customColor: MakeupColor?
        get() {
            val m = current ?: return null
            return when {
                category == MakeupCategory.LIP && tab == 1 -> m.lip?.color ?: MakeupCatalog.lipColors[0].color
                category == MakeupCategory.BROW && tab == 1 -> m.brow?.color ?: MakeupCatalog.browColors[1].color
                category == MakeupCategory.BLUSH && tab == 1 -> m.blush?.color ?: MakeupCatalog.blushColors[0].color
                else -> null
            }
        }

    fun setCustomColor(color: MakeupColor) {
        setPick("look", null)
        when {
            category == MakeupCategory.LIP && tab == 1 -> {
                setPick("lip", null)
                changeMakeup { m -> m.copy(lip = m.lip?.copy(color = color) ?: LipMakeup(color)) }
            }
            category == MakeupCategory.BROW && tab == 1 ->
                changeMakeup { m -> m.copy(brow = (m.brow ?: MakeupCatalog.browPreset(MKBrowShape.NATURAL)).copy(color = color)) }
            category == MakeupCategory.BLUSH && tab == 1 -> {
                setPick("blush", null)
                changeMakeup { m -> m.copy(blush = m.blush?.copy(color = color) ?: BlushMakeup(color)) }
            }
        }
    }

    // MARK: 缩略图

    fun thumbKey(option: MakeupOption) = "$faceIndex|${category.name}|$tab|${option.id}"

    /** 这一页的选项里还没有缩略图的，在后台用这张脸渲染出来。 */
    fun prepareThumbs(options: List<MakeupOption>, crop: MakeupCrop) {
        val base = model.base ?: return
        val face = current ?: return
        val pending = ArrayList<Pair<String, FaceMakeup>>()
        for (option in options) {
            if (option.kind != MakeupOption.Kind.Thumb) continue
            val key = thumbKey(option)
            if (!requested.add(key)) continue
            pending += key to option.preview(FaceMakeup(face.face, face.tone))
        }
        if (pending.isEmpty()) return
        val info = face.face
        jobs += model.scope.launch(Dispatchers.Default) {
            // 缩略图只有指甲盖大：先把图缩到"脸宽 400 像素"左右再上妆，又快又省内存
            var small = base
            val boxWidth = info.box.width() * base.width
            if (boxWidth > 400) small = Img.downscale(base, (max(base.width, base.height) * 400 / boxWidth).toInt())
            val w = small.width.toFloat()
            val h = small.height.toFloat()
            val g = MKFace.create(info, w, h) ?: return@launch
            val r = MakeupThumb.rect(crop, g)
            val ax = floor(max(r.minX, 0f)).toInt()
            val ay = floor(max(r.minY, 0f)).toInt()
            val ax1 = ceil(min(r.maxX, w)).toInt()
            val ay1 = ceil(min(r.maxY, h)).toInt()
            if (ax1 - ax < 8 || ay1 - ay < 8) return@launch
            val area = Bitmap.createBitmap(small, ax, ay, ax1 - ax, ay1 - ay)
            val batch = HashMap<String, Bitmap>()
            for ((index, job) in pending.withIndex()) {
                if (closed) return@launch
                val piece = area.copy(Bitmap.Config.ARGB_8888, true)
                runCatching { MakeupParams(listOf(job.second)).applyInto(piece, w, h, ax, ay) }.onFailure { it.printStackTrace() }
                batch[job.first] = Img.downscale(piece, 200)
                // 每几张交一次，缩略图一批批出来，不用等全部画完
                if (batch.size >= 6 || index == pending.size - 1) {
                    val ready = HashMap(batch)
                    batch.clear()
                    withContext(Dispatchers.Main) { if (!closed) thumbs.putAll(ready) }
                }
            }
        }
    }

    // MARK: 界面

    @Composable
    override fun Panel() = MakeupPanel(this)

    @Composable
    override fun Title() = MakeupTitle(this)

    companion object {
        fun zoneValue(zone: String, c: ContourMakeup): Float = when (zone) {
            "forehead" -> c.forehead
            "noseLight" -> c.noseLight
            "cheekLight" -> c.cheekLight
            "chinLight" -> c.chinLight
            "cupid" -> c.cupid
            "underEye" -> c.underEye
            "noseShade" -> c.noseShade
            "jaw" -> c.jaw
            "cheekShade" -> c.cheekShade
            else -> c.temple
        }

        fun setZone(zone: String, v: Float, c: ContourMakeup): ContourMakeup = when (zone) {
            "forehead" -> c.copy(forehead = v)
            "noseLight" -> c.copy(noseLight = v)
            "cheekLight" -> c.copy(cheekLight = v)
            "chinLight" -> c.copy(chinLight = v)
            "cupid" -> c.copy(cupid = v)
            "underEye" -> c.copy(underEye = v)
            "noseShade" -> c.copy(noseShade = v)
            "jaw" -> c.copy(jaw = v)
            "cheekShade" -> c.copy(cheekShade = v)
            else -> c.copy(temple = v)
        }
    }
}

/** 缩略图取脸上的哪一块（像素，原点左上角）。 */
object MakeupThumb {
    fun rect(crop: MakeupCrop, g: MKFace): MKRect {
        fun px(v: MKVec) = MKVec(g.roi.minX + v.x * g.roi.width, g.roi.minY + v.y * g.roi.height)
        fun square(points: List<MKVec>, grow: Float): MKRect {
            if (points.isEmpty()) return g.roi
            val p = points.map(::px)
            val minX = p.minOf { it.x }
            val maxX = p.maxOf { it.x }
            val minY = p.minOf { it.y }
            val maxY = p.maxOf { it.y }
            val side = max(maxX - minX, maxY - minY) * grow
            return MKRect((minX + maxX) / 2 - side / 2, (minY + maxY) / 2 - side / 2, side, side)
        }
        return when (crop) {
            MakeupCrop.FACE -> {
                val c = px(g.eyeMid + g.down * (g.mouthDist * 0.45f))
                val side = g.faceWidth * g.roi.width * 1.4f
                MKRect(c.x - side / 2, c.y - side / 2, side, side)
            }
            MakeupCrop.EYE -> {
                // 取露得多的那只眼睛，连眉毛一起
                val i = if (g.eyes[0].side >= g.eyes[1].side) 0 else 1
                val points = ArrayList(g.eyes[i].outline)
                g.brows[i]?.let { points += listOf(it.center.at(0f), it.center.at(0.5f), it.center.at(1f)) }
                square(points, 1.35f)
            }
            MakeupCrop.LIPS -> square(g.lipsOuter, 1.6f)
        }
    }
}
