package com.taoo.xiutu.ui

import androidx.compose.runtime.setValue
import androidx.compose.runtime.getValue
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.layout.positionInParent
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import android.graphics.Bitmap
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

object Theme {
    val accent = Color(1.0f, 0.68f, 0.26f)
    val bg = Color.Black
    val panel = Color(0.07f, 0.07f, 0.07f)
    val chip = Color(0.16f, 0.16f, 0.16f)
    val dim = Color(0.6f, 0.6f, 0.6f)
    val tile = Color(0.14f, 0.14f, 0.14f)
    val green = Color(0.2f, 0.8f, 0.35f)
    val red = Color(1f, 0.33f, 0.3f)
}

@Composable
fun XiuTuTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Theme.accent,
            onPrimary = Color.Black,
            secondary = Theme.accent,
            background = Theme.bg,
            surface = Theme.panel,
            onSurface = Color.White,
            onBackground = Color.White,
            surfaceVariant = Theme.chip,
        ),
        content = content,
    )
}

/** 按下去缩一点的手感。 */
@Composable
fun Modifier.press(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    val s by animateFloatAsState(if (pressed) 0.93f else 1f, label = "press")
    return this
        .scale(s)
        .alpha(if (pressed) 0.7f else 1f)
        .clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
}

/** 不带水波纹的点击。 */
@Composable
fun Modifier.tap(enabled: Boolean = true, onClick: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    return clickable(interactionSource = source, indication = null, enabled = enabled, onClick = onClick)
}

/** 点一下 / 长按，没有水波纹。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun Modifier.tapOrHold(onClick: () -> Unit, onHold: () -> Unit): Modifier {
    val source = remember { MutableInteractionSource() }
    return combinedClickable(source, null, onLongClick = onHold, onClick = onClick)
}

/** 小角标：凡是会调用 AI 生成的按钮，右上角都带一个 "AI"。 */
@Composable
fun CornerBadge(text: String, modifier: Modifier = Modifier) {
    Text(
        text,
        fontSize = 9.sp, fontWeight = FontWeight.Bold, color = Color.Black,
        modifier = modifier.background(Theme.accent, CircleShape).padding(horizontal = 4.dp, vertical = 0.dp),
        lineHeight = 12.sp,
    )
}

/** 面板里的小标签按钮。 */
@Composable
fun Chip(title: String, selected: Boolean, symbol: String? = null, badge: String? = null, onClick: () -> Unit) {
    Box {
        Row(
            Modifier
                .clip(CircleShape)
                .background(if (selected) Color.White else Theme.chip)
                .tap(onClick = onClick)
                .padding(horizontal = 14.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            val fg = if (selected) Color.Black else Color.White
            if (symbol != null) Icon(sym(symbol), null, tint = fg, modifier = Modifier.size(14.dp))
            Text(title, fontSize = 14.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal, color = fg, maxLines = 1)
        }
        if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = 3.dp, y = (-5).dp))
    }
}

/** 图标在上、文字在下的方块按钮。 */
@Composable
fun IconTile(
    symbol: String,
    title: String,
    selected: Boolean = false,
    badge: String? = null,
    modified: Boolean = false,
    enabled: Boolean = true,
    onClick: () -> Unit,
) {
    val fg = if (selected) Theme.accent else Color.White
    Column(
        Modifier.widthIn(min = 58.dp).alpha(if (enabled) 1f else 0.35f).tap(enabled) { onClick() }.padding(vertical = 4.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Box(Modifier.size(width = 44.dp, height = 30.dp), contentAlignment = Alignment.Center) {
            Icon(sym(symbol), null, tint = fg, modifier = Modifier.size(24.dp))
            if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = 8.dp, y = (-2).dp))
            else if (modified) Box(Modifier.align(Alignment.TopEnd).offset(x = (-4).dp, y = 2.dp).size(6.dp).background(Theme.accent, CircleShape))
        }
        Text(title, fontSize = 12.sp, color = fg, maxLines = 1)
    }
}

/** 功能按钮：圆角方块里放图标，名字在下面。 */
@Composable
fun FeatureTile(symbol: String, title: String, selected: Boolean = false, badge: String? = null, onClick: () -> Unit) {
    Column(Modifier.width(64.dp).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box {
            Box(
                Modifier.size(54.dp).clip(RoundedCornerShape(16.dp)).background(if (selected) Theme.accent else Theme.chip),
                contentAlignment = Alignment.Center,
            ) { Icon(sym(symbol), null, tint = if (selected) Color.Black else Color.White, modifier = Modifier.size(23.dp)) }
            if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = 5.dp, y = (-4).dp))
        }
        Text(
            title, fontSize = 11.5.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Theme.accent else Color.White,
        )
    }
}

/** 图片按钮：一张缩略图，名字在下面。没有图时显示 symbol 占位。 */
@Composable
fun ImageTile(
    title: String,
    image: Bitmap?,
    selected: Boolean = false,
    symbol: String? = null,
    badge: String? = null,
    width: Dp = 68.dp,
    height: Dp = 84.dp,
    onClick: () -> Unit,
) {
    Column(Modifier.width(width).press(onClick = onClick), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(
            Modifier.size(width, height).clip(RoundedCornerShape(10.dp)).background(Theme.tile)
                .border(2.5.dp, if (selected) Theme.accent else Color.Transparent, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (image != null) {
                val ib = remember(image) { image.asImageBitmap() }
                Image(ib, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(10.dp)))
                if (selected) Box(Modifier.fillMaxSize().border(2.5.dp, Theme.accent, RoundedCornerShape(10.dp)))
            } else if (symbol != null) {
                Icon(sym(symbol), null, tint = Theme.dim, modifier = Modifier.size(22.dp))
            }
            if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).padding(4.dp))
        }
        Text(
            title, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
            fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal,
            color = if (selected) Theme.accent else Color.White,
        )
    }
}

/** 一排等宽的分段标签，选中的那格是白底。 */
@Composable
fun <T> SegmentBar(
    items: List<T>, selected: T, title: (T) -> String, symbol: ((T) -> String)? = null,
    /** 放不下时改成可以左右滑，每格按内容宽度排。 */
    scrolls: Boolean = false,
    onSelect: (T) -> Unit,
) {
    @Composable
    fun Cell(item: T, modifier: Modifier, inner: androidx.compose.ui.unit.Dp = 0.dp) {
        val on = item == selected
        Row(
            modifier.heightIn(min = 32.dp).clip(CircleShape)
                .background(if (on) Color.White else Color.Transparent).tap { onSelect(item) }.padding(horizontal = inner),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            val fg = if (on) Color.Black else Color.White
            if (symbol != null) {
                Icon(sym(symbol(item)), null, tint = fg, modifier = Modifier.size(14.dp))
                Spacer(Modifier.width(4.dp))
            }
            Text(title(item), fontSize = 14.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Normal, color = fg, maxLines = 1)
        }
    }
    if (!scrolls) {
        Row(Modifier.fillMaxWidth().clip(CircleShape).background(Theme.chip).padding(3.dp)) {
            for (item in items) Cell(item, Modifier.weight(1f))
        }
        return
    }
    // 可以滑：选中的那格自动滑到中间
    val scroll = androidx.compose.foundation.rememberScrollState()
    val spans = androidx.compose.runtime.remember { HashMap<Int, IntRange>() }
    var width by androidx.compose.runtime.remember { androidx.compose.runtime.mutableIntStateOf(0) }
    val index = items.indexOf(selected)
    androidx.compose.runtime.LaunchedEffect(index, width) {
        val s = spans[index] ?: return@LaunchedEffect
        val target = ((s.first + s.last) / 2 - width / 2).coerceIn(0, scroll.maxValue)
        scroll.animateScrollTo(target)
    }
    Box(
        Modifier.fillMaxWidth().clip(CircleShape).background(Theme.chip)
            .onSizeChanged { width = it.width },
    ) {
        Row(Modifier.horizontalScroll(scroll).padding(3.dp)) {
            items.forEachIndexed { i, item ->
                Cell(
                    item,
                    Modifier.onGloballyPositioned { c ->
                        val x = c.positionInParent().x.toInt()
                        spans[i] = x..(x + c.size.width)
                    },
                    10.dp,
                )
            }
        }
    }
}

/** "文字 + 下划线"的标签（调色的 光效/色彩/细节/光影）。 */
@Composable
fun <T> UnderlineTabs(items: List<T>, selected: T, title: (T) -> String, onSelect: (T) -> Unit) {
    Row(Modifier.fillMaxWidth()) {
        for (item in items) {
            val on = item == selected
            Column(Modifier.weight(1f).tap { onSelect(item) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(title(item), fontSize = 15.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, color = if (on) Color.White else Theme.dim, maxLines = 1)
                Box(Modifier.size(18.dp, 3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
            }
        }
    }
}

/** 白色胶囊主按钮。 */
@Composable
fun PillButton(title: String, modifier: Modifier = Modifier, color: Color = Color.White, enabled: Boolean = true, badge: String? = null, onClick: () -> Unit) {
    Box(modifier) {
        Box(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).press(enabled, onClick).clip(CircleShape).background(if (enabled) color else color.copy(alpha = color.alpha * 0.4f)),
            contentAlignment = Alignment.Center,
        ) { Text(title, fontSize = 16.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
        if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = (-6).dp, y = (-4).dp))
    }
}

/** 统一样式的滑块。 */
@Composable
fun XSlider(value: Float, onChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float> = 0f..1f, modifier: Modifier = Modifier, enabled: Boolean = true, onFinished: (() -> Unit)? = null) {
    Slider(
        value = value.coerceIn(range.start, range.endInclusive), onValueChange = onChange, valueRange = range, enabled = enabled,
        onValueChangeFinished = onFinished,
        modifier = modifier.height(36.dp),
        colors = SliderDefaults.colors(
            thumbColor = Color.White, activeTrackColor = Theme.accent, inactiveTrackColor = Theme.chip,
            activeTickColor = Color.Transparent, inactiveTickColor = Color.Transparent,
        ),
    )
}

/** 一行：数值 + 滑块 + 还原按钮。 */
@Composable
fun ValueSliderRow(value: Float, onChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float>, label: String, onReset: (() -> Unit)? = null, resetEnabled: Boolean = true) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.width(44.dp))
        XSlider(value, onChange, range, Modifier.weight(1f))
        if (onReset != null) {
            Box(Modifier.size(36.dp).tap(onClick = onReset), contentAlignment = Alignment.Center) {
                Icon(sym("arrow.counterclockwise"), null, tint = if (resetEnabled) Color.White else Theme.dim, modifier = Modifier.size(18.dp))
            }
        }
    }
}

/** 标题 + 滑块。 */
@Composable
fun LabeledSlider(title: String, value: Float, onChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float> = 0f..1f) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(title, fontSize = 13.sp, color = Theme.dim, modifier = Modifier.width(44.dp))
        XSlider(value, onChange, range, Modifier.weight(1f))
    }
}

/** 半透明的转圈。 */
@Composable
fun BusyOverlay() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Box(Modifier.clip(RoundedCornerShape(16.dp)).background(Color.Black.copy(alpha = 0.6f)).padding(24.dp)) {
            CircularProgressIndicator(color = Color.White, strokeWidth = 3.dp, modifier = Modifier.size(36.dp))
        }
    }
}

/** 底部提示。 */
@Composable
fun Toast(text: String, modifier: Modifier = Modifier) {
    Text(
        text, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = Color.White,
        modifier = modifier.clip(CircleShape).background(Color(0.2f, 0.2f, 0.2f, 0.95f)).padding(horizontal = 18.dp, vertical = 11.dp),
    )
}
