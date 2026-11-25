package com.taoo.xiutu.tools.makeup

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
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
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ui.FeatureTile
import com.taoo.xiutu.ui.GenderSetting
import com.taoo.xiutu.ui.GenderToggle
import com.taoo.xiutu.ui.ImageTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

/** 美妆面板：小分类 + 浓淡滑块 + 一排预设。上妆全部在本机完成，美甲和装饰交给 AI。 */
@Composable
fun MakeupPanel(s: MakeupSession) {
    Column(Modifier.fillMaxWidth().padding(top = 12.dp, bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        val local = s.category.isLocal
        if (local && s.detecting) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = 44.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterHorizontally),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Text("正在找人脸…", fontSize = 14.sp, color = Color.White)
            }
        } else if (local && s.faces.isEmpty()) {
            com.taoo.xiutu.editor.FaceRescue(s.model, if (s.unreliable) "这张脸太小或者太侧，五官定位不准" else "这张图里没有找到人脸")
        } else {
            Header(s)
            if (local) AmountSlider(s)
            Options(s)
        }
    }
}

// MARK: 小分类 + 选脸

@Composable
private fun Header(s: MakeupSession) {
    val tabs = s.category.tabs
    val multi = s.category.isLocal && s.faces.size > 1
    val look = s.category == MakeupCategory.LOOK
    if (tabs.isEmpty() && !multi && !look) return
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        if (look) GenderToggle()
        Row(Modifier.weight(1f).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            tabs.forEachIndexed { index, title ->
                val on = s.tab == index
                Text(
                    title, fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal,
                    color = if (on) Color.White else Theme.dim, maxLines = 1,
                    modifier = Modifier.tap { s.selectTab(index) }.padding(vertical = 4.dp),
                )
            }
        }
        if (multi) {
            var open by remember { mutableStateOf(false) }
            Box {
                Row(
                    Modifier.clip(CircleShape).background(Theme.chip).tap { open = true }.padding(horizontal = 10.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Icon(sym("person.crop.circle"), null, tint = Color.White, modifier = Modifier.size(15.dp))
                    Text("${s.faceIndex + 1}/${s.faces.size}", fontSize = 13.sp, color = Color.White)
                }
                DropdownMenu(open, onDismissRequest = { open = false }, containerColor = Theme.panel) {
                    for (index in s.faces.indices) {
                        DropdownMenuItem(
                            text = { Text("第 ${index + 1} 张脸", color = Color.White) },
                            leadingIcon = if (index == s.faceIndex) ({ Icon(sym("checkmark"), null, tint = Color.White) }) else null,
                            onClick = { open = false; s.selectFace(index) },
                        )
                    }
                }
            }
        }
    }
}

// MARK: 浓淡

@Composable
private fun AmountSlider(s: MakeupSession) {
    val amount = s.amount
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp).alpha(if (amount == null) 0.3f else 1f),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("${((amount ?: 0f) * 100).roundToInt()}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White,
            modifier = Modifier.width(40.dp))
        XSlider(amount ?: 0f, { s.setAmount(it) }, 0f..1f, Modifier.weight(1f), enabled = amount != null)
    }
}

// MARK: 一排选项

@Composable
private fun Options(s: MakeupSession) {
    val (list, crop) = s.makeupOptions()
    val listKey = "${s.faceIndex}|${s.category.name}|${s.tab}|${GenderSetting.isMale}"
    LaunchedEffect(listKey, s.faces.size) { s.prepareThumbs(list, crop) }
    key(listKey) {
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top,
        ) {
            s.customColor?.let { CustomColorTile(it) { c -> s.setCustomColor(c) } }
            for (option in list) Tile(s, option)
        }
    }
}

@Composable
private fun Tile(s: MakeupSession, option: MakeupOption) {
    when (val kind = option.kind) {
        MakeupOption.Kind.Thumb ->
            ImageTile(option.title, s.thumbs[s.thumbKey(option)], selected = option.selected, width = 62.dp, height = 62.dp) { s.choose(option) }
        is MakeupOption.Kind.Swatch -> SwatchTile(option.title, kind.color, option.selected) { s.choose(option) }
        is MakeupOption.Kind.Symbol -> FeatureTile(kind.symbol, option.title, selected = option.selected) { s.choose(option) }
        is MakeupOption.Kind.Ai -> FeatureTile(kind.preset.symbol, option.title, badge = "AI") { s.choose(option) }
    }
}

/** 一个圆形色块，名字在下面。 */
@Composable
private fun SwatchTile(title: String, color: MakeupColor, selected: Boolean, onClick: () -> Unit) {
    Column(Modifier.width(62.dp).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(62.dp), contentAlignment = Alignment.Center) {
            Box(Modifier.size(54.dp).border(2.5.dp, if (selected) Theme.accent else Color.Transparent, CircleShape), contentAlignment = Alignment.Center) {
                Box(Modifier.size(46.dp).clip(CircleShape).background(Color(color.r, color.g, color.b))
                    .border(1.dp, Color.White.copy(alpha = 0.18f), CircleShape))
            }
        }
        Text(title, fontSize = 12.sp, maxLines = 1, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Theme.accent else Color.White)
    }
}

/** 自己挑颜色。 */
@Composable
private fun CustomColorTile(color: MakeupColor, change: (MakeupColor) -> Unit) {
    var picking by remember { mutableStateOf(false) }
    Column(Modifier.width(62.dp).press { picking = true }, horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(62.dp), contentAlignment = Alignment.Center) {
            Box(
                Modifier.size(46.dp).clip(CircleShape)
                    .background(Brush.sweepGradient(listOf(Color.Red, Color.Yellow, Color.Green, Color.Cyan, Color.Blue, Color.Magenta, Color.Red))),
                contentAlignment = Alignment.Center,
            ) { Box(Modifier.size(28.dp).clip(CircleShape).background(Color(color.r, color.g, color.b))) }
        }
        Text("自选", fontSize = 12.sp, color = Color.White, maxLines = 1)
    }
    if (picking) ColorPickerDialog(color, onDismiss = { picking = false }, onPick = change)
}

/** 色相、饱和度、亮度三条滑块，边调边生效。 */
@Composable
private fun ColorPickerDialog(initial: MakeupColor, onDismiss: () -> Unit, onPick: (MakeupColor) -> Unit) {
    val hsv = remember { FloatArray(3).also { android.graphics.Color.colorToHSV(initial.argb(), it) } }
    var h by remember { mutableFloatStateOf(hsv[0]) }
    var sat by remember { mutableFloatStateOf(hsv[1]) }
    var v by remember { mutableFloatStateOf(hsv[2]) }
    fun current(): MakeupColor {
        val c = android.graphics.Color.HSVToColor(floatArrayOf(h, sat, v))
        return MakeupColor(android.graphics.Color.red(c) / 255f, android.graphics.Color.green(c) / 255f, android.graphics.Color.blue(c) / 255f)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Theme.panel,
        confirmButton = { TextButton(onDismiss) { Text("完成", color = Theme.accent) } },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                val c = current()
                Box(Modifier.fillMaxWidth().height(44.dp).clip(RoundedCornerShape(10.dp)).background(Color(c.r, c.g, c.b)))
                Box(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(Brush.horizontalGradient(
                    (0..6).map { Color.hsv(it * 60f % 360f, 1f, 1f) },
                )))
                XSlider(h, { h = it; onPick(current()) }, 0f..360f)
                XSlider(sat, { sat = it; onPick(current()) }, 0f..1f)
                XSlider(v, { v = it; onPick(current()) }, 0f..1f)
            }
        },
    )
}

/** 美妆时底部确认栏（✕ 和 ✓ 之间）显示的内容：妆容 / 口红 / 眉毛 …… 这些大类，可以左右滑。 */
@Composable
fun MakeupTitle(s: MakeupSession) {
    val state = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val categories = MakeupCategory.entries
    LazyRow(
        Modifier.fillMaxWidth(), state = state,
        horizontalArrangement = Arrangement.spacedBy(20.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        itemsIndexed(categories) { index, category ->
            val on = category == s.category
            Column(
                Modifier.tap {
                    s.selectCategory(category)
                    // 点中的那一类滚到中间
                    scope.launch {
                        val info = state.layoutInfo
                        val item = info.visibleItemsInfo.firstOrNull { it.index == index }
                        val viewport = info.viewportEndOffset - info.viewportStartOffset
                        val offset = if (item != null) -(viewport - item.size) / 2 else 0
                        state.animateScrollToItem(index, offset)
                    }
                },
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(category.title, fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                    color = if (on) Color.White else Theme.dim, maxLines = 1)
                Box(Modifier.size(18.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
            }
        }
    }
}
