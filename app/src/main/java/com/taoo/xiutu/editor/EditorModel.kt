package com.taoo.xiutu.editor

import android.content.Context
import android.graphics.Bitmap
import android.graphics.PointF
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.ai.AIPreset
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.core.DraftStore
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.core.Saver
import com.taoo.xiutu.history.HistoryStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * 编辑器的全部状态。
 *
 * 思路：已确认的编辑存成一串和分辨率无关的操作（ops）。
 * 屏幕预览 = 操作作用在缩小的代理图上；保存 = 同一串操作作用在原图上。
 * 所以撤销只是去掉最后一个操作，原图始终不动。
 */
class EditorModel(val context: Context) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    // 状态
    var isLoading by mutableStateOf(true)
    var isBusy by mutableStateOf(false)
    var errorText by mutableStateOf<String?>(null)
    var displayImage by mutableStateOf<Bitmap?>(null)
    var comparing by mutableStateOf(false)
    var session by mutableStateOf<ToolSession?>(null)
        private set
    val tool: Tool? get() = session?.tool

    var ops by mutableStateOf<List<EditOp>>(emptyList())
        private set
    private var undoStates = ArrayList<List<EditOp>>()
    private var redoStates = ArrayList<List<EditOp>>()
    var undoCount by mutableIntStateOf(0)
        private set
    var redoCount by mutableIntStateOf(0)
        private set

    /** 每改动一次编辑步骤就加一，用来判断"保存之后有没有再改过"。 */
    var revision by mutableIntStateOf(0)
        private set

    // 界面上的浮层：文字输入、设置、提示
    var textInput by mutableStateOf<TextInputRequest?>(null)
    var showSettings by mutableStateOf(false)
    var toast by mutableStateOf<String?>(null)
    private var toastJob: Job? = null

    /** 原图（全分辨率）、编辑用的代理图（长边最多 4096）、当前已确认状态的预览（长边最多 1600）。 */
    var source: Bitmap? = null
        private set
    var proxy: Bitmap? = null
        private set
    /** 当前已确认状态的预览底图。工具在它上面做实时预览。 */
    var base: Bitmap? = null
        private set
    private var original: Bitmap? = null
    private var generation = 0

    /** 重新打开历史里的某一步来改时记下的东西；null = 这次是新加一步。 */
    private class Reopened(val prefix: List<EditOp>, val suffix: List<EditOp>, val preview: Bitmap?)
    private var reopened: Reopened? = null

    val canUndo get() = undoCount > 0 && tool == null
    val canRedo get() = redoCount > 0 && tool == null
    val hasEdits get() = ops.isNotEmpty()
    val hasChanges get() = undoCount > 0

    /** 画布上实际显示的图：按住对比按钮时显示修改前的样子。 */
    val shownImage: Bitmap?
        get() = if (!comparing) displayImage else (if (tool == null) original else base) ?: displayImage

    // MARK: 加载

    fun load(uri: Uri) = loadWith {
        if (draftEnabled) draftOriginal = runCatching { context.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
        Img.decode(context, uri)
    }

    fun load(file: File) = loadWith {
        if (draftEnabled) draftOriginal = runCatching { file.readBytes() }.getOrNull()
        Img.decode(file)
    }

    /** 从一张已经在内存里的图开始，并带上已有的修改步骤。 */
    fun load(image: Bitmap, initial: List<EditOp> = emptyList()) = loadWith(initial) { image }

    private fun loadWith(initial: List<EditOp> = emptyList(), fromDraft: Boolean = false, decode: () -> Bitmap?) {
        scope.launch {
            val r = withContext(Dispatchers.Default) {
                var full = decode() ?: return@withContext null
                // 原图超过这台设备 GPU 能放下的最大纹理时缩到上限，否则着色器步骤在保存时会失败
                val maxTex = runCatching { com.taoo.xiutu.gpu.Gpu.run { com.taoo.xiutu.gpu.Gpu.maxTextureSize } }.getOrDefault(4096)
                full = Img.downscale(full, maxTex)
                val p = Img.downscale(full, PROXY_SIDE)
                Triple(full, p, Img.downscale(p, PREVIEW_SIDE))
            }
            if (r == null) {
                errorText = "无法读取这张图片"
                isLoading = false
                return@launch
            }
            source = r.first
            proxy = r.second
            base = r.third
            original = r.third
            displayImage = r.third
            ops = initial
            if (fromDraft) {
                // 草稿里的画面是第一步：撤销一步就回到原图
                undoStates.add(emptyList())
                undoCount = 1
                revision++
            }
            isLoading = false
            if (initial.isNotEmpty()) rebuildBase()
            onLoaded?.invoke()
            onLoaded = null
        }
    }

    /** 加载完成后执行一次（比如直接打开某个工具）。 */
    var onLoaded: (() -> Unit)? = null

    private suspend fun rebuildBase() {
        val proxy = proxy ?: return
        val list = ops
        val gen = ++generation
        isBusy = true
        val out = withContext(Dispatchers.Default) {
            runCatching { Img.downscale(EditOp.applyAll(list, proxy), PREVIEW_SIDE) }.getOrNull()
        }
        if (gen != generation) return
        if (out != null) {
            base = out
            displayImage = out
        }
        isBusy = false
        saveDraft(committed = true)
    }

    // MARK: 草稿箱

    /** 这次编辑要不要自动存草稿（单独编辑图层时不存）。 */
    var draftEnabled = false
    /** 原图文件的数据，写草稿时一起存；null = 已经写过了或者没有。 */
    @Volatile private var draftOriginal: ByteArray? = null
    private var draftJob: Job? = null

    /** 从草稿接着编辑：原图当底，草稿里的画面作为第一步。 */
    fun loadDraft() {
        scope.launch {
            val snap = withContext(Dispatchers.IO) { runCatching { DraftStore.loadSnapshot() }.getOrNull() }
            val file = DraftStore.originalFile
            if (snap == null || !file.exists()) {
                errorText = "草稿读不出来了"
                isLoading = false
                return@launch
            }
            // 原图已经在草稿里，不用再写一遍
            draftOriginal = null
            loadWith(listOf(com.taoo.xiutu.ai.AIEdit(snap, emptyList(), reframed = true)), fromDraft = true) { Img.decode(file) }
        }
    }

    /** 停手一小会儿后，把当前画面（包括还没确认的 AI 结果）存进草稿箱。committed = 刚确认过，历史里已经有这一步了。 */
    fun saveDraft(committed: Boolean = false) {
        val proxy = proxy ?: return
        if (!draftEnabled) return
        var all = ops
        if (tool == Tool.AI && !committed) all = withLifted(runCatching { session?.commitOps() }.getOrNull() ?: emptyList())
        if (all.isEmpty()) return
        val original = draftOriginal
        val token = DraftStore.token
        draftJob?.cancel()
        draftJob = scope.launch {
            delay(600)
            val wrote = withContext(Dispatchers.Default) {
                runCatching { DraftStore.write(original, EditOp.applyAll(all, proxy), token) }.onFailure { it.printStackTrace() }.getOrDefault(false)
            }
            if (wrote && original != null && draftOriginal === original) draftOriginal = null
        }
    }

    /** 正常离开编辑器：不用草稿了。 */
    fun discardDraft() {
        draftJob?.cancel()
        draftJob = null
        if (draftEnabled) DraftStore.clear()
    }

    // MARK: 工具进出

    /** 打开一个新工具（不走"重新打开"）。 */
    fun begin(t: Tool): ToolSession? {
        if (base == null || isBusy) return null
        comparing = false
        val s = ToolRegistry.create(t, this) ?: return null
        session = s
        s.start()
        return s
    }

    /** 打开 AI 修图的某一组。 */
    fun beginAI(group: AIPresetGroup, prompt: String = "", preset: AIPreset? = null, run: Boolean = false) {
        beginLifting(Tool.AI) { s -> (s as? AiToolApi)?.setup(group, prompt, preset, run) }
    }

    /** 从别的工具里点了要用 AI 的功能：当前工具里已经调好的先保留成一步，再转到 AI 修图并直接开始生成。 */
    fun startAIPreset(preset: AIPreset, group: AIPresetGroup = AIPresetGroup.FIX) {
        if (isBusy || session?.busy == true) return
        commitTool { beginAI(group, preset.prompt, preset, run = true) }
    }

    /** 从滤镜里点了一位大师：转到 AI 修图，先显示这位大师的风格。 */
    fun startMaster(preset: AIPreset) {
        if (isBusy || session?.busy == true) return
        commitTool {
            beginLifting(Tool.AI) { s ->
                (s as? AiToolApi)?.setup(AIPresetGroup.MASTER, "", null, run = false)
                (s as? com.taoo.xiutu.ai.AISession)?.pickMaster(preset.title)
            }
        }
    }

    /** 直接显示一张预览图。只在有工具打开时生效。 */
    fun showLive(image: Bitmap) {
        if (session != null) displayImage = image
    }

    private val liveJobs = Channel<() -> Bitmap?>(Channel.CONFLATED)

    init {
        // 只渲染最新的一帧：渲染跟不上手指时，中间帧直接丢掉。
        scope.launch(Dispatchers.Default) {
            for (job in liveJobs) {
                val img = runCatching { job() }.onFailure { it.printStackTrace() }.getOrNull() ?: continue
                withContext(Dispatchers.Main) { if (session != null) displayImage = img }
            }
        }
    }

    /** 提交一帧实时预览（后台渲染）。 */
    fun live(job: () -> Bitmap?) {
        liveJobs.trySend(job)
    }

    /** 用当前底图渲染一帧实时预览。 */
    fun liveOnBase(job: (Bitmap) -> Bitmap) {
        val b = base ?: return
        live { job(b) }
    }

    fun cancelTool() {
        session?.close()
        session = null
        comparing = false
        reopened?.let { r ->
            reopened = null
            r.preview?.let { base = it }
        }
        dropLifted()
        displayImage = base
    }

    /** 确认当前工具。next 不为空时确认完接着执行它，用来从一个工具直接换到另一个。 */
    fun commitTool(next: (() -> Unit)? = null) {
        val s = session ?: run { next?.invoke(); return }
        if (s.busy) return
        // 工具要求原地替换整串历史（图层）
        val replacement = runCatching { s.replacementOps() }.onFailure { it.printStackTrace() }.getOrNull()
        if (replacement != null) {
            comparing = false
            clearLifted()
            s.close()
            replaceOps(replacement, next)
            return
        }
        val newOps = runCatching { s.commitOps() }.onFailure { it.printStackTrace() }.getOrElse { emptyList() }
        comparing = false
        val r = reopened
        if (r != null) {
            if (s.unchangedSinceReopen()) {
                cancelTool(); next?.invoke(); return
            }
            reopened = null
            s.close()
            replaceOps(r.prefix + newOps + r.suffix, next)
            return
        }
        if (newOps.isEmpty()) {
            cancelTool(); next?.invoke(); return
        }
        recordUndo()
        // 拿下过装饰：新的一步放在照片这一层，装饰仍然浮在最上面
        ops = withLifted(newOps)
        clearLifted()
        scope.launch {
            rebuildBase()
            s.close()
            session = null
            next?.invoke()
        }
    }

    private fun recordUndo() {
        undoStates.add(ops)
        redoStates.clear()
        undoCount = undoStates.size
        redoCount = 0
        revision++
    }

    /** 把整串操作换成新的一串，然后关掉当前工具。 */
    fun replaceOps(newOps: List<EditOp>, next: (() -> Unit)? = null) {
        recordUndo()
        ops = newOps
        comparing = false
        scope.launch {
            rebuildBase()
            session?.close()
            session = null
            next?.invoke()
        }
    }

    fun undo() {
        if (!canUndo) return
        redoStates.add(ops)
        ops = undoStates.removeAt(undoStates.size - 1)
        undoCount = undoStates.size; redoCount = redoStates.size
        revision++
        scope.launch { rebuildBase() }
    }

    fun redo() {
        if (!canRedo) return
        undoStates.add(ops)
        ops = redoStates.removeAt(redoStates.size - 1)
        undoCount = undoStates.size; redoCount = redoStates.size
        revision++
        scope.launch { rebuildBase() }
    }

    // MARK: 浮在照片上的装饰

    /** 进 AI 修图 / 美颜时先拿下来的装饰（文字、贴纸、形状、图层）：AI 只处理照片，确认后再放回最上面。 */
    private var liftedFloating: List<EditOp> = emptyList()
    /** 拿下装饰之前的底图：取消时换回来。 */
    private var liftedBase: Bitmap? = null

    /** 照片本身的步骤：拿下了装饰时不含它们。AI 修图、AI 美颜发出去的就是这些。 */
    val photoOps: List<EditOp> get() = if (liftedFloating.isEmpty()) ops else EditOp.splitFloating(ops).first

    /** 当前历史加上新的几步；拿下过装饰时新步骤放在照片和装饰之间。 */
    private fun withLifted(newOps: List<EditOp>): List<EditOp> {
        val color = session?.liftedColor ?: emptyList()
        // AI 修图拿下了滤镜和调色：新的一步放在它们下面
        if (color.isNotEmpty() && newOps.isNotEmpty()) return EditOp.splitColor(photoOps).first + newOps + color + liftedFloating
        return photoOps + newOps + liftedFloating
    }

    /**
     * 打开工具。AI 修图 / 美颜：历史末尾的装饰先拿下来，底图换成只有照片的样子再打开，
     * 确认后装饰放回最上面，不会被 AI 画死在照片里。
     */
    private fun beginLifting(t: Tool, ready: ((ToolSession) -> Unit)?) {
        val snapshot = ops
        val (photo, floating) = EditOp.splitFloating(snapshot)
        val proxy = proxy
        if ((t != Tool.AI && t != Tool.BEAUTY) || floating.isEmpty() || reopened != null || proxy == null) {
            begin(t)?.let { ready?.invoke(it) }
            return
        }
        if (base == null || isBusy || tool != null) return
        isBusy = true
        scope.launch {
            val img = withContext(Dispatchers.Default) {
                runCatching { Img.downscale(EditOp.applyAll(photo, proxy), PREVIEW_SIDE) }.getOrNull()
            }
            isBusy = false
            if (tool != null) return@launch
            if (img != null && ops === snapshot) {
                liftedFloating = floating
                liftedBase = base
                base = img
                displayImage = img
            }
            val s = begin(t)
            if (s == null) {
                dropLifted()
                displayImage = base
                return@launch
            }
            ready?.invoke(s)
        }
    }

    /** 不用拿下来的装饰了（确认之后）。 */
    private fun clearLifted() {
        liftedFloating = emptyList()
        liftedBase = null
    }

    /** 取消：底图换回带装饰的样子。 */
    private fun dropLifted() {
        if (liftedFloating.isEmpty()) return
        liftedBase?.let { base = it }
        clearLifted()
    }

    // MARK: 重新打开装饰

    private class ReopenPlan(val prefix: List<EditOp>, val suffix: List<EditOp>, val op: EditOp?, val merged: List<EditOp>)

    private fun reopenPlan(t: Tool): ReopenPlan? {
        // AI 整张重画过之后，前面那些步骤已经画死在结果里，不能再单独改。
        val barrier = ops.indexOfLast { it.bakesInput }
        if (ops.any { it.mergesOnReopen(t) }) {
            val floor = maxOf(barrier, ops.indexOfLast { it.changesCanvas })
            val merged = ArrayList<EditOp>()
            val rest = ArrayList<EditOp>()
            ops.forEachIndexed { i, op -> if (i > floor && op.mergesOnReopen(t)) merged += op else rest += op }
            if (merged.isNotEmpty()) return ReopenPlan(rest, emptyList(), null, merged)
        }
        val i = ops.indexOfLast { it.reopens(t) }
        if (i < 0 || i <= barrier) return null
        return ReopenPlan(ops.subList(0, i).toList(), ops.subList(i + 1, ops.size).toList(), ops[i], emptyList())
    }

    /**
     * 打开工具。装饰类工具如果历史里已经有这一类的步骤，就把那一步重新打开接着改。
     * ready 在工具真正打开之后调用。
     */
    fun open(t: Tool, selecting: String? = null, ready: ((ToolSession) -> Unit)? = null) {
        if (tool != null || isBusy || isLoading) return
        val plan = reopenPlan(t)
        val proxy = proxy
        if (plan == null || proxy == null) {
            beginLifting(t, ready)
            return
        }
        isBusy = true
        scope.launch {
            val prefix = plan.prefix
            val img = withContext(Dispatchers.Default) {
                runCatching { Img.downscale(EditOp.applyAll(prefix, proxy), PREVIEW_SIDE) }.getOrNull()
            }
            isBusy = false
            if (tool != null || img == null) return@launch
            reopened = Reopened(plan.prefix, plan.suffix, base)
            base = img
            displayImage = img
            val s = begin(t)
            if (s == null) { cancelTool(); return@launch }
            if (plan.op != null) s.reopen(plan.op) else s.reopenMerged(plan.merged, selecting)
            ready?.invoke(s)
        }
    }

    /** 没开工具时点了画面：点中了还能改的文字、贴纸、马赛克等，就直接把它打开。 */
    fun tapDecoration(p: PointF) {
        val b = base ?: return
        if (tool != null || isBusy) return
        val floor = maxOf(ops.indexOfLast { it.bakesInput }, ops.indexOfLast { it.changesCanvas })
        val ratio = b.height.toFloat() / b.width
        for (i in ops.indices.reversed()) {
            if (i <= floor) break
            val hit = ops[i].hitTest(p, ratio) ?: continue
            open(hit, selecting = (ops[i] as? HitSelectable)?.selectedId(p, ratio))
            return
        }
    }

    // MARK: 浮层

    fun requestText(initial: String, placeholder: String, onDone: (String) -> Unit) {
        textInput = TextInputRequest(initial, placeholder, onDone)
    }

    fun showToast(message: String) {
        toastJob?.cancel()
        toast = message
        toastJob = scope.launch {
            kotlinx.coroutines.delay(2000)
            toast = null
        }
    }

    // MARK: 保存

    /** 按当前所有步骤算出来的成品尺寸。 */
    suspend fun outputSize(): Pair<Int, Int>? {
        val src = source ?: return null
        val list = ops
        return withContext(Dispatchers.Default) {
            // 只有改变画布的步骤会改尺寸：用小图算比例再换算回原图
            if (list.none { it.changesCanvas }) return@withContext src.width to src.height
            val out = EditOp.applyAll(list, src)
            out.width to out.height
        }
    }

    /** 用原图分辨率重新跑一遍所有操作，存进相册。 */
    suspend fun export(options: SaveOptions): Boolean {
        val src = source ?: return false
        val list = ops
        return withContext(Dispatchers.Default) {
            runCatching {
                var out = EditOp.applyAll(list, src)
                options.size.maxSide?.let { out = Img.downscale(out, it) }
                val data = Saver.encode(out, options)
                Saver.saveToGallery(context, data, options.format)
                if (HistoryStore.enabled) HistoryStore.add(context, data, options.format.ext, "修图", EditRecipe.from(list, proxy ?: src))
                true
            }.getOrElse { it.printStackTrace(); false }
        }
    }

    fun dispose() {
        session?.close()
        scope.cancel()
        liveJobs.close()
    }

    companion object {
        const val PROXY_SIDE = 4096
        const val PREVIEW_SIDE = 1600
    }
}

/** 点画面时能说出点中的是哪一项（文字 / 贴纸）。 */
interface HitSelectable {
    fun selectedId(point: PointF, ratio: Float): String?
}

class TextInputRequest(val initial: String, val placeholder: String, val onDone: (String) -> Unit)
