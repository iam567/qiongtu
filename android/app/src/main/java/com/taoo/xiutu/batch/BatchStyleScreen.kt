package com.taoo.xiutu.batch

import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIMainButton
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.NeedsKeyView
import com.taoo.xiutu.ai.ProviderMenu
import com.taoo.xiutu.ai.outfit.OutfitSkirt
import com.taoo.xiutu.ai.outfit.WardrobeStore
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.picker.PhotoPickerScreen
import com.taoo.xiutu.settings.SettingsSheet
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.Toast
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import com.taoo.xiutu.ui.tapOrHold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.max
import kotlin.math.roundToInt

private val warnRed = Color(1f, 0.45f, 0.4f)
private val tileShape = RoundedCornerShape(10.dp)

/**
 * 统一风格：选一个存好的风格，导入一批照片，AI 一张张处理，出一张看一张，随时能停。styleID：进来就选这个风格。
 * outfitMode = 批量换衣服：换成衣橱里的一身，outfitID：进来就选这一身。
 */
@Composable
fun BatchStyleScreen(styleID: String?, outfitMode: Boolean = false, outfitID: String? = null, onClose: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val model = remember {
        BatchStyleModel(context.applicationContext).also { m ->
            StyleStore.styles.firstOrNull { it.id == styleID }?.let { m.style = it }
            m.outfitMode = outfitMode
            if (outfitMode) m.outfit = WardrobeStore.items.firstOrNull { it.id == outfitID } ?: WardrobeStore.items.firstOrNull()
        }
    }
    var picking by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    var comparing by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf<SavedStyle?>(null) }
    var toast by remember { mutableStateOf<String?>(null) }
    DisposableEffect(Unit) { onDispose { model.dispose() } }

    fun show(message: String) {
        toast = message
        scope.launch {
            delay(2000)
            if (toast == message) toast = null
        }
    }

    val stylePicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            val style = StyleStore.add { Img.decode(context, uri, StyleStore.SIDE) }
            if (style != null) model.style = style else show("保存失败")
        }
    }
    BackHandler(!picking) { onClose() }

    Box(Modifier.fillMaxSize().background(Theme.bg)) {
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            // 顶栏
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(44.dp).tap(onClick = onClose), contentAlignment = Alignment.Center) {
                    Icon(sym("chevron.left"), "返回", tint = Color.White)
                }
                Text(
                    if (outfitMode) "批量换衣服" else "统一风格", fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.White,
                    textAlign = TextAlign.Center, modifier = Modifier.weight(1f),
                )
                if (model.doneCount > 0) {
                    val enabled = !model.exporting && !model.running
                    Box(
                        Modifier.clip(CircleShape).background(if (enabled) Color.White else Color.White.copy(alpha = 0.4f)).tap(enabled) {
                            scope.launch {
                                val n = model.saveAll()
                                show(if (n > 0) "已保存 $n 张到相册" else "保存失败，请检查相册权限")
                            }
                        }.padding(horizontal = 14.dp, vertical = 8.dp),
                    ) {
                        Text(
                            if (model.exporting) "正在导出 ${model.exported + 1}/${model.doneCount}" else "全部保存",
                            fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black,
                        )
                    }
                } else {
                    Spacer(Modifier.size(44.dp))
                }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) { Preview(model, comparing, { comparing = it }) { picking = true } }
            Column(
                Modifier.fillMaxWidth().background(Theme.panel).padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                model.error?.let { Text(it, fontSize = 12.sp, lineHeight = 17.sp, color = warnRed, modifier = Modifier.fillMaxWidth()) }
                if (outfitMode) ClothesRow(model) else StyleRow(
                    model,
                    onAdd = { stylePicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                    onRename = { renaming = it },
                )
                PhotoRow(model) { picking = true }
                if (!outfitMode && model.doneCount > 0) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("强度", fontSize = 13.sp, color = Theme.dim)
                        XSlider(model.strength, { model.changeStrength(it) }, 0f..1f, Modifier.weight(1f), onFinished = { model.finishStrength() })
                        Text(
                            "${(model.strength * 100).roundToInt()}", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
                            textAlign = TextAlign.End, modifier = Modifier.width(34.dp),
                        )
                    }
                }
                if (!AISettings.isConfigured(AISettings.active)) NeedsKeyView { showSettings = true }
                else Actions(model) { showSettings = true }
                if (model.spent > 0) {
                    Text("已花费约 $" + String.format(Locale.US, "%.2f", model.spent), fontSize = 11.sp, color = Theme.accent, modifier = Modifier.fillMaxWidth())
                }
            }
        }
        toast?.let { Toast(it, Modifier.align(Alignment.BottomCenter).padding(bottom = 290.dp)) }
        if (picking) {
            BackHandler { picking = false }
            PhotoPickerScreen(
                onPick = {}, onClose = { picking = false }, limit = 60,
                onPickMany = { list -> picking = false; model.add(list) },
            )
        }
    }
    if (showSettings) SettingsSheet(onDismiss = { showSettings = false })
    renaming?.let { style -> NameDialog("风格的名字", style.name, onDismiss = { renaming = null }) { StyleStore.rename(style, it) } }
}

/** 改名的小窗。 */
@Composable
internal fun NameDialog(title: String, initial: String, onDismiss: () -> Unit, onDone: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = {
            TextField(
                name, { name = it }, singleLine = true,
                colors = TextFieldDefaults.colors(
                    focusedContainerColor = Theme.chip, unfocusedContainerColor = Theme.chip,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent, cursorColor = Theme.accent,
                ),
                shape = RoundedCornerShape(12.dp),
            )
        },
        confirmButton = { TextButton({ onDone(name); onDismiss() }) { Text("好", color = Color.White) } },
        dismissButton = { TextButton(onDismiss) { Text("取消", color = Color.White) } },
        containerColor = Theme.panel,
    )
}

@Composable
private fun Preview(model: BatchStyleModel, comparing: Boolean, onCompare: (Boolean) -> Unit, onAdd: () -> Unit) {
    val item = model.current
    if (item == null) {
        Column(
            Modifier.fillMaxSize().tap(onClick = onAdd), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
        ) {
            Icon(sym("photo.on.rectangle.angled"), null, tint = Theme.dim, modifier = Modifier.size(50.dp))
            Spacer(Modifier.height(14.dp))
            Text("添加照片", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Theme.dim)
        }
        return
    }
    Box(Modifier.fillMaxSize()) {
        val shown = if (comparing) item.preview else item.result ?: item.preview
        if (shown != null) {
            val image = remember(shown) { shown.asImageBitmap() }
            Image(image, null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 10.dp))
        }
        if (item.status == BatchStyleModel.Status.RUNNING) {
            Row(
                Modifier.align(Alignment.BottomCenter).padding(bottom = 22.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.65f))
                    .padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Text("正在处理…", fontSize = 13.sp, color = Color.White)
            }
        }
        if (item.result != null) {
            // 按住看原图
            Box(
                Modifier.align(Alignment.BottomEnd).padding(14.dp).size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f))
                    .pointerInput(Unit) {
                        awaitPointerEventScope {
                            while (true) {
                                val e = awaitPointerEvent()
                                onCompare(e.changes.any { it.pressed })
                                e.changes.forEach { it.consume() }
                            }
                        }
                    },
                contentAlignment = Alignment.Center,
            ) { Icon(sym("square.split.2x1"), "对比", tint = Color.White, modifier = Modifier.size(18.dp)) }
        }
    }
}

@Composable
private fun StyleRow(model: BatchStyleModel, onAdd: () -> Unit, onRename: (SavedStyle) -> Unit) {
    Row(
        Modifier.alpha(if (model.running) 0.4f else 1f).horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
    ) {
        Tile("添加风格", selected = false, onClick = { if (!model.running) onAdd() }) {
            Icon(sym("plus"), null, tint = Color.White, modifier = Modifier.align(Alignment.Center).size(22.dp))
        }
        for (style in StyleStore.styles) key(style.id) {
            var menu by remember { mutableStateOf(false) }
            val image by produceState<Bitmap?>(null, style.id) { value = withContext(Dispatchers.IO) { StyleStore.image(style)?.let { Img.thumb(it, 200, 1f) } } }
            Tile(
                style.name, selected = model.style?.id == style.id, image = image,
                onClick = { if (!model.running) model.style = style }, onHold = { if (!model.running) menu = true },
            ) {
                DropdownMenu(menu, { menu = false }, containerColor = Theme.chip) {
                    DropdownMenuItem(text = { Text("改名", color = Color.White) }, onClick = { menu = false; onRename(style) })
                    DropdownMenuItem(text = { Text("删除", color = Theme.red) }, onClick = {
                        menu = false
                        StyleStore.remove(style)
                        if (model.style?.id == style.id) model.style = StyleStore.styles.firstOrNull()
                    })
                }
            }
        }
    }
}

/** 选衣橱里的一身、裙摆。 */
@Composable
private fun ClothesRow(model: BatchStyleModel) {
    Column(Modifier.alpha(if (model.running) 0.4f else 1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (WardrobeStore.items.isEmpty()) {
            Text("衣橱是空的，先在 AI 修图的换衣服里存一身", fontSize = 13.sp, color = warnRed, modifier = Modifier.fillMaxWidth())
        } else {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                for (item in WardrobeStore.items) key(item.id) {
                    val image by produceState<Bitmap?>(null, item.id) { value = withContext(Dispatchers.IO) { WardrobeStore.image(item)?.let { Img.thumb(it, 200, 1f) } } }
                    Tile(item.name, selected = model.outfit?.id == item.id, image = image, onClick = { if (!model.running) model.outfit = item }) {}
                }
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (k in OutfitSkirt.entries) Chip("裙摆 " + k.title, selected = model.skirt == k) { if (!model.running) model.skirt = k }
        }
    }
}

@Composable
private fun PhotoRow(model: BatchStyleModel, onAdd: () -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.Top,
    ) {
        Tile("添加照片", selected = false, background = Theme.accent, onClick = { if (!model.running) onAdd() }) {
            Icon(sym("plus"), null, tint = Color.Black, modifier = Modifier.align(Alignment.Center).size(22.dp))
        }
        for (item in model.items) key(item.id) {
            var menu by remember { mutableStateOf(false) }
            Tile(
                item.name, selected = model.selected == item.id, image = item.result ?: item.preview,
                onClick = { model.selected = item.id }, onHold = { if (!model.running) menu = true },
            ) {
                StatusBadge(item.status, Modifier.align(Alignment.TopEnd).padding(5.dp))
                DropdownMenu(menu, { menu = false }, containerColor = Theme.chip) {
                    if (item.status == BatchStyleModel.Status.DONE || item.status == BatchStyleModel.Status.FAILED) {
                        DropdownMenuItem(text = { Text("重做这一张", color = Color.White) }, trailingIcon = { CornerBadge("AI") }, onClick = { menu = false; model.redo(item.id) })
                    }
                    DropdownMenuItem(text = { Text("移除", color = Theme.red) }, onClick = { menu = false; model.remove(item.id) })
                }
            }
        }
    }
}

@Composable
private fun StatusBadge(status: BatchStyleModel.Status, modifier: Modifier) {
    when (status) {
        BatchStyleModel.Status.PENDING -> {}
        BatchStyleModel.Status.RUNNING -> Box(modifier.clip(CircleShape).background(Color.Black.copy(alpha = 0.6f)).padding(4.dp)) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 1.5.dp, modifier = Modifier.size(11.dp))
        }
        BatchStyleModel.Status.DONE ->
            Icon(sym("checkmark.circle.fill"), null, tint = Theme.accent, modifier = modifier.clip(CircleShape).background(Color.Black).size(17.dp))
        BatchStyleModel.Status.FAILED ->
            Icon(sym("exclamationmark.circle.fill"), null, tint = warnRed, modifier = modifier.clip(CircleShape).background(Color.Black).size(17.dp))
    }
}

@Composable
private fun Tile(
    title: String, selected: Boolean, image: Bitmap? = null, background: Color = Theme.chip,
    onClick: () -> Unit, onHold: () -> Unit = {}, content: @Composable BoxScope.() -> Unit,
) {
    Column(Modifier.width(66.dp).tapOrHold(onClick, onHold), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(
            Modifier.size(66.dp).clip(tileShape).background(background)
                .then(if (selected) Modifier.border(2.5.dp, Theme.accent, tileShape) else Modifier),
        ) {
            if (image != null) {
                val ib = remember(image) { image.asImageBitmap() }
                Image(ib, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().padding(if (selected) 2.5.dp else 0.dp).clip(tileShape))
            }
            content()
        }
        Text(
            title, fontSize = 11.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Theme.accent else Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun Actions(model: BatchStyleModel, openSettings: () -> Unit) {
    if (model.running) {
        val begin = model.started
        val seconds by produceState(0, begin) {
            while (true) {
                value = max(0, ((System.currentTimeMillis() - begin) / 1000).toInt())
                delay(1000)
            }
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
            Text("第 ${model.runningIndex.coerceAtLeast(0) + 1} / ${model.items.size} 张 · $seconds 秒", fontSize = 14.sp, color = Color.White)
            Spacer(Modifier.weight(1f))
            Box(
                Modifier.height(38.dp).clip(CircleShape).background(Color(0.85f, 0.28f, 0.25f)).press { model.stop() }.padding(horizontal = 22.dp),
                contentAlignment = Alignment.Center,
            ) { Text("停止", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.White) }
        }
        return
    }
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) { ProviderMenu(openSettings, compact = true) }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        val item = model.current
        if (item != null && (item.status == BatchStyleModel.Status.DONE || item.status == BatchStyleModel.Status.FAILED)) {
            Box(Modifier.weight(1f).alpha(if (model.ready) 1f else 0.4f)) {
                Box(
                    Modifier.fillMaxWidth().height(42.dp).clip(CircleShape).background(Theme.chip).press(model.ready) { model.redo(item.id) },
                    contentAlignment = Alignment.Center,
                ) { Text("重做这一张", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
                CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = (-6).dp, y = (-5).dp))
            }
        }
        if (model.remaining > 0 || model.items.isEmpty()) {
            AIMainButton(
                if (model.doneCount > 0) "继续处理 ${model.remaining} 张" else "开始处理 ${model.remaining} 张", Modifier.weight(1f),
                enabled = model.ready && model.remaining > 0,
            ) { model.start() }
        }
    }
}
