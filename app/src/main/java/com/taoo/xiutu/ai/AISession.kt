package com.taoo.xiutu.ai

import android.graphics.Bitmap
import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.outfit.BackPill
import com.taoo.xiutu.ai.outfit.Outfit
import com.taoo.xiutu.ai.outfit.OutfitCatalog
import com.taoo.xiutu.ai.outfit.OutfitMask
import com.taoo.xiutu.ai.outfit.OutfitPanel
import com.taoo.xiutu.ai.outfit.OutfitSkirt
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.AIRecipe
import com.taoo.xiutu.editor.AiToolApi
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolRegistry
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.tools.mosaic.MosaicMaskSet
import com.taoo.xiutu.tools.mosaic.MosaicStroke
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.FeatureTile
import com.taoo.xiutu.ui.GenderSetting
import com.taoo.xiutu.ui.GenderToggle
import com.taoo.xiutu.ui.ImageTile
import com.taoo.xiutu.ui.SegmentBar
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * AI 修图：点一个功能就开始；想只改局部，先在图上涂抹。
 * AI 美体、美发也用这个工具，只是顶上换成各自的分组。
 */
class AISession(model: EditorModel) : ToolSession(model, Tool.AI), AiToolApi {
    var group by mutableStateOf(AIPresetGroup.FIX)
    var prompt by mutableStateOf("")
    var brush by mutableFloatStateOf(44f)
    var erasing by mutableStateOf(false)
    var running by mutableStateOf(false)
        private set
    private var started by mutableLongStateOf(0L)
    var error by mutableStateOf<String?>(null)
    var hasResult by mutableStateOf(false)
        private set
    var strength by mutableFloatStateOf(1f)
        private set
    /** 柔化：压 AI 结果过头的锐化。 */
    var soften by mutableFloatStateOf(0f)
        private set
    /** 同一条指令点了几次"再生成一次"；每次在指令后面加不同的变化要求，避免出来的图都一样。 */
    private var regenRound = 0
    private var lastPrompt = ""
    /** 大师风格：除了色彩，也按大师的习惯重新构图（默认开）。 */
    var masterCompose by mutableStateOf(true)
    /** 整张重画时贴回原图的脸：开关，以及这次对上的脸。 */
    private var keepFace by mutableStateOf(true)
    private var faces by mutableStateOf<List<FaceKeep>>(emptyList())
    /** 只在变了的地方用 AI 的像素（美体、去路人）：开关，以及这次能不能用。 */
    private var changedOnly by mutableStateOf(true)
    private var canKeepRest by mutableStateOf(false)
    private var area: Bitmap? = null
    private var shift = 0f to 0f
    /** 换衣服：这一块一定用 AI 的。 */
    private var core: Bitmap? = null
    /** 这次结果是换衣服（结果面板上的说法不一样）。 */
    private var resultOutfit by mutableStateOf(false)
    /** 换衣服：点了哪一款、颜色、裙摆、照着换的图；patch = 涂抹补换没换干净的地方。 */
    var outfitPick by mutableStateOf<Outfit?>(null)
        private set
    var outfitColor by mutableStateOf("")
    var outfitSkirt by mutableStateOf(OutfitSkirt.NORMAL)
    var outfitReference by mutableStateOf<Bitmap?>(null)
    private var outfitPatch by mutableStateOf(false)
    /** 这条指令只该动身体的哪一块。 */
    private var part: BodyPart? = null
    private var mono = false
    /** 这次先拿下来、出来以后再盖回去的滤镜和调色，以及没盖它们的底图。 */
    private var colorLift: List<EditOp> = emptyList()
    private var colorBase: Bitmap? = null
    /** 最近点的那个快捷指令的名字（大师构图按名字找取景方式）。 */
    private var presetTitle = ""
    /** 创意玩法里选中的那一类。 */
    private var creativeKind by mutableStateOf(CreativeKind.COMIC)
    /** 当前结果是图层 AI 融合来的（不能"再生成一次"）。 */
    var resultFused by mutableStateOf(false)
        private set
    /** 当前指令是不是"没涂抹就自动只处理头部"的那一类（修跑焦）。 */
    private var faceCrop = false
    /** 美发：没涂抹时自动找到人脸，把头和头发这一大块发给 AI。 */
    private var hairCrop = false
    /** 只采用 AI 的光影和颜色、细节保留原图。结果出来后可以切换，不用重新生成。 */
    var toneOnly by mutableStateOf(false)
        private set
    /** 构图时输出的画幅。 */
    var reframe by mutableStateOf(AIReframe.ORIGINAL)
    /** 当前这次结果是不是换了画幅。 */
    private var resultReframed by mutableStateOf(false)
    /** 最近一次请求的实际用量。 */
    private var usageText by mutableStateOf<String?>(null)
    /** 当前这次是怎么发起的（存进历史，套用步骤时用）；涂抹出来的是 null。 */
    private var pendingRecipe: AIRecipe? = null

    private val strokes = ArrayList<MosaicStroke>()
    private var strokeCount by mutableIntStateOf(0)
    private var maskSet: MosaicMaskSet? = null
    private var result: Bitmap? = null
    private var frame: RectF? = null
    private var ellipse: RectF? = null
    private var job: Job? = null
    /** 每发一次请求（或取消）加一：旧请求晚回来的结果直接丢掉。 */
    private var generation = 0
    private var closed = false
    private var lastEdit: AIEdit? = null
    private var photoThumb by mutableStateOf<Bitmap?>(null)
    /** 大师 / 相机 / 光线按钮上的小图：本机模拟的大致色调。 */
    private var toneThumbs by mutableStateOf<Map<String, Bitmap>>(emptyMap())
    private val density = model.context.resources.displayMetrics.density

    private val hasRegion get() = strokes.any { !it.erase }

    override val drawing: Boolean get() = true
    override val busy: Boolean get() = running
    override val liftedColor: List<EditOp> get() = if (hasResult) colorLift else emptyList()

    override fun start() {
        val b = model.base ?: return
        maskSet = MosaicMaskSet(b.width, b.height)
        model.scope.launch {
            photoThumb = withContext(Dispatchers.Default) { runCatching { Img.thumb(b, 260, 68f / 84f) }.getOrNull() }
            val titles = AIPresetGroup.entries.filter { it.usesTonePreview }.flatMap { g -> g.presets.map { it.title } }
            toneThumbs = withContext(Dispatchers.Default) {
                runCatching { com.taoo.xiutu.tools.filter.MasterPreview.thumbs(b, titles) }.getOrDefault(emptyMap())
            }
            // 创意玩法：本机能大致模拟的画风算一张小图
            val small = photoThumb ?: return@launch
            val creative = withContext(Dispatchers.Default) {
                CreativeKind.all.mapNotNull { p -> runCatching { CreativePreview.render(p.title, small) }.getOrNull()?.let { p.title to it } }.toMap()
            }
            if (!closed) toneThumbs = toneThumbs + creative
        }
    }

    override fun close() {
        closed = true
        job?.cancel()
        job = null
    }

    override fun setup(group: AIPresetGroup, prompt: String, preset: AIPreset?, run: Boolean) {
        this.group = group
        this.prompt = prompt
        presetTitle = preset?.title ?: ""
        reframe = AIReframe.ORIGINAL
        faceCrop = preset?.faceCrop ?: false
        hairCrop = preset?.hairCrop ?: false
        toneOnly = preset?.toneOnly ?: false
        part = preset?.part
        if (run) runAI()
    }

    fun pickOutfit(outfit: Outfit?) {
        error = null
        outfitPick = outfit
        if (outfit != null && outfitColor !in outfit.colors) outfitColor = outfit.colors.firstOrNull() ?: ""
        if (outfit?.skirt != true) outfitSkirt = OutfitSkirt.NORMAL
    }

    fun runOutfit(prompt: String, title: String) {
        error = null
        this.prompt = prompt
        presetTitle = title
        faceCrop = false
        hairCrop = false
        toneOnly = false
        part = null
        runAI()
    }

    /** 没换干净的地方：涂一下只补那一块。 */
    private fun runOutfitPatch() {
        if (!hasRegion) {
            error = "先涂抹没换干净的地方。"
            return
        }
        runOutfit(OutfitCatalog.PATCH_PROMPT, "补换")
    }

    /** 结果大体满意、只差一小块：先把结果定下来，再进补换。 */
    private fun startOutfitPatch() {
        if (running || model.isBusy) return
        val m = model
        m.commitTool { m.beginAI(AIPresetGroup.OUTFIT) { it.outfitPatch = true } }
    }

    override fun commitOps(): List<EditOp> {
        if (running) return emptyList()
        return currentEdit()?.let { listOf(it) } ?: emptyList()
    }

    // MARK: 涂抹

    override fun strokeBegan(p: PointF, displayScale: Float) {
        if (displayScale <= 0 || running || hasResult) return
        val s = AIRegion.stroke(listOf(p), brush * density / displayScale, erasing)
        strokes += s
        strokeCount = strokes.size
        maskSet?.add(listOf(p), s)
        render()
    }

    override fun strokeMoved(p: PointF) {
        if (running || hasResult) return
        val s = strokes.lastOrNull() ?: return
        val prev = s.points.lastOrNull() ?: return
        s.points += p
        maskSet?.add(listOf(prev, p), s)
        render()
    }

    override fun strokeCancelled() = undoStroke()

    fun undoStroke() {
        if (running || hasResult || strokes.isEmpty()) return
        strokes.removeAt(strokes.size - 1)
        strokeCount = strokes.size
        maskSet?.rebuild(strokes)
        render()
    }

    fun clearRegion() {
        if (running || hasResult) return
        strokes.clear()
        strokeCount = 0
        maskSet?.rebuild(strokes)
        render()
    }

    // MARK: 结果

    /** 当前这次 AI 结果对应的编辑步骤；还没有结果时是 null。 */
    private fun currentEdit(): AIEdit? {
        val r = result ?: return null
        // 柔化只给整张重画的结果用；局部贴回的不柔化。
        val soft = if (frame == null && !hasRegion) soften else 0f
        val recipe = if (resultFused) null else pendingRecipe?.copy(
            strength = strength, toneOnly = toneOnly, soften = soft, keepFace = keepFace, changedOnly = changedOnly,
        )
        val kept = if (keepFace) faces else emptyList()
        if (resultReframed) return AIEdit(r, emptyList(), reframed = true, soften = soft, recipe = recipe, faces = kept, mono = mono)
        val e = AIEdit(
            r, strokes, frame, ellipse, strength, toneOnly, shared = lastEdit?.takeIf { it.result === r }, soften = soft, recipe = recipe,
            faces = kept, changedOnly = canKeepRest && changedOnly, area = area, core = core, shift = shift, mono = mono,
        )
        lastEdit = e
        return e
    }

    private fun render() {
        val edit = currentEdit()
        if (edit != null) {
            val under = colorBase
            val color = colorLift
            if (color.isNotEmpty() && under != null) model.live { EditOp.applyAll(color, edit.apply(under)) }
            else model.liveOnBase { edit.apply(it) }
            return
        }
        val set = maskSet
        val mask = if (hasRegion) set?.snapshot()?.firstOrNull()?.image else null
        if (set != null && mask != null) {
            model.liveOnBase { AIRegion.overlay(it, mask, set.lock) }
        } else {
            model.liveOnBase { it }
        }
    }

    fun setToneOnlyMode(on: Boolean) {
        toneOnly = on
        render()
    }

    private fun setChangedOnlyMode(on: Boolean) {
        changedOnly = on
        render()
    }

    private fun setKeepFaceMode(on: Boolean) {
        keepFace = on
        render()
    }

    fun updateStrength(value: Float) {
        strength = value.coerceIn(0f, 1f)
        render()
    }

    fun updateSoften(value: Float) {
        soften = value.coerceIn(0f, 1f)
        render()
    }

    /** 图层融合完：结果放进结果面板，可以调强度和柔化，点 ✓ 才算数。 */
    fun showFusedResult(image: Bitmap) {
        if (closed) return
        cancelAI()
        error = null
        usageText = null
        frame = null
        ellipse = null
        resultReframed = false
        toneOnly = false
        clearExtras()
        result = image
        hasResult = true
        resultFused = true
        soften = 0f
        render()
    }

    /** 上一次结果附带的东西都不要了。 */
    private fun clearExtras() {
        faces = emptyList()
        mono = false
        canKeepRest = false
        area = null
        core = null
        resultOutfit = false
        shift = 0f to 0f
        colorLift = emptyList()
        colorBase = null
    }

    /** 不要这次的结果，回到涂抹和写指令的状态。 */
    fun discardResult() {
        result = null
        hasResult = false
        render()
    }

    fun cancelAI() {
        generation++
        job?.cancel()
        job = null
        running = false
    }

    // MARK: 发送

    /** 把当前画面和指令发给选中的服务商。 */
    fun runAI() {
        val basePrompt = prompt.trim()
        if (closed || running) return
        if (basePrompt.isEmpty()) {
            error = "先写一句要怎么改，或者点上面的快捷指令。"
            return
        }
        // 结果出来后再点同一条：算重新生成，加上这一轮的变化要求。
        regenRound = if (hasResult && basePrompt == lastPrompt) regenRound + 1 else 0
        lastPrompt = basePrompt
        // 记下怎么发起的：涂抹出来的和原图位置绑定，不能套到别的照片上。
        pendingRecipe = if (hasRegion || basePrompt.contains("涂抹区域")) null
        else AIRecipe(group.name, basePrompt, presetTitle, masterCompose, faceCrop, hairCrop, reframe.name)
        ellipse = null
        resultReframed = false
        val composeBase = model.base
        if (group == AIPresetGroup.MASTER && masterCompose && composeBase != null &&
            MasterCompose.prompt(basePrompt, presetTitle, hasPerson = true) != null
        ) {
            // 大师构图：整张交给 AI 重新取景，不看涂抹；结果和原图对不齐，按换过构图处理。
            // 先在本机看看照片里有没有人：没人的场景照用场景版指令，免得 AI 照着"人物居中"之类的描述加个人进去。
            val round = regenRound
            val title = presetTitle
            frame = null
            toneOnly = false
            error = null
            running = true
            started = System.currentTimeMillis()
            val gen = ++generation
            job = model.scope.launch {
                val hasPerson = withContext(Dispatchers.Default) { MasterCompose.hasPerson(composeBase) }
                if (closed || gen != generation) return@launch
                running = false
                val recomposed = MasterCompose.prompt(basePrompt, title, hasPerson) ?: return@launch
                val rp = if (round > 0) recomposed + AIVariation.clause(AIPresetGroup.MASTER, round, recompose = true, hasPerson = hasPerson) else recomposed
                launchAI(rp, emptyList(), null, guidance = false, identity = hasPerson, recomposed = true)
            }
            return
        }
        val p = if (regenRound > 0) basePrompt + AIVariation.clause(group, regenRound) else basePrompt
        if (group == AIPresetGroup.COMPOSE && reframe != AIReframe.ORIGINAL) {
            // 换画幅：整张交给 AI 重新构图，不看涂抹。
            frame = null
            toneOnly = false
            launchAI(p, emptyList(), null, guidance = false, reframe = reframe)
            return
        }
        if (p.contains("涂抹区域") && !hasRegion) {
            error = "先在图上涂抹要去掉的东西，再点发送。"
            return
        }
        // 换衣服（点的款式，或者自己写的要换衣服）：只发人这一块，背景、脸、头都用原图。
        val typed = presetTitle.isEmpty() && group != AIPresetGroup.OUTFIT && AIIntent.changesClothes(basePrompt)
        if (!hasRegion && (group == AIPresetGroup.OUTFIT || typed) && composeBase != null) {
            val text = if (p.contains(OutfitCatalog.KEEP)) p else p + "。" + OutfitCatalog.CLEAN + OutfitCatalog.KEEP
            // 点款式的看选的裙摆；自己写的看说没说裙摆要溢出去。
            val overflow = if (presetTitle.isEmpty()) OutfitCatalog.saysOverflow(basePrompt)
            else outfitSkirt == OutfitSkirt.OVERFLOW && outfitPick != null
            val references = if (group == AIPresetGroup.OUTFIT) listOfNotNull(outfitReference) else emptyList()
            frame = null
            toneOnly = false
            error = null
            running = true
            started = System.currentTimeMillis()
            val gen = ++generation
            job = model.scope.launch {
                val crop = if (overflow) null else withContext(Dispatchers.Default) { runCatching { OutfitMask.crop(composeBase) }.getOrNull() }
                if (closed || gen != generation) return@launch
                running = false
                launchAI(text, emptyList(), crop, guidance = false, references = references, outfit = true, overflow = overflow)
            }
            return
        }
        val base = model.base
        if (hairCrop && !hasRegion && base != null) {
            // 美发：找到脸，把头、头发连同肩膀这一块发出去；找不到脸就发整张图。
            detectFaceThen(base) { face ->
                if (face == null) {
                    frame = null
                    launchAI(p, emptyList(), null, guidance = true, identity = true)
                    return@detectFaceThen
                }
                val w = base.width.toFloat()
                val h = base.height.toFloat()
                val bw = face.box.width() * w
                val bh = face.box.height() * h
                val side = max(bw, bh) * 5.2f
                // 往下偏一些：长发、披肩发主要在脸的下面和两侧。
                val cx = face.box.centerX() * w
                val cy = face.box.centerY() * h + bh * 0.6f
                val f = clip(RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2), w, h)
                // 这一块几乎占满全图时直接发整张，省得贴回去多一道接缝。
                if (f == null || f.width() * f.height() > w * h * 0.8f) {
                    frame = null
                    launchAI(p, emptyList(), null, guidance = true, identity = true)
                    return@detectFaceThen
                }
                frame = RectF(f.left / w, f.top / h, f.right / w, f.bottom / h)
                // 贴回的范围比发出去的小一圈：羽化要完全落在发出去的这一块里面。
                val dx = f.width() * 0.11f
                val dy = f.height() * 0.11f
                ellipse = RectF((f.left + dx) / w, (f.top + dy) / h, (f.right - dx) / w, (f.bottom - dy) / h)
                launchAI(p, emptyList(), frame, guidance = false, identity = true)
            }
            return
        }
        if (faceCrop && !hasRegion && base != null) {
            // 先在本机找脸，只把头部这一块发出去；找不到脸再退回整张图。
            detectFaceThen(base) { face ->
                if (face == null) {
                    frame = null
                    launchAI(p, emptyList(), null, guidance = false, identity = true)
                    return@detectFaceThen
                }
                val w = base.width.toFloat()
                val h = base.height.toFloat()
                val bw = face.box.width() * w
                val bh = face.box.height() * h
                val cx = face.box.centerX() * w
                val cy = face.box.centerY() * h - bh * 0.1f
                frame = faceFrame(face, 2.6f, w, h)
                // 贴回的范围包住整个头和头发，边缘羽化。
                ellipse = RectF((cx - bw * 0.95f) / w, (cy - bh * 1.1f) / h, (cx + bw * 0.95f) / w, (cy + bh * 1.1f) / h)
                launchAI(p, emptyList(), frame, guidance = false, identity = true)
            }
            return
        }
        val crop = if (hasRegion) regionCrop() else null
        if (crop == null) {
            frame = null
            launchAI(p, emptyList(), null, guidance = true, identity = faceCrop)
            return
        }
        // 涂了区域：只把这一块（带一圈周围环境）裁出来发给 AI，结果也只贴回涂抹的范围。
        frame = crop
        if (AIIntent.replacesContent(p)) {
            // 去掉/替换：涂抹范围当蒙版，让 AI 把里面的东西重画。
            launchAI(p, remap(strokes, crop), crop, guidance = true)
        } else {
            // 在原内容上修改：不发蒙版，AI 看得到原图。
            val hint = "\n\nThis is a cropped part of a larger photo. Apply the instruction to what is shown here and keep the same framing, position and scale so it can be placed back."
            launchAI(p + hint, emptyList(), crop, guidance = true, identity = faceCrop)
        }
    }

    /** 换了服务商之后，把刚才那次请求原样重发。 */
    fun retryAI() = runAI()

    /** 套用别的图的处理步骤：按记下的指令和设置在这张照片上重新生成。 */
    fun replay(r: AIRecipe) {
        AIPresetGroup.entries.firstOrNull { it.name == r.group }?.let { group = it }
        error = null
        prompt = r.prompt
        presetTitle = r.presetTitle
        masterCompose = r.masterCompose
        faceCrop = r.faceCrop
        hairCrop = r.hairCrop
        reframe = AIReframe.entries.firstOrNull { it.name == r.reframe } ?: AIReframe.ORIGINAL
        toneOnly = r.toneOnly
        runAI()
    }

    /** 重新生成的结果出来后，按原来的强度、柔化和"只取光影色彩"来定。 */
    fun applyReplayed(r: AIRecipe) {
        if (!hasResult) return
        strength = r.strength.coerceIn(0f, 1f)
        soften = r.soften.coerceIn(0f, 1f)
        toneOnly = r.toneOnly
        r.keepFace?.let { keepFace = it }
        r.changedOnly?.let { changedOnly = it }
        render()
    }

    private fun detectFaceThen(base: Bitmap, then: (FaceInfo?) -> Unit) {
        error = null
        running = true
        started = System.currentTimeMillis()
        val gen = ++generation
        job = model.scope.launch {
            val found = withContext(Dispatchers.Default) { runCatching { FaceDetector.detect(base) }.getOrDefault(emptyList()) }
            if (closed || gen != generation) return@launch
            running = false
            then(found.firstOrNull())
        }
    }

    private fun clip(r: RectF, w: Float, h: Float): RectF? {
        val out = RectF(r)
        return if (out.intersect(0f, 0f, w, h)) out else null
    }

    /** 以脸为中心、边长为脸的 factor 倍的方框（按像素是正方形），限制在图片范围内。 */
    private fun faceFrame(face: FaceInfo, factor: Float, w: Float, h: Float): RectF {
        val bw = face.box.width() * w
        val bh = face.box.height() * h
        val side = max(bw, bh) * factor
        val cx = face.box.centerX() * w
        // 人脸框不含额头上半部分，往上挪一点把头顶也框进来。
        val cy = face.box.centerY() * h - bh * 0.1f
        val r = clip(RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2), w, h) ?: RectF(0f, 0f, w, h)
        return RectF(r.left / w, r.top / h, r.right / w, r.bottom / h)
    }

    /** 涂抹范围的外接框，四周留出余量，限制在图片内（归一化坐标）。 */
    private fun regionCrop(): RectF? {
        val b = model.base ?: return null
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val long = max(w, h)
        var box: RectF? = null
        for (s in strokes) {
            if (s.erase) continue
            val half = s.width * long / 2
            for (p in s.points) {
                val r = RectF(p.x * w - half, p.y * h - half, p.x * w + half, p.y * h + half)
                val cur = box
                if (cur == null) box = r else cur.union(r)
            }
        }
        val bx = box ?: return null
        val margin = max(max(bx.width(), bx.height()) * 0.35f, long * 0.06f)
        bx.inset(-margin, -margin)
        // 太细长的框补成不超过 2.5:1，接口对比例有限制。
        if (bx.width() > bx.height() * 2.5f) bx.inset(0f, -(bx.width() / 2.5f - bx.height()) / 2)
        if (bx.height() > bx.width() * 2.5f) bx.inset(-(bx.height() / 2.5f - bx.width()) / 2, 0f)
        val c = clip(bx, w, h) ?: return null
        if (c.width() < 8 || c.height() < 8) return null
        return RectF(c.left / w, c.top / h, c.right / w, c.bottom / h)
    }

    /** 把整图坐标的笔画换算到裁剪框内的坐标。 */
    private fun remap(list: List<MosaicStroke>, crop: RectF): List<MosaicStroke> {
        val b = model.base ?: return list
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val k = max(w, h) / max(crop.width() * w, crop.height() * h)
        return list.map { s ->
            MosaicStroke(
                s.points.map { PointF((it.x - crop.left) / crop.width(), (it.y - crop.top) / crop.height()) }.toMutableList(),
                s.width * k, s.erase, s.style, s.strength,
            )
        }
    }

    /** identity = true：必须还是同一个人的任务。画质设成"自动"时改用高画质，并要求尽量忠实于原图。 */
    private fun launchAI(
        prompt: String, strokes: List<MosaicStroke>, crop: RectF?, guidance: Boolean,
        identity: Boolean = false, reframe: AIReframe = AIReframe.ORIGINAL, recomposed: Boolean = false,
        references: List<Bitmap> = emptyList(), outfit: Boolean = false, overflow: Boolean = false,
    ) {
        if (closed) return
        val proxy = model.proxy ?: return
        var endpoint = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        if (identity) {
            endpoint = endpoint.copy(highFidelity = true, quality = if (endpoint.quality == "auto") "high" else endpoint.quality)
        }
        // 只取光影和颜色时，AI 图的清晰度用不上，按标准尺寸要就够了，省钱。
        if (toneOnly) endpoint = endpoint.copy(hires = false)
        // 文字、贴纸、形状这些装饰不发给 AI，只发照片本身。
        var ops = model.photoOps
        clearExtras()
        // 大师、相机、创意本来就是换色调；其余的不能把用户加的滤镜冲掉。
        if (group != AIPresetGroup.MASTER && group != AIPresetGroup.CAMERA && group != AIPresetGroup.CREATIVE) {
            val (base, color) = EditOp.splitColor(ops)
            ops = base
            colorLift = color
        }
        val sentOps = ops
        val lifted = colorLift.isNotEmpty()
        // 整张重画、还是同一个人的这几组：出来以后把原图的脸贴回去。
        val whole = crop == null && strokes.isEmpty()
        var before = if (outfit || whole && group in FACE_GROUPS) model.base else null
        // 只动一部分的这两组：没动的地方用原图。
        var rest = if (outfit || whole && !recomposed && reframe == AIReframe.ORIGINAL &&
            (group == AIPresetGroup.BODY || group == AIPresetGroup.REMOVE)
        ) model.base else null
        val bodyOnly = group == AIPresetGroup.BODY
        val bodyPart = part
        val sent = strokes.map { it.copy() }
        error = null
        result = null
        hasResult = false
        resultFused = false
        usageText = null
        AIClient.takeLastUsage()
        running = true
        started = System.currentTimeMillis()
        render()
        val gen = ++generation
        job = model.scope.launch {
            try {
                var under: Bitmap? = null
                if (recomposed) {
                    // 重新取景的结果里脸可能很小：对脸用大一点的图。
                    before = withContext(Dispatchers.Default) { Img.downscale(EditOp.applyAll(sentOps, proxy), 2560) }
                }
                if (outfit) {
                    // 脸在画面里可能很小：比较和找脸用大一点的图。
                    val big = withContext(Dispatchers.Default) { Img.downscale(EditOp.applyAll(sentOps, proxy), 3072) }
                    before = big
                    rest = big
                }
                if (lifted) {
                    // 比较和贴脸都用没盖滤镜的底图。
                    under = withContext(Dispatchers.Default) { Img.downscale(EditOp.applyAll(sentOps, proxy), EditorModel.PREVIEW_SIDE) }
                    if (before != null && !outfit) before = under
                    if (rest != null && !outfit) rest = under
                }
                val piece = AIRunner.run(endpoint, prompt, proxy, sentOps, sent, crop, guidance, reframe, references)
                // 换衣服只发了人这一块：拼回整张，后面就和发整张的一样处理。
                val image = if (outfit && crop != null) {
                    withContext(Dispatchers.Default) { OutfitMask.paste(piece, crop, EditOp.applyAll(sentOps, proxy)) }
                } else piece
                // 用量 AIClient 已经记过了，这里只取来显示
                val usage = AIClient.takeLastUsage()
                val found = withContext(Dispatchers.Default) { examine(image, before, rest, bodyOnly, bodyPart, outfit, overflow) }
                if (closed || gen != generation) return@launch
                colorBase = under
                faces = found.faces
                // 大师保持最早的样子：默认用 AI 的脸，想要原图的脸再切过去。
                keepFace = group != AIPresetGroup.MASTER
                mono = found.mono
                shift = found.shift
                area = found.area
                core = found.core
                resultOutfit = outfit
                if (outfit) frame = null
                canKeepRest = rest != null
                usageText = usage?.summary
                result = image
                resultReframed = reframe != AIReframe.ORIGINAL || recomposed
                hasResult = true
                running = false
                render()
                model.saveDraft()
            } catch (e: CancellationException) {
                if (gen == generation) running = false
                throw e
            } catch (e: Throwable) {
                if (closed || gen != generation) return@launch
                running = false
                error = (e as? AIError)?.text ?: e.message ?: "请求失败。"
            }
        }
    }

    private class Examined(val faces: List<FaceKeep>, val mono: Boolean, val shift: Pair<Float, Float>, val area: Bitmap?, val core: Bitmap?)

    /** 结果出来以后在本机看一遍：整体偏了多少、人在哪、脸对不对得上、是不是黑白的。 */
    private fun examine(
        image: Bitmap, before: Bitmap?, rest: Bitmap?, bodyOnly: Boolean, bodyPart: BodyPart?, outfit: Boolean, overflow: Boolean,
    ): Examined {
        val shift = rest?.let { runCatching { ChangeKeep.shift(it, image) }.getOrNull() } ?: (0f to 0f)
        var area: Mask8? = null
        if (bodyOnly && rest != null) {
            area = ChangeKeep.personArea(
                PersonSegmenter.maskData(Img.downscale(rest, 1024)), PersonSegmenter.maskData(Img.downscale(image, 1024)), rest.width, rest.height,
            )
            val limit = runCatching { bodyPart?.area(rest) }.getOrNull()
            if (limit != null) area = ChangeKeep.intersect(area, limit)
        }
        // 五官是在没对齐的 AI 图上量的，跟着整体平移一起挪。
        var faces = before?.let { runCatching { FaceKeep.match(it, image) }.getOrNull() }.orEmpty()
            .map { it.moved(shift.first, shift.second, image.width, image.height) }
        var core: Mask8? = null
        if (outfit && rest != null) {
            // 头基本没挪（位置差不到脸宽的 12%、大小差不到 4%）就整个头用原图；挪了就按五官对齐贴脸。
            val still = faces.isNotEmpty() && faces.all { it.isStill }
            val masks = OutfitMask.masks(rest, image, overflow, keepHead = still)
            area = masks.area
            core = masks.core
            if (still) faces = emptyList()
        }
        return Examined(faces, MonoCheck.isMono(image), shift, area?.toGrayBitmap(), core?.toGrayBitmap())
    }

    /** 美体里换到"手动美体"：已经做出来的修改先保留成一步，再换过去。 */
    private fun switchToManualBody() {
        if (running || model.isBusy) return
        model.commitTool { model.begin(Tool.LIQUIFY) }
    }

    // MARK: 界面

    @Composable
    override fun Title() {
        val t = when {
            group == AIPresetGroup.BODY -> "美体"
            group.isHair -> "美发"
            else -> tool.title
        }
        Text(t, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }

    private fun openSettings() {
        model.showSettings = true
    }

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Header()
            // 出错放在最上面：下面的格子多，放底下会被挤到看不见。
            AIFailureView(if (running) null else error) { retryAI() }
            when {
                !AISettings.isConfigured(AISettings.active) -> NeedsKeyView(openSettings = ::openSettings)
                running -> Running()
                hasResult -> ResultControls()
                else -> ComposeControls()
            }
        }
    }

    @Composable
    private fun Header() {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            when {
                group == AIPresetGroup.BODY -> {
                    // 美体的两种做法
                    Row(Modifier.alpha(if (running) 0.4f else 1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Chip("AI 美体", selected = true, symbol = "sparkles") {}
                        if (ToolRegistry.available(Tool.LIQUIFY)) {
                            Chip("手动美体", selected = false, symbol = "hand.draw") { switchToManualBody() }
                        }
                    }
                    Spacer(Modifier.weight(1f))
                    ProviderMenu(::openSettings, compact = true)
                }
                group.isHair -> {
                    Box(Modifier.weight(1f)) {
                        SegmentBar(AIPresetGroup.hairGroups, group, { it.title }, { it.symbol }) { group = it }
                    }
                    ProviderMenu(::openSettings, compact = true)
                }
                else -> {
                    Box(Modifier.weight(1f)) {
                        SegmentBar(AIPresetGroup.editGroups, group, { it.title }, { it.symbol }, scrolls = true) { group = it }
                    }
                    ProviderMenu(::openSettings, iconOnly = true)
                }
            }
        }
    }

    /** 点一个功能就直接开始。需要补充内容的（比如"换背景"）先弹出输入框，写完自动开始。 */
    @Composable
    private fun ComposeControls() {
        when {
            group != AIPresetGroup.OUTFIT -> Tiles()
            outfitPatch -> PatchControls()
            else -> OutfitPanel(this, ::custom)
        }
    }

    @Composable
    private fun Tiles() {
        val master = group.usesTonePreview
        val pictures = master || group == AIPresetGroup.HAIR_STYLE
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (group == AIPresetGroup.CREATIVE) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (kind in CreativeKind.entries) {
                        Chip(kind.title, selected = creativeKind == kind, symbol = kind.symbol) { creativeKind = kind }
                    }
                }
            }
            if (group == AIPresetGroup.BODY || group.isHair) {
                GenderToggle()
            }
            if (group == AIPresetGroup.MASTER) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("大师构图", selected = masterCompose, symbol = "viewfinder") { masterCompose = true }
                    Chip("原构图", selected = !masterCompose, symbol = "rectangle") { masterCompose = false }
                }
            }
            if (group == AIPresetGroup.COMPOSE) {
                // 构图可以换画幅
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    for (item in AIReframe.entries) {
                        Chip(item.title, selected = reframe == item, symbol = item.symbol) { reframe = item }
                    }
                }
            }
            key(group, if (group == AIPresetGroup.CREATIVE) creativeKind else null, GenderSetting.isMale) {
                Row(
                    Modifier.bleed(16.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(top = 6.dp, bottom = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(if (pictures) 10.dp else 4.dp),
                    verticalAlignment = Alignment.Top,
                ) {
                    val list = if (group == AIPresetGroup.CREATIVE) creativeKind.presets else group.presets
                    if (group == AIPresetGroup.COMPOSE) {
                        FeatureTile(Tool.SMART_CROP.symbol, Tool.SMART_CROP.title, badge = "AI") {
                            if (!model.isBusy) model.commitTool { model.begin(Tool.SMART_CROP) }
                        }
                    }
                    for (preset in list) {
                        val tint = preset.tint
                        when {
                            group == AIPresetGroup.CREATIVE && toneThumbs[preset.title] == null ->
                                CreativeArtTile(preset.title, preset.symbol, creativeKind) { start(preset) }
                            master -> ImageTile(preset.title, toneThumbs[preset.title] ?: photoThumb, symbol = group.symbol, badge = "AI") { start(preset) }
                            tint != null -> ColorTile(tint, preset.title) { start(preset) }
                            group == AIPresetGroup.HAIR_STYLE ->
                                ImageTile(preset.title, HairArt.image(preset.title), symbol = preset.symbol, badge = "AI") { start(preset) }
                            else -> FeatureTile(preset.symbol, preset.title, badge = "AI") { start(preset) }
                        }
                    }
                    if (pictures) {
                        ImageTile("自己写", null, symbol = "square.and.pencil", badge = "AI") { custom() }
                    } else {
                        FeatureTile("square.and.pencil", "自己写", badge = "AI") { custom() }
                    }
                }
            }
            BrushRow()
        }
    }

    /** 换衣服没换干净：涂抹，再点"补换"。 */
    @Composable
    private fun PatchControls() {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            BrushRow()
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                BackPill("返回") { outfitPatch = false }
                AIMainButton("补换涂抹的地方", Modifier.weight(1f).alpha(if (strokeCount > 0) 1f else 0.4f)) { runOutfitPatch() }
            }
        }
    }

    @Composable
    private fun BrushRow() {
        val any = strokeCount > 0
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Text("涂抹", fontSize = 13.sp, color = Theme.dim)
            XSlider(brush, { brush = it }, 14f..100f, Modifier.weight(1f))
            SmallButton("eraser", active = erasing) { erasing = !erasing }
            SmallButton("arrow.uturn.backward", active = false, Modifier.alpha(if (any) 1f else 0.35f)) { undoStroke() }
            SmallButton("trash", active = false, Modifier.alpha(if (any) 1f else 0.35f)) { clearRegion() }
        }
    }

    private fun start(preset: AIPreset) {
        error = null
        prompt = preset.prompt
        presetTitle = preset.title
        faceCrop = preset.faceCrop
        hairCrop = preset.hairCrop
        toneOnly = preset.toneOnly
        part = preset.part
        if (preset.prompt.endsWith("：")) editPrompt() else runAI()
    }

    private fun custom() {
        error = null
        prompt = ""
        presetTitle = ""
        faceCrop = false
        hairCrop = group.isHair
        toneOnly = false
        part = null
        editPrompt()
    }

    /** 写指令：写完直接开始；什么都没写，或者只留着"换成："这样的半句话，就不发。 */
    private fun editPrompt() {
        model.requestText(prompt, "写下要怎么改，比如：把背景换成海边") { text ->
            prompt = text.trim()
            if (prompt.isNotEmpty() && !prompt.endsWith("：")) runAI()
        }
    }

    @Composable
    private fun Running() {
        val begin = started
        val seconds by produceState(0, begin) {
            while (true) {
                value = max(0, ((System.currentTimeMillis() - begin) / 1000).toInt())
                delay(1000)
            }
        }
        Row(Modifier.padding(vertical = 22.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Text("${AISettings.active.shortTitle} 正在处理… $seconds 秒", fontSize = 14.sp, color = Color.White)
            Spacer(Modifier.weight(1f))
            Text("取消", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Theme.accent, modifier = Modifier.tap { cancelAI() })
        }
    }

    @Composable
    private fun ResultControls() {
        Column(Modifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            usageText?.let {
                Text(it, fontSize = 11.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth())
            }
            // 改形状的（美体、美发）没有"只取光影"这回事。
            if (!group.isHair && group != AIPresetGroup.BODY && group != AIPresetGroup.CREATIVE && !canKeepRest && !resultReframed && !resultFused) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("只取光影色彩", toneOnly) { setToneOnlyMode(true) }
                    Chip("完整采用 AI 图", !toneOnly) { setToneOnlyMode(false) }
                }
            }
            if (canKeepRest && !toneOnly) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip(if (resultOutfit) "只换衣服" else "只换变了的地方", changedOnly) { setChangedOnlyMode(true) }
                    Chip("完整采用 AI 图", !changedOnly) { setChangedOnlyMode(false) }
                }
            }
            if (faces.isNotEmpty() && (resultReframed || !toneOnly)) {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("用原图的脸", keepFace) { setKeepFaceMode(true) }
                    Chip("用 AI 的脸", !keepFace) { setKeepFaceMode(false) }
                }
            }
            if (!resultReframed) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("强度", fontSize = 13.sp, color = Theme.dim)
                    XSlider(strength, { updateStrength(it) }, 0f..1f, Modifier.weight(1f))
                    Text(
                        "${(strength * 100).roundToInt()}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                        textAlign = TextAlign.End, modifier = Modifier.width(34.dp),
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("柔化", fontSize = 13.sp, color = Theme.dim)
                XSlider(soften, { updateSoften(it) }, 0f..1f, Modifier.weight(1f))
                Text(
                    "${(soften * 100).roundToInt()}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    textAlign = TextAlign.End, modifier = Modifier.width(34.dp),
                )
            }
            if (resultOutfit || (group == AIPresetGroup.OUTFIT && outfitPatch)) {
                WideButton("有地方没换干净，涂抹补换", "paintbrush", null, Modifier.fillMaxWidth()) { startOutfitPatch() }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!resultFused) WideButton("再生成一次", "arrow.clockwise", "AI", Modifier.weight(1f)) { runAI() }
                WideButton("不要了，换一个", "arrow.uturn.backward", null, Modifier.weight(1f)) { discardResult() }
            }
        }
    }
}

/** 整张重画、还是同一个人的这几组。 */
private val FACE_GROUPS = setOf(AIPresetGroup.MASTER, AIPresetGroup.CAMERA, AIPresetGroup.COMPOSE, AIPresetGroup.LIGHT, AIPresetGroup.BODY)

/** 面板内容左右各伸出 h，横向滚动的一排能滑到屏幕边。 */
internal fun Modifier.bleed(h: Dp): Modifier = layout { measurable, constraints ->
    val px = h.roundToPx()
    val wide = constraints.copy(
        minWidth = constraints.minWidth + px * 2,
        maxWidth = constraints.maxWidth + px * 2,
    )
    val p = measurable.measure(wide)
    layout(constraints.maxWidth, p.height) { p.place(-px, 0) }
}

/** 涂抹那一行的小圆按钮。 */
@Composable
private fun SmallButton(symbol: String, active: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.size(36.dp).clip(CircleShape).background(if (active) Theme.accent else Theme.chip).tap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(sym(symbol), null, tint = if (active) Color.Black else Color.White, modifier = Modifier.size(17.dp)) }
}

/** 结果下面的两个胶囊按钮。 */
@Composable
private fun WideButton(title: String, symbol: String, badge: String?, modifier: Modifier, onClick: () -> Unit) {
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 40.dp).clip(CircleShape).background(Theme.chip).press(onClick = onClick),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(6.dp))
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1)
        }
        if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = (-4).dp, y = (-4).dp))
    }
}

/** 色块按钮：一个圆角色块，名字在下面（染发的颜色用）。 */
@Composable
fun ColorTile(hex: Int, title: String, onClick: () -> Unit) {
    fun color(k: Float): Color {
        val r = ((hex shr 16) and 0xFF) / 255f
        val g = ((hex shr 8) and 0xFF) / 255f
        val b = (hex and 0xFF) / 255f
        return Color(min(r * k, 1f), min(g * k, 1f), min(b * k, 1f))
    }
    Column(Modifier.width(64.dp).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(16.dp))
                    .background(Brush.linearGradient(listOf(color(1.18f), color(0.82f))))
                    .border(1.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(16.dp)),
            )
            CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = 5.dp, y = (-4).dp))
        }
        Text(title, fontSize = 11.5.sp, color = Color.White, maxLines = 1)
    }
}

/** 创意玩法里本机模拟不了的那些（加分身、加东西、换场景）：色块渐变 + 图标。 */
@Composable
private fun CreativeArtTile(title: String, symbol: String, kind: CreativeKind, onClick: () -> Unit) {
    val colors = when (kind) {
        CreativeKind.COMIC -> listOf(Color(0.98f, 0.55f, 0.62f), Color(0.5f, 0.36f, 0.85f))
        CreativeKind.CARTOON -> listOf(Color(1f, 0.78f, 0.35f), Color(0.98f, 0.45f, 0.5f))
        CreativeKind.ART -> listOf(Color(0.45f, 0.7f, 0.85f), Color(0.25f, 0.3f, 0.55f))
        CreativeKind.TWIN -> listOf(Color(0.55f, 0.85f, 0.8f), Color(0.3f, 0.45f, 0.8f))
        CreativeKind.FUN -> listOf(Color(1f, 0.6f, 0.3f), Color(0.85f, 0.25f, 0.45f))
        CreativeKind.MOOD -> listOf(Color(0.95f, 0.7f, 0.45f), Color(0.35f, 0.25f, 0.5f))
    }
    Column(Modifier.width(68.dp).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(68.dp, 84.dp).clip(RoundedCornerShape(10.dp)).background(Brush.linearGradient(colors)), contentAlignment = Alignment.Center) {
            Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(28.dp))
            CornerBadge("AI", Modifier.align(Alignment.TopEnd).padding(4.dp))
        }
        Text(title, fontSize = 12.sp, color = Color.White, maxLines = 1)
    }
}
