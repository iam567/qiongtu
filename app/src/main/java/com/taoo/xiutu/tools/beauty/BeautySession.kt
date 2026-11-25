package com.taoo.xiutu.tools.beauty

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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIEdit
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIFailureView
import com.taoo.xiutu.ai.AIRunner
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.NeedsKeyView
import com.taoo.xiutu.ai.ProviderMenu
import com.taoo.xiutu.ai.current
import com.taoo.xiutu.ai.named
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.FaceRescue
import com.taoo.xiutu.editor.FaceSeeker
import com.taoo.xiutu.editor.ModeSelectable
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.GenderToggle
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 美颜：AI 美颜（只把脸部发给服务商）和手动美颜（全部在本机）。
 * 多张脸时每张脸各自保存 AI 结果和手动参数，确认时每张脸的 AI 美颜和手动美颜各算一步。
 */
class BeautySession(model: EditorModel) : ToolSession(model, Tool.BEAUTY), ModeSelectable, FaceSeeker {
    enum class Mode { AI, MANUAL }

    var mode by mutableStateOf(Mode.AI)
    var beauty by mutableStateOf(BeautyParams())
        private set
    var beautyKey by mutableStateOf(BeautyKey.SMOOTH)
    var beautyPreset by mutableStateOf<String?>(null)
        private set
    var beautyStyle by mutableStateOf<String?>(null)
        private set
    var faces by mutableStateOf<List<FaceInfo>>(emptyList())
        private set
    var faceIndex by mutableIntStateOf(0)
        private set
    var detectingFaces by mutableStateOf(false)
        private set

    /** 画布要放大到的区域（归一化坐标）。 */
    private var focus by mutableStateOf<RectF?>(null)
    override val focusRect: RectF? get() = focus

    // AI 美颜
    var running by mutableStateOf(false)
        private set
    private var started by mutableLongStateOf(0L)
    var error by mutableStateOf<String?>(null)
        private set
    var hasResult by mutableStateOf(false)
        private set
    var strength by mutableFloatStateOf(1f)
        private set
    private var usageText by mutableStateOf<String?>(null)
    private var result: Bitmap? = null
    private var frame: RectF? = null
    private var ellipse: RectF? = null
    private var job: Job? = null
    /** 每发一次请求（或取消）加一：旧请求晚回来的结果直接丢掉。 */
    private var generation = 0
    private var closed = false

    /** 这次进美颜后已经生成过的结果，按"第几张脸 + 风格"记住，再点同一个风格直接切换，不重新调用接口。 */
    private class CachedFace(val image: Bitmap, val frame: RectF, val ellipse: RectF)
    private val faceCache = HashMap<String, CachedFace>()
    private var pendingFaceKey: String? = null
    var cachedFaceKeys by mutableStateOf<Set<String>>(emptySet())
        private set

    /** 每张脸各自的修改：切到别的脸时先存起来，切回来再取出，互不影响。 */
    private class FaceState(
        val edit: AIEdit? = null,
        val style: String? = null,
        val beauty: BeautyParams = BeautyParams(),
        val preset: String? = null,
    )
    private val faceStates = HashMap<Int, FaceState>()
    private var editedFaces by mutableStateOf<Set<Int>>(emptySet())

    override val busy: Boolean get() = running
    override val wantsTap: Boolean get() = true

    /** 一进美颜就按满意脸型修（菜单"满意脸型"入口用）：等找完脸再开始。 */
    private var runFavoriteAfterDetect = false

    override fun selectMode(mode: String) {
        this.mode = if (mode == "manual") Mode.MANUAL else Mode.AI
        if (mode == "favorite") {
            if (detectingFaces) runFavoriteAfterDetect = true
            else if (faces.isNotEmpty()) runFavoriteFace()
        }
    }

    override fun start() {
        detectFaces()
    }

    override fun close() {
        closed = true
        job?.cancel()
        job = null
    }

    override fun commitOps(): List<EditOp> = if (running) emptyList() else faceOps()

    override val lacksFace: Boolean get() = faces.isEmpty() && !detectingFaces

    override fun redetectFaces() = detectFaces()

    override fun onTap(p: PointF) {
        if (!model.faceSearch.tap(p)) tapFace(p)
    }

    // MARK: 找脸

    private fun detectFaces() {
        if (model.base == null) return
        detectingFaces = true
        model.scope.launch {
            val found = model.faceSearch.find()
            if (closed) return@launch
            faces = found
            faceStates.clear()
            beauty = beauty.copy(faces = found.firstOrNull()?.let { listOf(it) } ?: emptyList())
            faceIndex = 0
            detectingFaces = false
            updateFocus()
            if (runFavoriteAfterDetect) {
                runFavoriteAfterDetect = false
                if (found.isNotEmpty()) runFavoriteFace()
            }
        }
    }

    /** 以脸为中心、边长为脸的 factor 倍的方框（按像素是正方形），限制在图片范围内。 */
    private fun faceFrame(face: FaceInfo, factor: Float): RectF {
        val b = model.base
        val w = (b?.width ?: 1).toFloat()
        val h = (b?.height ?: 1).toFloat()
        val bw = face.box.width() * w
        val bh = face.box.height() * h
        val side = max(bw, bh) * factor
        val cx = face.box.centerX() * w
        // 人脸框不含额头上半部分，往上挪一点把头顶也框进来。
        val cy = face.box.centerY() * h - bh * 0.1f
        val r = RectF(cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)
        if (!r.intersect(0f, 0f, w, h)) r.set(0f, 0f, w, h)
        return RectF(r.left / w, r.top / h, r.right / w, r.bottom / h)
    }

    private fun updateFocus() {
        if (faceIndex !in faces.indices) {
            focus = null
            return
        }
        val target = faceFrame(faces[faceIndex], 1.9f)
        if (focus == target) {
            // 用户自己缩放过之后再点同一张脸：先放回整张再放大，画布才会重新对准。
            model.scope.launch {
                focus = null
                delay(40)
                if (!closed) focus = target
            }
        } else {
            focus = target
        }
    }

    // MARK: 每张脸

    fun faceEdited(index: Int): Boolean =
        if (index == faceIndex) hasResult || !beauty.isIdentity else index in editedFaces

    fun selectFace(index: Int) {
        if (index !in faces.indices || running) return
        if (index == faceIndex) return updateFocus()
        // 存下当前这张脸的状态
        val edit = currentAIEdit()
        faceStates[faceIndex] = FaceState(edit, beautyStyle, beauty, beautyPreset)
        editedFaces = if (edit != null || !beauty.isIdentity) editedFaces + faceIndex else editedFaces - faceIndex
        // 取出要切过去的那张脸的状态
        faceIndex = index
        val state = faceStates[index] ?: FaceState()
        result = state.edit?.result
        hasResult = result != null
        frame = state.edit?.frame
        ellipse = state.edit?.ellipse
        strength = state.edit?.strength ?: 1f
        beautyStyle = state.style
        beauty = state.beauty.copy(faces = listOf(faces[index]))
        beautyPreset = state.preset
        usageText = null
        error = null
        updateFocus()
        renderAI()
    }

    /** 点画面：点到哪张脸就切到哪张。 */
    private fun tapFace(point: PointF) {
        if (running || faces.size <= 1) return
        var best: Int? = null
        var bestDistance = Float.MAX_VALUE
        for ((i, face) in faces.withIndex()) {
            val b = face.box
            val area = RectF(b.left - b.width() * 0.35f, b.top - b.height() * 0.45f, b.right + b.width() * 0.35f, b.bottom + b.height() * 0.45f)
            if (!area.contains(point.x, point.y)) continue
            val d = hypot(point.x - b.centerX(), point.y - b.centerY())
            if (d < bestDistance) { best = i; bestDistance = d }
        }
        best?.let { selectFace(it) }
    }

    /** 当前这次 AI 结果对应的编辑步骤；还没有结果时是 null。 */
    private fun currentAIEdit(): AIEdit? {
        val r = result ?: return null
        return AIEdit(r, emptyList(), frame, ellipse, strength)
    }

    /** 所有脸当前的修改：先是各张脸的 AI 结果，再是各张脸的手动美颜。 */
    private fun faceLayers(): Pair<List<AIEdit>, List<BeautyParams>> {
        val edits = ArrayList<AIEdit>()
        val beauties = ArrayList<BeautyParams>()
        for (i in faces.indices) {
            val edit = if (i == faceIndex) currentAIEdit() else faceStates[i]?.edit
            val params = if (i == faceIndex) beauty else faceStates[i]?.beauty ?: BeautyParams()
            if (edit != null) edits += edit
            if (!params.isIdentity) beauties += params
        }
        return edits to beauties
    }

    private fun faceOps(): List<EditOp> {
        val (edits, beauties) = faceLayers()
        return edits + beauties
    }

    private fun renderAI() {
        val (edits, beauties) = faceLayers()
        model.liveOnBase { b ->
            var out = b
            for (e in edits) out = e.apply(out)
            for (p in beauties) out = p.apply(out)
            out
        }
    }

    // MARK: 手动美颜

    fun setBeauty(key: BeautyKey, value: Float) {
        beauty = beauty.with(key, if (value < 0.02f) 0f else value)
        beautyPreset = null
        renderAI()
    }

    fun applyBeautyPreset(preset: BeautyPreset?) {
        beauty = beauty.with(preset)
        beautyPreset = preset?.id
        renderAI()
    }

    fun setLipColor(index: Int) {
        var b = beauty.copy(lipColor = index)
        if (b[BeautyKey.LIPS] == 0f) b = b.with(BeautyKey.LIPS, 0.5f)
        beauty = b
        beautyPreset = null
        renderAI()
    }

    // MARK: AI 美颜

    private fun faceKey(style: BeautyStyle) = "$faceIndex|${style.prompt}"  // 男女两套有同名的风格，按指令区分

    fun isFaceStyleCached(style: BeautyStyle) = faceKey(style) in cachedFaceKeys

    fun setAIStrength(value: Float) {
        strength = value.coerceIn(0f, 1f)
        renderAI()
    }

    /**
     * AI 美颜：只把选中的那张脸裁出来发给服务商，结果只贴回脸部的椭圆范围。
     * 这张脸的这个风格之前生成过的话直接用记住的结果；force = true 时强制重新生成。
     */
    /** 按满意脸型修当前这张脸。 */
    fun runFavoriteFace(force: Boolean = false) {
        val face = FavoriteFaceStore.current
        val reference = face?.let { FavoriteFaceStore.image(it) }
        if (reference == null) {
            error = "还没有满意脸型"
            return
        }
        runFaceAI(BeautyStyle.favorite, force, listOf(reference))
    }

    fun runFaceAI(style: BeautyStyle, force: Boolean = false, references: List<Bitmap> = emptyList()) {
        if (closed || running || faceIndex !in faces.indices) return
        val key = faceKey(style)
        val cached = faceCache[key]
        if (!force && cached != null) {
            error = null
            usageText = null
            beautyStyle = style.id
            frame = cached.frame
            ellipse = cached.ellipse
            result = cached.image
            hasResult = true
            renderAI()
            return
        }
        val b = model.base ?: return
        val face = faces[faceIndex]
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        val crop = faceFrame(face, 2.0f)
        val bw = face.box.width() * w
        val bh = face.box.height() * h
        val cx = face.box.centerX() * w
        val cy = face.box.centerY() * h - bh * 0.1f
        val ell = RectF((cx - bw * 0.66f) / w, (cy - bh * 0.82f) / h, (cx + bw * 0.66f) / w, (cy + bh * 0.82f) / h)
        beautyStyle = style.id
        frame = crop
        ellipse = ell
        pendingFaceKey = key
        launchAI(BeautyStyle.preamble + " " + style.prompt, crop, references)
    }

    /** 对当前显示的这个风格重新生成一次（会再调用一次接口）。 */
    fun regenerateFaceAI() {
        if (beautyStyle == BeautyStyle.favorite.id) return runFavoriteFace(force = true)
        val style = BeautyStyle.named(beautyStyle) ?: return
        runFaceAI(style, force = true)
    }

    /** 换了服务商之后，把刚才那次请求原样重发。 */
    fun retryAI() = regenerateFaceAI()

    fun discardFaceAI() {
        result = null
        hasResult = false
        beautyStyle = null
        renderAI()
    }

    fun cancelAI() {
        generation++
        job?.cancel()
        job = null
        running = false
    }

    /** 必须还是同一个人：画质设成"自动"时改用高画质，并要求尽量忠实于原图。 */
    private fun launchAI(prompt: String, crop: RectF, references: List<Bitmap> = emptyList()) {
        if (closed) return
        val proxy = model.proxy ?: return
        var endpoint = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        endpoint = endpoint.copy(highFidelity = true, quality = if (endpoint.quality == "auto") "high" else endpoint.quality)
        // 文字、贴纸、形状这些装饰不发给 AI，只发照片本身。
        val ops = model.photoOps
        val key = pendingFaceKey
        val sentFrame = RectF(crop)
        val sentEllipse = ellipse?.let { RectF(it) }
        error = null
        result = null
        hasResult = false
        usageText = null
        AIClient.takeLastUsage()
        running = true
        started = System.currentTimeMillis()
        renderAI()
        val gen = ++generation
        job = model.scope.launch {
            try {
                val image = AIRunner.run(endpoint, prompt, proxy, ops, emptyList(), crop, appendGuidance = false, references = references)
                // 用量 AIClient 已经记过了，这里只取来显示
                val usage = AIClient.takeLastUsage()
                if (closed || gen != generation) return@launch
                usageText = usage?.summary
                result = image
                hasResult = true
                running = false
                if (key != null && sentEllipse != null) {
                    faceCache[key] = CachedFace(image, sentFrame, sentEllipse)
                    cachedFaceKeys = cachedFaceKeys + key
                }
                renderAI()
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

    private fun openSettings() {
        model.showSettings = true
    }

    // MARK: 界面

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("AI 美颜", mode == Mode.AI, symbol = "sparkles") { mode = Mode.AI }
                Chip("手动美颜", mode == Mode.MANUAL, symbol = "slider.horizontal.3") { mode = Mode.MANUAL }
                Spacer(Modifier.weight(1f))
                if (mode == Mode.AI) ProviderMenu(::openSettings, compact = true)
            }
            when {
                detectingFaces -> Row(
                    Modifier.fillMaxWidth().padding(vertical = 26.dp),
                    horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                    Text("正在找人脸…", fontSize = 14.sp, color = Color.White)
                }
                faces.isEmpty() -> FaceRescue(model, "这张图里没有找到人脸")
                else -> {
                    if (faces.size > 1) FacePicker()
                    if (mode == Mode.AI) AISection() else ManualSection()
                }
            }
            AIFailureView(if (running) null else error) { retryAI() }
        }
    }

    @Composable
    private fun FacePicker() {
        Row(
            Modifier.horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("修哪张脸", fontSize = 12.sp, color = Theme.dim)
            for (index in faces.indices) {
                Chip(if (faceEdited(index)) "第 ${index + 1} 张 ✓" else "第 ${index + 1} 张", faceIndex == index) { selectFace(index) }
            }
            Chip("看全图", false) { focus = null }
        }
    }

    @Composable
    private fun AISection() {
        when {
            !AISettings.isConfigured(AISettings.active) -> NeedsKeyView(openSettings = ::openSettings)
            running -> Running()
            else -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (hasResult) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("强度", fontSize = 13.sp, color = Theme.dim)
                        XSlider(strength, { setAIStrength(it) }, 0f..1f, Modifier.weight(1f))
                        Text(
                            "${(strength * 100).roundToInt()}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                            textAlign = TextAlign.End, modifier = Modifier.width(34.dp),
                        )
                        // 重新生成这个风格
                        Box(Modifier.size(34.dp).tap { regenerateFaceAI() }, contentAlignment = Alignment.Center) {
                            Icon(sym("arrow.clockwise"), "重新生成这个风格", tint = Color.White, modifier = Modifier.size(18.dp))
                            CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-2).dp))
                        }
                    }
                }
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp, end = 6.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    GenderToggle()
                    Chip("原图", !hasResult) { discardFaceAI() }
                    if (FavoriteFaceStore.current != null) {
                        val fav = BeautyStyle.favorite
                        Chip(
                            if (isFaceStyleCached(fav)) "${fav.title} ✓" else fav.title,
                            beautyStyle == fav.id && hasResult, symbol = "star.fill", badge = "AI",
                        ) { runFavoriteFace() }
                    }
                    for (style in BeautyStyle.current) {
                        Chip(
                            if (isFaceStyleCached(style)) "${style.title} ✓" else style.title,
                            beautyStyle == style.id && hasResult, badge = "AI",
                        ) { runFaceAI(style) }
                    }
                }
                val usage = usageText
                if (usage != null && hasResult) {
                    Text(usage, fontSize = 11.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth())
                }
            }
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
            Text("${beautyStyle ?: ""}：${AISettings.active.shortTitle} 正在处理… $seconds 秒", fontSize = 14.sp, color = Color.White)
            Spacer(Modifier.weight(1f))
            Text("取消", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Theme.accent, modifier = Modifier.tap { cancelAI() })
        }
    }

    @Composable
    private fun ManualSection() {
        val key = beautyKey
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Chip("原图", beauty.isIdentity) { applyBeautyPreset(null) }
                for (preset in BeautyPreset.all) {
                    Chip(preset.title, beautyPreset == preset.id) { applyBeautyPreset(preset) }
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(
                    "${(beauty[key] * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                    modifier = Modifier.width(40.dp),
                )
                XSlider(beauty[key], { setBeauty(key, it) }, 0f..1f, Modifier.weight(1f))
                if (key == BeautyKey.LIPS) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for ((index, c) in BeautyParams.lipColors.withIndex()) {
                            Box(
                                Modifier.size(22.dp).clip(CircleShape).background(Color(c.r, c.g, c.b))
                                    .border(2.dp, if (beauty.lipColor == index) Color.White else Color.Transparent, CircleShape)
                                    .tap { setLipColor(index) },
                            )
                        }
                    }
                }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
                for (item in BeautyKey.entries) {
                    IconTile(item.symbol, item.title, selected = item == key, modified = beauty[item] > 0f) { beautyKey = item }
                }
            }
        }
    }
}
