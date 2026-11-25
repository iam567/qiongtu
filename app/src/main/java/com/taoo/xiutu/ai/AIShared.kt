package com.taoo.xiutu.ai

import android.graphics.Bitmap
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.editor.ZoomableCanvas
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tap
import kotlinx.coroutines.launch

/** 一排可横向滑动的选项标签（单选或多选都用它）。badge 给要带角标的项。 */
@Composable
fun <T> ChipRow(
    items: List<T>,
    title: (T) -> String,
    isSelected: (T) -> Boolean,
    modifier: Modifier = Modifier,
    badge: ((T) -> String?)? = null,
    onTap: (T) -> Unit,
) {
    Row(
        modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (item in items) {
            Chip(title(item), isSelected(item), badge = badge?.invoke(item)) { onTap(item) }
        }
    }
}

/** 页面底部的一级菜单（和修图编辑器同款）。 */
@Composable
fun <T> BottomTabBar(tabs: List<T>, title: (T) -> String, selection: T, modifier: Modifier = Modifier, onSelect: (T) -> Unit) {
    Row(modifier.fillMaxWidth().height(50.dp).background(Theme.panel), verticalAlignment = Alignment.CenterVertically) {
        for (item in tabs) {
            val on = item == selection
            Column(
                Modifier.weight(1f).tap { onSelect(item) },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    title(item), fontSize = 16.sp,
                    fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
                    color = if (on) Theme.accent else Color.White,
                )
                Spacer(Modifier.height(6.dp))
                Box(Modifier.width(18.dp).height(3.dp).clip(CircleShape).background(if (on) Theme.accent else Color.Transparent))
            }
        }
    }
}

/** AI 出错时的红字原因，外加"换一家重试"的按钮。 */
@Composable
fun AIFailureView(message: String?, modifier: Modifier = Modifier, retry: () -> Unit) {
    if (message == null) return
    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(message, fontSize = 12.sp, color = Color(1f, 0.45f, 0.4f))
        val others = AIProvider.entries.filter { it != AISettings.active && AISettings.isConfigured(it) }
        if (others.isNotEmpty()) {
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (provider in others) {
                    Box {
                        Text(
                            "换 ${provider.shortTitle} 重试", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Color.Black,
                            modifier = Modifier.clip(CircleShape).background(Theme.accent)
                                .press {
                                    AISettings.setActive(provider)
                                    retry()
                                }
                                .padding(horizontal = 12.dp, vertical = 6.dp),
                        )
                        CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = 3.dp, y = (-5).dp))
                    }
                }
            }
        }
    }
}

/** 没填 Key 时：只有一个"去设置"按钮。 */
@Composable
fun NeedsKeyView(modifier: Modifier = Modifier, openSettings: () -> Unit) {
    Box(modifier.fillMaxWidth().padding(vertical = 18.dp), contentAlignment = Alignment.Center) {
        Text(
            "去设置", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.Black,
            modifier = Modifier.clip(CircleShape).background(Theme.accent).press(onClick = openSettings)
                .padding(horizontal = 22.dp, vertical = 8.dp),
        )
    }
}

/** 全屏看一张生成结果，可以保存。 */
@Composable
fun ResultViewer(image: Bitmap, onClose: () -> Unit, source: String = "AI 生成") {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var note by remember(image) { mutableStateOf<String?>(null) }
    BackHandler(onBack = onClose)
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        ZoomableCanvas(image)
        Row(
            Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier.size(40.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.5f)).tap(onClick = onClose),
                contentAlignment = Alignment.Center,
            ) { Icon(sym("xmark"), null, tint = Color.White, modifier = Modifier.size(20.dp)) }
            Spacer(Modifier.weight(1f))
            Text(
                note ?: "保存", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black,
                modifier = Modifier.clip(RoundedCornerShape(50)).background(Color.White)
                    .press {
                        scope.launch {
                            val ok = AIOneShot.saveToPhotos(context, image, source)
                            note = if (ok) "已保存到相册" else "保存失败"
                        }
                    }
                    .padding(horizontal = 18.dp, vertical = 8.dp),
            )
        }
    }
}

/** 橙色的主按钮，带 AI 角标。 */
@Composable
fun AIMainButton(title: String, modifier: Modifier = Modifier, symbol: String? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth().height(42.dp).clip(CircleShape)
                .background(if (enabled) Theme.accent else Theme.accent.copy(alpha = 0.35f)).press(enabled, onClick),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            if (symbol != null) {
                Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
            }
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black, maxLines = 1)
        }
        CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = (-6).dp, y = (-5).dp))
    }
}
