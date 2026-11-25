package com.taoo.xiutu.tools.smartcrop

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIFailureView
import com.taoo.xiutu.ai.AIMainButton
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.NeedsKeyView
import com.taoo.xiutu.ai.ProviderMenu
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.core.Saver
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.SaveOptions
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.history.HistoryStore
import com.taoo.xiutu.tools.crop.CropOp
import com.taoo.xiutu.tools.crop.CropParams
import com.taoo.xiutu.tools.crop.CropRect
import com.taoo.xiutu.tools.crop.cropDrag
import com.taoo.xiutu.tools.crop.drawCropFrame
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
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

/** 智能构图：AI 看图找出几个取景，选一个应用，或者全部存下来。 */
class SmartCropSession(model: EditorModel) : ToolSession(model, Tool.SMART_CROP) {
    private var items by mutableStateOf<List<SmartCropItem>>(emptyList())
    private var selected by mutableIntStateOf(-1)
    private var ratio by mutableStateOf(SmartCropRatio.FREE)
    private var running by mutableStateOf(false)
    private var started by mutableLongStateOf(0L)
    private var rounds = 0
    private var error by mutableStateOf<String?>(null)
    private var usage by mutableStateOf<String?>(null)
    private var saving by mutableStateOf(false)
    private var note by mutableStateOf<String?>(null)
    private var job: Job? = null
    private var generation = 0
    private var closed = false

    private val current get() = items.firstOrNull { it.id == selected }

    override val customCanvas: Boolean get() = true

    override fun close() {
        closed = true
        cancel()
    }

    override fun commitOps(): List<EditOp> {
        cancel()
        return current?.let { listOf(CropOp(CropParams(rect = it.rect))) } ?: emptyList()
    }

    /** 照片的像素大小（按成品算）：预览最长 1600，按原图比例放大回去。 */
    private fun pixels(base: Bitmap): Pair<Float, Float> {
        val src = model.source ?: return base.width.toFloat() to base.height.toFloat()
        val k = max(src.width, src.height).toFloat() / max(base.width, base.height)
        return base.width * k to base.height * k
    }

    fun run() {
        val base = model.base ?: return
        val proxy = model.proxy ?: return
        if (closed || running) return
        val endpoint = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        error = null
        note = null
        running = true
        started = System.currentTimeMillis()
        val (pw, ph) = pixels(base)
        // 裁出来的短边至少这么大（占宽高的比例）：大约 800 像素，最多三成。
        val minimum = min(max(800f / max(min(pw, ph), 1f), 0.08f), 0.3f)
        val again = rounds > 0
        val ops = model.ops
        val gen = ++generation
        job = model.scope.launch {
            try {
                AIClient.takeLastUsage()
                // 小局部也要看得清：发大一点的图。
                val jpeg = withContext(Dispatchers.Default) { Img.jpeg(Img.downscale(EditOp.applyAll(ops, proxy), 2048), 88) }
                val text = AIClient.look(endpoint, SmartCrop.prompt(pw.roundToInt(), ph.roundToInt(), minimum, again = again), jpeg)
                val used = AIClient.takeLastUsage()
                val found = SmartCrop.parse(text, minimum)
                if (closed || gen != generation) return@launch
                running = false
                usage = used?.summary
                if (found.isEmpty()) {
                    error = "AI 没有给出可用的取景，可以再试一次或换一家服务商。"
                    return@launch
                }
                rounds++
                items = found
                selected = found.first().id
                chooseRatio(ratio)
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

    private fun cancel() {
        generation++
        job?.cancel()
        job = null
        running = false
    }

    private fun chooseRatio(r: SmartCropRatio) {
        ratio = r
        val b = model.base ?: return
        val w = b.width.toFloat()
        val h = b.height.toFloat()
        items = items.map { it.copy(rect = SmartCrop.fit(it.original, r.value(w, h), w, h)) }
    }

    /** 手动拖框时锁定的比例（归一化坐标下的宽 / 高）。 */
    private val locked: Float?
        get() {
            val b = model.base ?: return null
            val w = b.width.toFloat()
            val h = b.height.toFloat()
            return ratio.value(w, h)?.let { it * h / w }
        }

    private fun setRect(rect: CropRect) {
        items = items.map { if (it.id == selected) it.copy(rect = rect) else it }
    }

    /** 全部存进相册：所有取景按原图分辨率各裁一张。 */
    private fun saveAll() {
        val src = model.source ?: return
        if (saving) return
        saving = true
        note = null
        val ops = model.ops
        val list = items.toList()
        model.scope.launch {
            val saved = withContext(Dispatchers.Default) {
                runCatching {
                    val full = EditOp.applyAll(ops, src)
                    list.count { item ->
                        runCatching {
                            val data = Img.jpeg(CropParams(rect = item.rect).apply(full), 95)
                            Saver.saveToGallery(model.context, data, SaveOptions.Format.JPEG)
                            if (HistoryStore.enabled) HistoryStore.add(model.context, data, "jpg", "智能构图")
                        }.onFailure { it.printStackTrace() }.isSuccess
                    }
                }.getOrDefault(0)
            }
            saving = false
            note = if (saved == list.size && saved > 0) "已保存 $saved 张到相册" else "保存失败，请检查相册权限"
        }
    }

    // MARK: 画布

    /** 整张照片上画出找到的取景，选中的那个可以拖、可以改大小；没选中的是虚线框加序号，点序号选它。 */
    @Composable
    override fun Canvas(modifier: Modifier) {
        val image = model.base
        BoxWithConstraints(modifier.fillMaxSize()) {
            val px = LocalDensity.current.density
            val margin = 24f * px
            val vw = constraints.maxWidth.toFloat()
            val vh = constraints.maxHeight.toFloat()
            val iw = (image?.width ?: 1).toFloat()
            val ih = (image?.height ?: 1).toFloat()
            val k = min(max(1f, vw - margin * 2) / iw, max(1f, vh - margin * 2) / ih)
            val fw = iw * k
            val fh = ih * k
            val img = Rect(Offset((vw - fw) / 2, (vh - fh) / 2), Size(fw, fh))
            val bmp = remember(image) { image?.asImageBitmap() }
            fun frame(r: CropRect) = Rect(img.left + r.x * fw, img.top + r.y * fh, img.left + r.maxX * fw, img.top + r.maxY * fh)
            Canvas(Modifier.fillMaxSize().cropDrag({ img }, { current?.rect }, { locked }, ::setRect)) {
                if (bmp != null) {
                    drawImage(
                        bmp, dstOffset = IntOffset(img.left.roundToInt(), img.top.roundToInt()),
                        dstSize = IntSize(fw.roundToInt(), fh.roundToInt()), filterQuality = FilterQuality.High,
                    )
                }
                current?.let { drawCropFrame(img, frame(it.rect), px) }
                for (item in items) {
                    if (item.id == selected) continue
                    val f = frame(item.rect)
                    drawRect(
                        Color.White.copy(alpha = 0.55f), f.topLeft, f.size,
                        style = Stroke(1f * px, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5f * px, 4f * px))),
                    )
                }
            }
            items.forEachIndexed { i, item ->
                if (item.id != selected) {
                    val f = frame(item.rect)
                    Number(
                        i + 1, 24,
                        Modifier.offset { IntOffset((f.left + 4 * px).roundToInt(), (f.top + 4 * px).roundToInt()) }.tap { selected = item.id },
                    )
                }
            }
        }
    }

    @Composable
    private fun Number(n: Int, side: Int, modifier: Modifier) {
        Box(modifier.size(side.dp).clip(CircleShape).background(Theme.accent), contentAlignment = Alignment.Center) {
            Text("$n", fontSize = (side / 2).sp, lineHeight = (side / 2).sp, fontWeight = FontWeight.Bold, color = Color.Black)
        }
    }

    // MARK: 面板

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 12.dp, bottom = 4.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                ProviderMenu({ model.showSettings = true }, compact = true)
            }
            AIFailureView(if (running) null else error) { run() }
            when {
                !AISettings.isConfigured(AISettings.active) && items.isEmpty() -> NeedsKeyView { model.showSettings = true }
                running -> Running()
                items.isEmpty() -> AIMainButton("开始分析", Modifier.fillMaxWidth(), symbol = "viewfinder") { run() }
                else -> Results()
            }
            usage?.let { Text(it, fontSize = 11.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth()) }
            note?.let { Text(it, fontSize = 12.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth()) }
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
            Text("${AISettings.active.shortTitle} 正在看图找取景… $seconds 秒", fontSize = 14.sp, color = Color.White)
            Spacer(Modifier.weight(1f))
            Text("取消", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Theme.accent, modifier = Modifier.tap { cancel() })
        }
    }

    @Composable
    private fun Results() {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (r in SmartCropRatio.entries) Chip(r.title, selected = ratio == r) { chooseRatio(r) }
            }
            Row(
                Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
            ) {
                items.forEachIndexed { i, item -> CropTile(i + 1, item) }
            }
            current?.let { c ->
                val text = listOf(c.how, c.why).filter { it.isNotEmpty() }.joinToString(" · ")
                if (text.isNotEmpty()) Text(text, fontSize = 13.sp, color = Theme.dim, modifier = Modifier.fillMaxWidth())
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(
                    Modifier.weight(1f).height(42.dp).clip(CircleShape).background(Theme.chip).press(!saving) { saveAll() },
                    contentAlignment = Alignment.Center,
                ) { Text(if (saving) "正在处理…" else "全部保存", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
                AIMainButton("再找一组", Modifier.weight(1f), symbol = "viewfinder") { run() }
            }
        }
    }

    @Composable
    private fun CropTile(n: Int, item: SmartCropItem) {
        val on = item.id == selected
        val base = model.base
        val image = remember(base, item.rect) {
            base?.let { b ->
                val r = item.rect
                val piece = Img.cropNormalized(b, android.graphics.RectF(r.x, r.y, r.maxX, r.maxY))
                Img.downscale(piece, 260).asImageBitmap()
            }
        }
        Column(Modifier.width(84.dp).press { selected = item.id }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            val shape = RoundedCornerShape(10.dp)
            Box(
                Modifier.size(84.dp).clip(shape).background(Color(0.1f, 0.1f, 0.1f))
                    .then(if (on) Modifier.border(2.5.dp, Theme.accent, shape) else Modifier),
            ) {
                if (image != null) Image(image, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize())
                Number(n, 19, Modifier.padding(4.dp))
            }
            Text(
                item.title, fontSize = 11.5.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                color = if (on) Theme.accent else Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center,
            )
        }
    }
}
