package com.taoo.xiutu.history

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.taoo.xiutu.batch.StyleStore
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.editor.ZoomableCanvas
import com.taoo.xiutu.tools.beauty.FavoriteFaceStore
import com.taoo.xiutu.ui.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private val warnRed = Color(1f, 0.45f, 0.4f)

/** 历史图库：App 里留的那份图。可以设密码、批量删除、一键清空。onApply：把某张图的处理步骤套到一张新照片上。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    onEdit: (File) -> Unit,
    onApply: (String) -> Unit,
    /** 存成风格，接着批量处理照片。 */
    onBatch: (String) -> Unit = {},
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val store = HistoryStore
    var unlocked by remember { mutableStateOf(!store.hasPassword) }
    var selecting by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var viewing by remember { mutableStateOf<HistoryItem?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var confirmClear by remember { mutableStateOf(false) }
    var settingPassword by remember { mutableStateOf(false) }
    var menuOpen by remember { mutableStateOf(false) }
    var toast by remember { mutableStateOf<String?>(null) }

    fun show(message: String) {
        toast = message
        scope.launch {
            delay(2000)
            if (toast == message) toast = null
        }
    }

    fun saveStyle(item: HistoryItem, batch: Boolean) {
        scope.launch {
            val style = StyleStore.add(store.file(item))
            if (style == null) show("保存失败") else if (batch) onBatch(style.id) else show("已保存此风格")
        }
    }

    // 离开 App 再回来要重新输密码
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_STOP && store.hasPassword) {
                unlocked = false
                viewing = null
                selecting = false
                selected = emptySet()
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs) }
    }

    BackHandler(viewing == null) { onClose() }

    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding()) {
            Column(Modifier.fillMaxSize()) {
                // 顶栏
                Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(44.dp).tap(onClick = onClose), contentAlignment = Alignment.Center) {
                        Icon(sym("chevron.left"), "返回", tint = Color.White)
                    }
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Text(if (selecting) "已选 ${selected.size} 张" else "历史图库", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    }
                    if (unlocked) {
                        if (store.items.isNotEmpty()) {
                            Box(Modifier.height(44.dp).padding(horizontal = 6.dp).tap { selecting = !selecting; selected = emptySet() }, contentAlignment = Alignment.Center) {
                                Text(if (selecting) "完成" else "选择", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                            }
                        }
                        Box {
                            Box(Modifier.size(44.dp).tap { menuOpen = true }, contentAlignment = Alignment.Center) {
                                Icon(sym("ellipsis.circle"), "更多", tint = Color.White)
                            }
                            DropdownMenu(menuOpen, { menuOpen = false }, containerColor = Theme.chip) {
                                DropdownMenuItem(
                                    text = { Text("保存时存入历史图库", color = Color.White) },
                                    leadingIcon = { if (store.enabled) Icon(sym("checkmark"), null, tint = Color.White) else Spacer(Modifier.size(24.dp)) },
                                    onClick = { store.setEnabled(context, !store.enabled); menuOpen = false },
                                )
                                DropdownMenuItem(
                                    text = { Text(if (store.hasPassword) "修改密码" else "设置密码", color = Color.White) },
                                    onClick = { menuOpen = false; settingPassword = true },
                                )
                                if (store.hasPassword) {
                                    DropdownMenuItem(text = { Text("关闭密码", color = Color.White) }, onClick = { menuOpen = false; store.removePassword() })
                                }
                                if (store.items.isNotEmpty()) {
                                    HorizontalDivider(color = Color.White.copy(alpha = 0.12f))
                                    DropdownMenuItem(text = { Text("清空图库", color = Theme.red) }, onClick = { menuOpen = false; confirmClear = true })
                                }
                            }
                        }
                    } else {
                        Spacer(Modifier.size(44.dp))
                    }
                }
                when {
                    !unlocked -> HistoryLock(onUnlock = { unlocked = true })
                    store.items.isEmpty() -> Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                        Text("还没有图片", color = Theme.dim)
                    }
                    else -> {
                        LazyVerticalGrid(
                            GridCells.Fixed(3), Modifier.weight(1f).fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp),
                            contentPadding = PaddingValues(bottom = 20.dp),
                        ) {
                            items(store.items, key = { it.id }) { item ->
                                HistoryCell(item, selecting, item.id in selected, onStyle = { batch -> saveStyle(item, batch) }) {
                                    if (selecting) selected = if (item.id in selected) selected - item.id else selected + item.id
                                    else viewing = item
                                }
                            }
                        }
                        if (selecting) {
                            val all = selected.size == store.items.size
                            Row(
                                Modifier.fillMaxWidth().height(56.dp).background(Theme.panel).padding(horizontal = 20.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(if (all) "取消全选" else "全选", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                                    modifier = Modifier.tap { selected = if (all) emptySet() else store.items.map { it.id }.toSet() })
                                Spacer(Modifier.weight(1f))
                                BarButton("square.and.arrow.down", "存到相册", Color.White, selected.isNotEmpty()) {
                                    val ids = selected
                                    scope.launch {
                                        val list = store.items.filter { it.id in ids }
                                        val saved = withContext(Dispatchers.IO) { list.count { store.saveToGallery(context, it) } }
                                        show(if (saved == list.size) "已存到相册 $saved 张" else "存了 $saved 张，${list.size - saved} 张失败")
                                    }
                                }
                                Spacer(Modifier.weight(1f))
                                BarButton("trash", "删除", Theme.red, selected.isNotEmpty()) { confirmDelete = true }
                            }
                        }
                    }
                }
            }
            toast?.let { Toast(it, Modifier.align(Alignment.BottomCenter).padding(bottom = 90.dp)) }
        }
        // 看大图盖在整页上面
        viewing?.let { item ->
            HistoryViewer(
                item, onEdit = { f -> viewing = null; onEdit(f) }, onApply = { viewing = null; onApply(item.id) },
                onClose = { viewing = null },
            )
        }
    }
    if (settingPassword) HistoryPasswordSheet { settingPassword = false }
    if (confirmDelete) {
        ConfirmDialog("删除选中的 ${selected.size} 张？", "删除", onDismiss = { confirmDelete = false }) {
            store.delete(selected)
            selected = emptySet()
            selecting = false
        }
    }
    if (confirmClear) {
        ConfirmDialog("清空历史图库？共 ${store.items.size} 张，删了找不回来。", "全部删除", onDismiss = { confirmClear = false }) {
            store.clear()
            selected = emptySet()
            selecting = false
        }
    }
}

@Composable
private fun BarButton(symbol: String, title: String, color: Color, enabled: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.alpha(if (enabled) 1f else 0.35f).tap(enabled, onClick),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(sym(symbol), null, tint = color, modifier = Modifier.size(18.dp))
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = color)
    }
}

/** 确认删除这类不可撤回的操作。 */
@Composable
private fun ConfirmDialog(title: String, action: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        text = { Text(title, fontSize = 15.sp, color = Color.White) },
        confirmButton = { TextButton({ onDismiss(); onConfirm() }) { Text(action, color = Theme.red) } },
        dismissButton = { TextButton(onDismiss) { Text("取消", color = Color.White) } },
        containerColor = Theme.panel,
    )
}

/** 图库里的一格。 */
@Composable
private fun HistoryCell(item: HistoryItem, selecting: Boolean, selected: Boolean, onStyle: (Boolean) -> Unit, onClick: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    var image by remember(item.id) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(item.id) { image = HistoryStore.thumbnail(item) }
    Box(Modifier.aspectRatio(1f).background(Color(0.12f, 0.12f, 0.12f)).tapOrHold(onClick) { menu = true }) {
        DropdownMenu(menu, { menu = false }, containerColor = Theme.chip) {
            DropdownMenuItem(text = { Text("保存此风格", color = Color.White) }, onClick = { menu = false; onStyle(false) })
            DropdownMenuItem(text = { Text("用此风格批量处理…", color = Color.White) }, onClick = { menu = false; onStyle(true) })
        }
        image?.let {
            val ib = remember(it) { it.asImageBitmap() }
            Image(ib, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        }
        Text(
            item.source, fontSize = 10.sp, fontWeight = FontWeight.Medium, color = Color.White, lineHeight = 12.sp,
            modifier = Modifier.align(Alignment.BottomStart).padding(4.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape)
                .padding(horizontal = 5.dp, vertical = 2.dp),
        )
        if (selected) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.25f)))
        if (selecting) {
            Icon(
                sym(if (selected) "checkmark.circle.fill" else "circle"), null,
                tint = if (selected) Theme.accent else Color.White,
                modifier = Modifier.align(Alignment.TopEnd).padding(5.dp).size(22.dp).shadow(2.dp, CircleShape, clip = false),
            )
        }
    }
}

/** 输密码才能进。 */
@Composable
private fun ColumnScope.HistoryLock(onUnlock: () -> Unit) {
    val store = HistoryStore
    var password by remember { mutableStateOf("") }
    var wrong by remember { mutableStateOf(false) }
    var confirmReset by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }

    fun unlock() {
        if (store.check(password)) onUnlock() else { wrong = true; password = "" }
    }

    Column(Modifier.weight(1f).fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Icon(sym("lock.fill"), null, tint = Theme.accent, modifier = Modifier.size(38.dp))
        Spacer(Modifier.height(18.dp))
        PasswordField(password, { password = it }, "密码", Modifier.padding(horizontal = 60.dp).focusRequester(focus), center = true, onDone = ::unlock)
        if (wrong) {
            Spacer(Modifier.height(18.dp))
            Text("密码不对", fontSize = 13.sp, color = warnRed)
        }
        Spacer(Modifier.height(18.dp))
        Box(
            Modifier.size(160.dp, 44.dp).clip(CircleShape).background(Color.White).press(onClick = ::unlock),
            contentAlignment = Alignment.Center,
        ) { Text("解锁", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
        Spacer(Modifier.height(18.dp))
        Text("忘记密码", fontSize = 13.sp, color = Theme.dim, modifier = Modifier.tap { confirmReset = true })
        Spacer(Modifier.weight(2f))
    }
    if (confirmReset) {
        ConfirmDialog("忘记密码只能清空图库后重设。图库里的 ${store.items.size} 张会全部删除，找不回来。", "清空图库并去掉密码", onDismiss = { confirmReset = false }) {
            store.clear()
            store.removePassword()
            onUnlock()
        }
    }
}

@Composable
private fun PasswordField(value: String, onChange: (String) -> Unit, placeholder: String, modifier: Modifier = Modifier, center: Boolean = false, onDone: () -> Unit = {}) {
    val align = if (center) TextAlign.Center else TextAlign.Start
    TextField(
        value = value, onValueChange = onChange, singleLine = true,
        placeholder = { Text(placeholder, color = Theme.dim, textAlign = align, modifier = Modifier.fillMaxWidth(), fontSize = if (center) 18.sp else 17.sp) },
        textStyle = LocalTextStyle.current.copy(fontSize = if (center) 18.sp else 17.sp, color = Color.White, textAlign = align),
        visualTransformation = PasswordVisualTransformation(),
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, imeAction = ImeAction.Done),
        keyboardActions = KeyboardActions(onDone = { onDone() }),
        shape = RoundedCornerShape(12.dp),
        colors = TextFieldDefaults.colors(
            focusedContainerColor = Theme.chip, unfocusedContainerColor = Theme.chip,
            focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = Theme.accent,
        ),
        modifier = modifier.fillMaxWidth(),
    )
}

/** 设置 / 修改密码。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistoryPasswordSheet(onDismiss: () -> Unit) {
    var first by remember { mutableStateOf("") }
    var second by remember { mutableStateOf("") }
    var mismatch by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Theme.panel) {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp, bottom = 24.dp).imePadding(),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(if (HistoryStore.hasPassword) "修改密码" else "设置密码", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White)
            PasswordField(first, { first = it }, "新密码")
            PasswordField(second, { second = it }, "再输一次")
            if (mismatch) Text("两次输入不一样", fontSize = 13.sp, color = warnRed)
            PillButton("确定", Modifier.fillMaxWidth(), enabled = first.isNotEmpty()) {
                if (first == second) {
                    HistoryStore.setPassword(first)
                    onDismiss()
                } else {
                    mismatch = true
                }
            }
        }
    }
}

/** 看大图：可以继续编辑、存到相册、分享、删除。 */
@Composable
private fun HistoryViewer(item: HistoryItem, onEdit: (File) -> Unit, onApply: () -> Unit, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val file = remember(item.id) { HistoryStore.file(item) }
    var image by remember(item.id) { mutableStateOf<Bitmap?>(null) }
    var recipe by remember(item.id) { mutableStateOf<com.taoo.xiutu.editor.EditRecipe?>(null) }
    var showSteps by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(item.id) {
        recipe = withContext(Dispatchers.IO) { HistoryStore.recipe(item.id) }
        image = withContext(Dispatchers.IO) { Img.decode(file, 2400) }
    }
    BackHandler(onBack = onClose)
    val stamp = remember(item.date) { SimpleDateFormat("yyyy/M/d HH:mm", Locale.getDefault()).format(Date(item.date)) }

    Box(Modifier.fillMaxSize().background(Color.Black).tap {}.systemBarsPadding()) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(44.dp).tap(onClick = onClose), contentAlignment = Alignment.Center) {
                    Icon(sym("xmark"), "关闭", tint = Color.White)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(item.source, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Text("$stamp · ${item.width} × ${item.height}", fontSize = 11.sp, color = Theme.dim)
                }
                Spacer(Modifier.size(44.dp))
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { ZoomableCanvas(image) }
            note?.let { Text(it, fontSize = 13.sp, color = Theme.accent, modifier = Modifier.align(Alignment.CenterHorizontally).padding(bottom = 4.dp)) }
            Row(
                Modifier.fillMaxWidth().background(Theme.panel).padding(vertical = 10.dp),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                IconTile("slider.horizontal.3", "编辑") { onEdit(file) }
                if (recipe != null) IconTile("list.number", "步骤") { showSteps = true }
                IconTile("square.and.arrow.down", "存到相册") {
                    scope.launch {
                        val ok = withContext(Dispatchers.IO) { HistoryStore.saveToGallery(context, item) }
                        note = if (ok) "已存到相册" else "保存失败，请检查相册权限"
                    }
                }
                IconTile("square.and.arrow.up", "分享") { share(context, item, file) }
                IconTile("star", "满意脸型") {
                    scope.launch {
                        val data = withContext(Dispatchers.IO) { runCatching { file.readBytes() }.getOrNull() }
                        val ok = data != null && FavoriteFaceStore.add(context, data)
                        note = if (ok) "已设为满意脸型" else "这张图里没有找到人脸"
                    }
                }
                IconTile("trash", "删除") { confirmDelete = true }
            }
        }
    }
    recipe?.let { r ->
        if (showSteps) RecipeSheet(r, onDismiss = { showSteps = false }) { showSteps = false; onApply() }
    }
    if (confirmDelete) {
        ConfirmDialog("删除这张？", "删除", onDismiss = { confirmDelete = false }) {
            HistoryStore.delete(setOf(item.id))
            onClose()
        }
    }
}

/** 用系统分享面板分享原文件。 */
private fun share(context: Context, item: HistoryItem, file: File) {
    runCatching {
        val uri = FileProvider.getUriForFile(context, context.packageName + ".files", file)
        val mime = when (item.ext.lowercase()) {
            "png" -> "image/png"
            "heic", "heif" -> "image/heic"
            else -> "image/jpeg"
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = mime
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(send, null).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
