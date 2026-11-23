package com.taoo.xiutu.tools.overlay

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs
import kotlin.math.roundToInt

private enum class TextTab(val title: String) {
    PRESET("花字"), FONT("字体"), COLOR("颜色"), STROKE("描边"), SHADOW("阴影"), BOX("底色"), GLOW("发光"), LAYOUT("排版"),
}

/** 出错时的红字。 */
internal val problemColor = Color(1f, 0.45f, 0.4f)

/**
 * 文字面板：上面一排是"加文字"和各类设置的标签，下面是当前标签的内容。
 * 所有设置都作用在画面上选中的那段文字上，可以随意组合。
 */
@Composable
fun TextPanel(s: OverlaySession) {
    var tab by remember { mutableStateOf(TextTab.PRESET) }
    var fontCategory by remember { mutableStateOf(FontCategory.COMMON) }
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isEmpty()) return@rememberLauncherForActivityResult
        scope.launch {
            // 字体文件可能很大，读写放到后台
            val font = withContext(Dispatchers.IO) { FontStore.importFonts(context, uris) }
            if (font != null) {
                fontCategory = FontCategory.MINE
                s.change { it.copy(fontID = font.id) }
            }
        }
    }
    val selected = s.selected?.takeIf { !it.isSticker }
    Column(Modifier.fillMaxWidth().padding(top = 14.dp, bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(Modifier.padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                Modifier.clip(CircleShape).background(Theme.accent).press { s.addText() }.padding(horizontal = 12.dp, vertical = 7.dp),
                verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Icon(sym("plus"), null, tint = Color.Black, modifier = Modifier.size(14.dp))
                Text("文字", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.Black)
            }
            Box(Modifier.weight(1f)) {
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(end = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(18.dp),
                ) {
                    for (item in TextTab.entries) {
                        val on = tab == item
                        Column(Modifier.tap { tab = item }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text(item.title, fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) Color.White else Theme.dim, maxLines = 1)
                            Box(Modifier.size(16.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
                        }
                    }
                }
            }
        }
        Box(Modifier.fillMaxWidth().height(128.dp)) {
            if (selected != null) {
                Content(s, tab, selected, fontCategory, { fontCategory = it }) {
                    importer.launch(arrayOf("font/*", "application/x-font-ttf", "application/x-font-otf", "application/font-sfnt", "application/vnd.ms-opentype", "application/octet-stream"))
                }
            }
        }
    }
}

@Composable
private fun Content(
    s: OverlaySession, tab: TextTab, item: OverlayItem,
    category: FontCategory, onCategory: (FontCategory) -> Unit, onImport: () -> Unit,
) {
    val pad = Modifier.padding(horizontal = 16.dp)
    when (tab) {
        TextTab.PRESET -> Presets(s, item)
        TextTab.FONT -> FontPicker(s, item, category, onCategory, onImport)
        TextTab.COLOR -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OverlayColorRow(item.color) { c -> if (c != null) s.change { it.copy(color = c) } }
            MiniSlider("不透明度", item.opacity, 0.1f..1f, pad, labelWidth = 56.dp) { v -> s.change { it.copy(opacity = v) } }
        }
        TextTab.STROKE -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OverlayColorRow(if (item.strokeOn) item.strokeColor else null, allowsNone = true) { c ->
                s.change { if (c != null) it.copy(strokeOn = true, strokeColor = c) else it.copy(strokeOn = false) }
            }
            MiniSlider("粗细", item.strokeWidth, 0.05f..1f, pad) { v -> s.change { it.copy(strokeOn = true, strokeWidth = v) } }
        }
        TextTab.SHADOW -> Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            OverlayColorRow(if (item.shadowOn) item.shadowColor else null, allowsNone = true) { c ->
                s.change { if (c != null) it.copy(shadowOn = true, shadowColor = c) else it.copy(shadowOn = false) }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("虚实", item.shadowBlur, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowBlur = v) } }
                MiniSlider("距离", item.shadowDistance, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowDistance = v) } }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("角度", item.shadowAngle, 0f..360f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowAngle = v) } }
                MiniSlider("浓度", item.shadowOpacity, 0.1f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(shadowOn = true, shadowOpacity = v) } }
            }
        }
        TextTab.BOX -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OverlayColorRow(if (item.boxOn) item.boxColor else null, allowsNone = true) { c ->
                s.change { if (c != null) it.copy(boxOn = true, boxColor = c) else it.copy(boxOn = false) }
            }
            EdgeRow {
                for (shape in OverlayShape.entries) {
                    val on = item.boxOn && item.boxShape == shape
                    Box(Modifier.press { s.change { it.copy(boxOn = true, boxShape = shape) } }) {
                        OverlayThumb("shape-${shape.name}", 54.dp, 36.dp, selected = on, fontSize = 15f) {
                            OverlayItem(text = "字", color = OverlayColor.black, boxOn = true, boxColor = OverlayColor.white, boxShape = shape)
                        }
                    }
                }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("浓度", item.boxOpacity, 0.1f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(boxOn = true, boxOpacity = v) } }
                MiniSlider("留白", item.boxPadding, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(boxOn = true, boxPadding = v) } }
            }
        }
        TextTab.GLOW -> Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OverlayColorRow(if (item.glowOn) item.glowColor else null, allowsNone = true) { c ->
                s.change { if (c != null) it.copy(glowOn = true, glowColor = c) else it.copy(glowOn = false) }
            }
            Row(pad, horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("大小", item.glowSize, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(glowOn = true, glowSize = v) } }
                MiniSlider("强度", item.glowStrength, 0f..1f, Modifier.weight(1f)) { v -> s.change { it.copy(glowOn = true, glowStrength = v) } }
            }
        }
        TextTab.LAYOUT -> Column(pad, verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                TextToggle("竖排", item.vertical) {
                    s.change {
                        // 框拉过的长度横竖不通用，换方向就重来；竖排一列太长的，先按一列 8 个字排。
                        val v = !it.vertical
                        val longest = it.text.split("\n").maxOfOrNull { l -> l.length } ?: 0
                        it.copy(vertical = v, wrap = if (v && longest > 10) 8.3f else 0f)
                    }
                }
                Box(Modifier.size(1.dp, 20.dp).background(Theme.chip))
                for (a in OverlayAlign.entries) Toggle(a.symbol, item.align == a) { s.change { it.copy(align = a) } }
                Box(Modifier.size(1.dp, 20.dp).background(Theme.chip))
                Toggle("bold", item.bold) { s.change { it.copy(bold = !it.bold) } }
                Toggle("italic", item.italic) { s.change { it.copy(italic = !it.italic) } }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                MiniSlider("字距", item.letterSpacing, -0.05f..0.8f, Modifier.weight(1f)) { v ->
                    s.change { it.copy(letterSpacing = if (abs(v) < 0.02f) 0f else v) }
                }
                MiniSlider("行距", item.lineSpacing, -0.2f..1f, Modifier.weight(1f)) { v ->
                    s.change { it.copy(lineSpacing = if (abs(v) < 0.03f) 0f else v) }
                }
            }
            MiniSlider("大小", item.scale, 0.3f..5f) { v -> s.change { it.copy(scale = v) } }
        }
    }
}

/** 和 Toggle 一样大的开关，但写字（"竖排"用图标说不清）。 */
@Composable
private fun TextToggle(title: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(50.dp, 34.dp).clip(RoundedCornerShape(9.dp)).background(if (on) Color.White else Theme.chip).tap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(title, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = if (on) Color.Black else Color.White, maxLines = 1) }
}

@Composable
private fun Toggle(symbol: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(44.dp, 34.dp).clip(RoundedCornerShape(9.dp)).background(if (on) Color.White else Theme.chip).tap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Icon(sym(symbol), null, tint = if (on) Color.Black else Color.White, modifier = Modifier.size(18.dp)) }
}

// MARK: 花字

@Composable
private fun Presets(s: OverlaySession, item: OverlayItem) {
    EdgeRow(spacing = 10.dp, verticalAlignment = Alignment.Top) {
        for (preset in OverlayPreset.all) {
            Column(
                Modifier.press { s.change { preset.applied(it) } },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                OverlayThumb("preset-${preset.id}-${item.fontID}-${item.bold}-${item.italic}", 72.dp, 60.dp) {
                    preset.applied(OverlayItem(text = "字", fontID = item.fontID, bold = item.bold, italic = item.italic))
                }
                Text(preset.title, fontSize = 12.sp, color = Color.White, maxLines = 1)
            }
        }
    }
}

// MARK: 字体

@Composable
private fun FontPicker(s: OverlaySession, item: OverlayItem, category: FontCategory, onCategory: (FontCategory) -> Unit, onImport: () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (c in FontCategory.entries) {
                val on = category == c
                Text(
                    c.title, fontSize = 13.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (on) Theme.accent else Color.White,
                    modifier = Modifier.clip(CircleShape).background(if (on) Theme.chip else Color.Transparent)
                        .tap { onCategory(c) }.padding(horizontal = 10.dp, vertical = 5.dp),
                )
            }
        }
        EdgeRow {
            if (category == FontCategory.MINE) Chip("导入字体", false, symbol = "square.and.arrow.down", onClick = onImport)
            for (choice in FontStore.fonts(category)) FontChip(s, choice, item)
        }
        // 只在出错时显示一行原因（导入失败、下载失败）
        FontStore.note?.let {
            Text(it, fontSize = 11.sp, color = problemColor, maxLines = 2, modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth())
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun FontChip(s: OverlaySession, choice: FontChoice, item: OverlayItem) {
    val on = item.fontID == choice.id
    val ready = FontStore.isReady(choice)
    val progress = FontStore.progress(choice)
    var menu by remember { mutableStateOf(false) }
    val family = remember(choice.id, ready) {
        if (ready) FontFamily(androidx.compose.ui.text.font.Typeface(OverlayFonts.resolve(choice.id).typeface)) else null
    }
    Box {
        Row(
            Modifier.height(36.dp).clip(CircleShape).background(if (on) Color.White else Theme.chip)
                .combinedClickable(
                    interactionSource = remember { MutableInteractionSource() }, indication = null,
                    onLongClick = { if (choice.kind == FontChoice.Kind.CUSTOM) menu = true },
                    onClick = { pick(s, choice) },
                )
                .padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            val fg = if (on) Color.Black else Color.White
            Text(choice.title, fontSize = if (ready) 15.sp else 14.sp, fontFamily = family, color = fg, maxLines = 1)
            if (progress != null) {
                Text("${(progress * 100).roundToInt()}%", fontSize = 11.sp, color = fg)
            } else if (!ready) {
                Icon(sym("arrow.down.circle"), null, tint = fg, modifier = Modifier.size(13.dp))
            }
        }
        DropdownMenu(menu, onDismissRequest = { menu = false }, containerColor = Theme.panel) {
            DropdownMenuItem(text = { Text("删除这款字体", color = Theme.red) }, onClick = { menu = false; FontStore.delete(choice) })
        }
    }
}

private fun pick(s: OverlaySession, choice: FontChoice) {
    FontStore.note = null
    if (FontStore.isReady(choice)) {
        s.change { it.copy(fontID = choice.id) }
        return
    }
    val target = s.selectedId
    FontStore.download(choice) { ok ->
        // 下载期间如果换了别的文字，就不动它了
        if (ok && target != null && s.selectedId == target) s.update(target) { it.copy(fontID = choice.id) }
    }
}
