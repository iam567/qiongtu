package com.taoo.xiutu.editor

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.history.HistoryStore
import com.taoo.xiutu.settings.SettingsSheet
import com.taoo.xiutu.ui.*
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** 底部一级菜单。 */
enum class MainTab(val title: String, val directTool: Tool? = null) {
    TOOLS("工具"), BEAUTY("美颜"), BODY("美体"), HAIR("美发"),
    FILTER("滤镜", Tool.FILTER), EFFECT("特效", Tool.EFFECT), ADJUST("调色", Tool.ADJUST), DECO("装饰"), AI("AI 修图");
}

/** 二级菜单里点了之后做什么。 */
sealed interface MenuAction {
    data class OpenTool(val tool: Tool) : MenuAction
    data class OpenAI(val group: AIPresetGroup) : MenuAction
    data object Erase : MenuAction
    /** 打开工具后再切到指定的做法（美颜的 AI / 手动，美体塑形的各种模式）。 */
    data class ToolMode(val tool: Tool, val mode: String) : MenuAction
}

/** 工具里有几种做法、要从菜单直接进到某一种时实现它。 */
interface ModeSelectable { fun selectMode(mode: String) }

class MenuEntry(val title: String, val symbol: String, val badge: String? = null, val action: MenuAction) {
    constructor(tool: Tool) : this(tool.title, tool.symbol, null, MenuAction.OpenTool(tool))
}

/** 每个一级菜单下面的二级入口。只列出已经做好的工具。 */
fun MainTab.entries(): List<MenuEntry> {
    val list = when (this) {
        MainTab.TOOLS -> listOf(
            MenuEntry(Tool.CROP), MenuEntry(Tool.FILTER), MenuEntry(Tool.ADJUST),
            MenuEntry("消除", "eraser", "AI", MenuAction.Erase),
            MenuEntry(Tool.RETOUCH),
            MenuEntry(Tool.COLLAGE), MenuEntry(Tool.LAYERS),
        )
        MainTab.BEAUTY -> listOf(
            MenuEntry("满意脸型", "star.fill", "AI", MenuAction.ToolMode(Tool.BEAUTY, "favorite")),
            MenuEntry("一键美颜", "sparkles", "AI", MenuAction.ToolMode(Tool.BEAUTY, "ai")),
            MenuEntry(Tool.RESHAPE), MenuEntry(Tool.MAKEUP), MenuEntry(Tool.SKIN),
            MenuEntry("手动美颜", "slider.horizontal.3", null, MenuAction.ToolMode(Tool.BEAUTY, "manual")),
        )
        MainTab.BODY -> listOf(
            MenuEntry("一键美体", "figure.stand", null, MenuAction.ToolMode(Tool.SHAPE, "preset")),
            MenuEntry("塑形", "figure.arms.open", null, MenuAction.ToolMode(Tool.SHAPE, "shape")),
            MenuEntry("增高", "arrow.up.and.down", null, MenuAction.ToolMode(Tool.SHAPE, "tall")),
            MenuEntry("瘦身", "arrow.right.and.line.vertical.and.arrow.left", null, MenuAction.ToolMode(Tool.SHAPE, "slim")),
            MenuEntry("缩放", "circle.dashed", null, MenuAction.ToolMode(Tool.SHAPE, "zoom")),
            MenuEntry(Tool.BODY_TONE),
            MenuEntry("推拉", "hand.draw", null, MenuAction.OpenTool(Tool.LIQUIFY)),
            MenuEntry("AI 美体", "sparkles", "AI", MenuAction.OpenAI(AIPresetGroup.BODY)),
        )
        MainTab.HAIR -> AIPresetGroup.hairGroups.map { MenuEntry(it.title, it.symbol, "AI", MenuAction.OpenAI(it)) }
        MainTab.DECO -> listOf(
            MenuEntry(Tool.STICKER), MenuEntry(Tool.TEXT), MenuEntry(Tool.GRAPHIC), MenuEntry(Tool.DOODLE), MenuEntry(Tool.FRAME),
            MenuEntry(Tool.BACKDROP), MenuEntry(Tool.MARK), MenuEntry(Tool.MOSAIC),
        )
        MainTab.AI -> AIPresetGroup.editGroups.map { MenuEntry(it.menuTitle, it.symbol, "AI", MenuAction.OpenAI(it)) } +
            MenuEntry(Tool.SMART_CROP.title, Tool.SMART_CROP.symbol, "AI", MenuAction.OpenTool(Tool.SMART_CROP))
        MainTab.FILTER, MainTab.EFFECT, MainTab.ADJUST -> emptyList()
    }
    return list.filter { e ->
        when (val a = e.action) {
            is MenuAction.OpenTool -> ToolRegistry.available(a.tool)
            is MenuAction.ToolMode -> ToolRegistry.available(a.tool)
            else -> true
        }
    }
}

@Composable
fun EditorScreen(
    model: EditorModel,
    initialTool: Tool?,
    /** 不为空时编辑的是一个图层自己的内容（或者图层下面的照片）：点"完成"把步骤交回去，不存相册。 */
    layerEdit: LayerEditRequest? = null,
    /** 打开后把历史图库里某张图的处理步骤套到这张照片上。 */
    recipe: EditRecipe? = null,
    /** 自动拼图：打开拼接页并摆好这组截图。 */
    stitchJob: com.taoo.xiutu.tools.collage.AutoStitchJob? = null,
    onClose: () -> Unit,
) {
    val embedded = layerEdit != null
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var savedRevision by remember { mutableStateOf<Int?>(null) }
    val isSaved = savedRevision == model.revision
    var confirmDiscard by remember { mutableStateOf(false) }
    var showSave by remember { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var mainTab by remember { mutableStateOf(MainTab.TOOLS) }
    val player = remember { recipe?.let { RecipePlayer(model) } }
    val replaying = player?.status != null

    fun start(t: Tool) {
        model.open(t) { s ->
            if (t == Tool.TEXT) (s as? TextStarter)?.onOpenedFromMenu()
            if (stitchJob != null) (s as? com.taoo.xiutu.tools.collage.CollageSession)?.loadAutoStitch(stitchJob)
        }
    }

    LaunchedEffect(Unit) {
        if (initialTool != null) {
            if (model.isLoading) model.onLoaded = { start(initialTool) } else start(initialTool)
        }
    }
    LaunchedEffect(Unit) {
        if (recipe == null || player == null) return@LaunchedEffect
        snapshotFlow { model.isLoading }.first { !it }
        if (model.base != null) player.start(recipe)
    }
    DisposableEffect(Unit) { onDispose { model.dispose() } }

    /** 正常离开编辑器：草稿用不着了。 */
    fun leave() {
        model.discardDraft()
        onClose()
    }

    fun tryClose() {
        val changed = if (embedded) model.hasChanges else model.hasEdits
        if (changed && !isSaved) confirmDiscard = true else leave()
    }
    BackHandler {
        when {
            model.textInput != null -> model.textInput = null
            model.tool != null -> model.cancelTool()
            else -> tryClose()
        }
    }

    Box(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding().imePadding()) {
        Column(Modifier.fillMaxSize()) {
            TopBar(model, isSaved, saving, onBack = ::tryClose, onSave = { showSave = true },
                onDone = layerEdit?.let { req -> { req.onDone(model.ops); onClose() } })
            Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(0.dp))) {
                EditorCanvas(model, onLayers = if (embedded) null else ({ start(Tool.LAYERS) }))
                // 单独编辑图层内容时，标出改的是哪一层
                if (layerEdit != null) {
                    Text(
                        "正在编辑：${layerEdit.title}", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.Black,
                        modifier = Modifier.align(Alignment.TopCenter).padding(top = 6.dp).clip(CircleShape)
                            .background(Theme.accent).padding(horizontal = 12.dp, vertical = 5.dp),
                    )
                }
                player?.status?.let { status ->
                    RecipeBanner(status, Modifier.align(Alignment.TopCenter)) { player.stop() }
                }
            }
            Box {
                Bottom(model, mainTab, embedded, onTab = { mainTab = it }, onEntry = { action ->
                    when (action) {
                        is MenuAction.OpenTool -> start(action.tool)
                        is MenuAction.OpenAI -> model.beginAI(action.group)
                        MenuAction.Erase -> model.beginAI(AIPresetGroup.REMOVE, AIPresetGroup.REMOVE.presets.first().prompt)
                        is MenuAction.ToolMode ->
                            // 进美颜后直接按满意脸型修：还没有满意脸型就不进
                            if (action.mode == "favorite" && com.taoo.xiutu.tools.beauty.FavoriteFaceStore.current == null) {
                                model.showToast("还没有满意脸型")
                            } else {
                                model.open(action.tool) { s -> (s as? ModeSelectable)?.selectMode(action.mode) }
                            }
                    }
                })
                // 套用步骤时底部不能点
                if (replaying) Box(Modifier.matchParentSize().pointerInput(Unit) {
                    awaitPointerEventScope { while (true) awaitPointerEvent().changes.forEach { it.consume() } }
                })
            }
        }
        if (model.isLoading || model.isBusy || saving) BusyOverlay()
        model.errorText?.let { Text(it, color = Theme.dim, modifier = Modifier.align(Alignment.Center)) }
        model.toast?.let { Toast(it, Modifier.align(Alignment.BottomCenter).padding(bottom = 230.dp)) }
        model.textInput?.let { req ->
            TextInputOverlay(req.initial, req.placeholder) { text ->
                model.textInput = null
                req.onDone(text)
            }
        }
    }

    if (showSave) {
        SaveSheet(model, onDismiss = { showSave = false }) { options ->
            showSave = false
            saving = true
            val rev = model.revision
            scope.launch {
                val ok = model.export(options)
                saving = false
                if (ok) savedRevision = rev
                model.showToast(if (ok) "已保存到相册" else "保存失败，请检查相册权限")
            }
        }
    }
    if (model.showSettings) SettingsSheet(onDismiss = { model.showSettings = false })
    if (confirmDiscard) {
        AlertDialog(
            onDismissRequest = { confirmDiscard = false },
            title = { Text("放弃当前修改？") },
            confirmButton = { TextButton({ confirmDiscard = false; leave() }) { Text("放弃修改", color = Theme.red) } },
            dismissButton = { TextButton({ confirmDiscard = false }) { Text("继续编辑", color = Color.White) } },
            containerColor = Theme.panel,
        )
    }
}

/** 正在套用别的图的处理步骤：进度和"停止"。 */
@Composable
private fun RecipeBanner(status: String, modifier: Modifier, onStop: () -> Unit) {
    Row(
        modifier.padding(top = 6.dp).padding(horizontal = 16.dp).clip(CircleShape).background(Theme.accent)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        CircularProgressIndicator(color = Color.Black, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
        Text(
            status, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.Black, maxLines = 1,
            overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis, modifier = Modifier.weight(1f, fill = false),
        )
        Text("停止", fontSize = 13.sp, fontWeight = FontWeight.Bold, color = Color.Black, modifier = Modifier.tap(onClick = onStop))
    }
}

/** 文字工具：从菜单进来时自动弹出输入框。 */
interface TextStarter { fun onOpenedFromMenu() }

@Composable
private fun TopBar(model: EditorModel, isSaved: Boolean, saving: Boolean, onBack: () -> Unit, onSave: () -> Unit, onDone: (() -> Unit)? = null) {
    Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        if (model.tool == null) {
            Box(Modifier.size(44.dp).tap(onClick = onBack), contentAlignment = Alignment.Center) {
                Icon(sym("chevron.left"), "返回", tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(44.dp).alpha(if (model.canUndo) 1f else 0.3f).tap(model.canUndo) { model.undo() }, contentAlignment = Alignment.Center) {
                Icon(sym("arrow.uturn.backward"), "撤销", tint = Color.White)
            }
            Box(Modifier.size(44.dp).alpha(if (model.canRedo) 1f else 0.3f).tap(model.canRedo) { model.redo() }, contentAlignment = Alignment.Center) {
                Icon(sym("arrow.uturn.forward"), "重做", tint = Color.White)
            }
            Spacer(Modifier.weight(1f))
            if (onDone != null) {
                // 单独编辑图层内容：不存相册，把修改步骤交回图层
                val enabled = !model.isLoading && !model.isBusy
                Box(
                    Modifier.clip(CircleShape).background(if (enabled) Theme.accent else Theme.accent.copy(alpha = 0.4f))
                        .tap(enabled, onDone).padding(horizontal = 18.dp, vertical = 8.dp),
                ) { Text("完成", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
                return@Row
            }
            if (isSaved) {
                Icon(sym("checkmark.circle.fill"), null, tint = Theme.green, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(3.dp))
                Text("已保存", fontSize = 12.sp, color = Theme.green, fontWeight = FontWeight.Medium)
                Spacer(Modifier.width(8.dp))
            }
            Box(
                Modifier.clip(CircleShape).background(if (model.isLoading || saving) Color.White.copy(alpha = 0.4f) else Color.White)
                    .tap(!model.isLoading && !saving, onSave).padding(horizontal = 18.dp, vertical = 8.dp),
            ) { Text("保存", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
        }
    }
}

@Composable
private fun EditorCanvas(model: EditorModel, onLayers: (() -> Unit)?) {
    val s = model.session
    if (s != null && s.customCanvas) {
        s.Canvas(Modifier.fillMaxSize())
        return
    }
    Box(Modifier.fillMaxSize()) {
        val handlers = if (s?.drawing == true) DrawHandlers(
            began = { p, k -> s.strokeBegan(p, k) },
            moved = { s.strokeMoved(it) },
            ended = { s.strokeEnded() },
            cancelled = { s.strokeCancelled() },
        ) else null
        val tap: ((android.graphics.PointF) -> Unit)? = when {
            s == null -> { p -> model.tapDecoration(p) }
            s.wantsTap -> { p -> s.onTap(p) }
            else -> null
        }
        ZoomableCanvas(model.shownImage, handlers = handlers, focus = s?.focusRect, onTap = tap)
        Column(Modifier.align(Alignment.BottomEnd)) {
            if (s == null && onLayers != null && ToolRegistry.available(Tool.LAYERS)) {
                RoundIcon(Tool.LAYERS.symbol, Modifier.padding(end = 12.dp).padding(bottom = 0.dp)) { onLayers() }
            }
            CompareButton(model)
        }
    }
}

@Composable
private fun RoundIcon(symbol: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)).tap(onClick = onClick), contentAlignment = Alignment.Center) {
        Icon(sym(symbol), null, tint = Color.White, modifier = Modifier.size(18.dp))
    }
}

/** 按住看修改前的样子。 */
@Composable
fun CompareButton(model: EditorModel) {
    Box(
        Modifier.padding(12.dp).size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)).alpha(if (model.isLoading) 0f else 1f)
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val e = awaitPointerEvent()
                        val pressed = e.changes.any { it.pressed }
                        if (pressed != model.comparing) model.comparing = pressed
                        e.changes.forEach { it.consume() }
                    }
                }
            },
        contentAlignment = Alignment.Center,
    ) { Icon(sym("square.split.2x1"), "对比", tint = Color.White, modifier = Modifier.size(18.dp)) }
}

@Composable
private fun Bottom(model: EditorModel, tab: MainTab, embedded: Boolean, onTab: (MainTab) -> Unit, onEntry: (MenuAction) -> Unit) {
    val s = model.session
    if (s != null) {
        Column(Modifier.fillMaxWidth().background(Theme.panel)) {
            s.Panel()
            Row(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(52.dp, 48.dp).tap { model.cancelTool() }, contentAlignment = Alignment.Center) {
                    Icon(sym("xmark"), "取消", tint = Color.White)
                }
                Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    CompositionLocalProvider(LocalContentColor provides Color.White) { s.Title() }
                }
                Box(Modifier.size(52.dp, 48.dp).tap { model.commitTool() }, contentAlignment = Alignment.Center) {
                    Icon(sym("checkmark"), "确定", tint = Color.White)
                }
            }
        }
    } else {
        MainMenu(tab, onTab, onEntry, embedded)
    }
}

/** 没有打开任何工具时的底部：上面是当前一级菜单的二级入口，下面是一级菜单。 */
@Composable
private fun MainMenu(tab: MainTab, onTab: (MainTab) -> Unit, onEntry: (MenuAction) -> Unit, embedded: Boolean = false) {
    val tabs = MainTab.entries.filter { it.directTool != null || it.entries().isNotEmpty() }
    Column(Modifier.fillMaxWidth().background(Theme.panel)) {
        key(tab) {
            Row(
                Modifier.fillMaxWidth().height(92.dp).horizontalScroll(rememberScrollState()).padding(horizontal = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                // 单独编辑图层内容时不再提供"图层"入口
                val list = tab.entries().filter { !(embedded && (it.action as? MenuAction.OpenTool)?.tool == Tool.LAYERS) }
                for (e in list) IconTile(e.symbol, e.title, badge = e.badge) { onEntry(e.action) }
            }
        }
        Row(Modifier.fillMaxWidth().height(50.dp).padding(horizontal = 6.dp)) {
            for (item in tabs) {
                val on = item == tab
                Column(
                    Modifier.weight(1f).fillMaxHeight().tap { item.directTool?.let { onEntry(MenuAction.OpenTool(it)) } ?: onTab(item) },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    // 九个一级菜单在窄屏上放不下时字号自动缩小一点（iOS 的 minimumScaleFactor 0.8）
                    BasicText(
                        item.title, maxLines = 1, softWrap = false,
                        style = TextStyle(fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) Theme.accent else Color.White),
                        autoSize = TextAutoSize.StepBased(minFontSize = 12.sp, maxFontSize = 15.sp, stepSize = 0.5.sp),
                    )
                    Spacer(Modifier.height(6.dp))
                    Box(Modifier.size(18.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
                }
            }
        }
    }
}

/** 输入文字的浮层。 */
@Composable
fun TextInputOverlay(initial: String, placeholder: String, onDone: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.75f)).tap { onDone(text) }) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                Text("完成", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Theme.accent, modifier = Modifier.tap { onDone(text) })
            }
            TextField(
                value = text, onValueChange = { text = it },
                placeholder = { Text(placeholder, fontSize = 22.sp, color = Theme.dim, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth()) },
                textStyle = LocalTextStyle.current.copy(fontSize = 26.sp, fontWeight = FontWeight.SemiBold, color = Color.White, textAlign = TextAlign.Center),
                // 多行输入：回车换行（竖排就是换列），点"完成"结束。
                maxLines = 8,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Default),
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = Theme.accent,
                ),
                modifier = Modifier.fillMaxWidth().focusRequester(focus),
            )
        }
    }
}

/** 点"保存"后从底部出来的画质选择。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SaveSheet(model: EditorModel, onDismiss: () -> Unit, onSave: (SaveOptions) -> Unit) {
    val context = LocalContext.current
    var options by remember { mutableStateOf(SaveOptions.saved(context)) }
    var full by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    var history by remember { mutableStateOf(HistoryStore.enabled) }
    LaunchedEffect(Unit) { full = model.outputSize() }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Theme.panel) {
        Column(Modifier.padding(horizontal = 20.dp).padding(bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (item in SaveOptions.Size.entries) {
                    val on = options.size == item
                    Column(
                        Modifier.weight(1f).heightIn(min = 66.dp).clip(RoundedCornerShape(14.dp)).background(if (on) Theme.accent else Theme.chip)
                            .press { options = options.copy(size = item) },
                        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                    ) {
                        val fg = if (on) Color.Black else Color.White
                        Text(item.title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = fg)
                        Spacer(Modifier.height(6.dp))
                        val px = full?.let { options.copy(size = item).pixels(it) }
                        Text(px?.let { "${it.first} × ${it.second}" } ?: "…", fontSize = 11.sp, color = fg.copy(alpha = 0.65f))
                    }
                }
            }
            SegmentBar(SaveOptions.Format.entries, options.format, { it.title }) { options = options.copy(format = it) }
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(horizontal = 4.dp)) {
                Text("同时存入历史图库", fontSize = 15.sp, color = Color.White, modifier = Modifier.weight(1f))
                Switch(history, { history = it; HistoryStore.setEnabled(context, it) },
                    colors = SwitchDefaults.colors(checkedTrackColor = Theme.accent, checkedThumbColor = Color.White))
            }
            PillButton("保存到相册", Modifier.fillMaxWidth()) {
                SaveOptions.store(context, options)
                onSave(options)
            }
        }
    }
}
