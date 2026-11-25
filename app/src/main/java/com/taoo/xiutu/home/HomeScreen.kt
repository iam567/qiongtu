package com.taoo.xiutu.home

import android.Manifest
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.history.HistoryStore
import com.taoo.xiutu.picker.PhotoLibrary
import com.taoo.xiutu.settings.SettingsSheet
import com.taoo.xiutu.tools.beauty.FavoriteFaceStore
import com.taoo.xiutu.tools.collage.AutoStitchLoader
import com.taoo.xiutu.ui.*
import kotlinx.coroutines.launch

/** 主页：一个大的"开始编辑"，加几个直达某个工具的快捷入口。 */
@Composable
fun HomeScreen(
    start: (Tool?) -> Unit,
    startCover: () -> Unit,
    startStudio: () -> Unit,
    startManga: () -> Unit,
    startBatch: () -> Unit,
    startHistory: () -> Unit,
    startRaw: () -> Unit,
    startFavorite: () -> Unit = {},
    /** 自动拼好的长图直接进编辑器。 */
    openStitch: (com.taoo.xiutu.tools.collage.AutoStitchJob) -> Unit = {},
) {
    var showSettings by remember { mutableStateOf(false) }
    val shortcuts = listOf(Tool.CROP, Tool.FILTER, Tool.ADJUST)
    val context = LocalContext.current
    val uriHandler = LocalUriHandler.current
    val scope = rememberCoroutineScope()
    var stitching by remember { mutableStateOf(false) }
    var stitchError by remember { mutableStateOf<String?>(null) }
    // 找最近一组连续截图，算好接缝后打开拼接页。
    fun runStitch() {
        stitching = true
        scope.launch {
            val result = AutoStitchLoader.run(context)
            stitching = false
            result.job?.let(openStitch) ?: run { stitchError = result.failure?.message }
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (PhotoLibrary.granted(context)) runStitch() else stitchError = AutoStitchLoader.Failure.NO_ACCESS.message
    }
    fun autoStitch() {
        if (stitching) return
        if (PhotoLibrary.granted(context)) { runStitch(); return }
        val perms = if (Build.VERSION.SDK_INT >= 34) arrayOf(PhotoLibrary.permission, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) else arrayOf(PhotoLibrary.permission)
        permission.launch(perms)
    }
    Box(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding()) {
        // 屏幕矮、字号大的手机上一屏放不下，可以往下滚到底部的小字。
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Row(Modifier.fillMaxWidth().padding(top = 24.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("穷图", fontSize = 38.sp, fontWeight = FontWeight.Black, color = Color.White, fontFamily = FontFamily.SansSerif)
                Spacer(Modifier.weight(1f))
                Box(Modifier.size(44.dp).clip(CircleShape).background(Theme.chip).tap { showSettings = true }, contentAlignment = Alignment.Center) {
                    Icon(sym("gearshape.fill"), "设置", tint = Color.White, modifier = Modifier.size(22.dp))
                }
            }
            Row(Modifier.fillMaxWidth()) {
                for (t in shortcuts) {
                    Column(Modifier.weight(1f).press { start(t) }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Icon(sym(t.symbol), null, tint = Color.White, modifier = Modifier.size(30.dp))
                        Text(t.title, fontSize = 13.sp, color = Color.White)
                    }
                }
                Column(Modifier.weight(1f).press { autoStitch() }, horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Icon(sym("rectangle.stack"), null, tint = Color.White, modifier = Modifier.size(30.dp))
                    Text("自动拼图", fontSize = 13.sp, color = Color.White)
                }
            }
            Row(
                Modifier.fillMaxWidth().height(72.dp).clip(RoundedCornerShape(22.dp)).background(Color.White).press { start(null) },
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(sym("plus.app.fill"), null, tint = Color.Black, modifier = Modifier.size(24.dp))
                Spacer(Modifier.width(10.dp))
                Text("开始编辑", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = Color.Black)
            }
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                FeatureButton("camera.filters", "RAW 冲洗", action = startRaw)
                FeatureButton("crown.fill", "封神", action = startCover)
                FeatureButton("camera.aperture", "摄影棚", action = startStudio)
                FeatureButton("book.pages.fill", "漫画人生", action = startManga)
                FeatureButton("square.stack.3d.down.right.fill", "统一风格", value = "一批照片调成同一种色彩", action = startBatch)
                FeatureButton(if (HistoryStore.hasPassword) "lock.fill" else "photo.stack", "历史图库", value = "${HistoryStore.count} 张", action = startHistory)
                FeatureButton("star.fill", "满意脸型", value = "${FavoriteFaceStore.faces.size} 个", action = startFavorite)
            }
            Row(
                Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(Theme.panel).press { showSettings = true }.padding(14.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(sym("sparkles"), null, tint = Theme.accent, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("AI 修图：${AISettings.activeShortTitle}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    if (AISettings.isActiveConfigured()) Text(AISettings.activeModel, fontSize = 12.sp, color = Theme.dim)
                }
                Icon(sym("chevron.right"), null, tint = Theme.dim, modifier = Modifier.size(14.dp))
            }
            // 点一下打开作者的 X 主页。
            Text("作者X:@iam678", fontSize = 13.sp, color = Theme.dim, modifier = Modifier.align(Alignment.CenterHorizontally).tap { runCatching { uriHandler.openUri("https://x.com/iam678") } })
        }
        if (stitching) BusyOverlay()
    }
    stitchError?.let { message ->
        AlertDialog(
            onDismissRequest = { stitchError = null },
            text = { Text(message) },
            confirmButton = { TextButton({ stitchError = null }) { Text("好", color = Color.White) } },
            containerColor = Theme.panel,
        )
    }
    if (showSettings) SettingsSheet(onDismiss = { showSettings = false })
}

@Composable
private fun FeatureButton(symbol: String, title: String, value: String? = null, badge: String? = null, action: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).background(Theme.panel).press(onClick = action).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box {
            Box(Modifier.size(42.dp).clip(RoundedCornerShape(12.dp)).background(Theme.accent), contentAlignment = Alignment.Center) {
                Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(22.dp))
            }
            if (badge != null) CornerBadge(badge, Modifier.align(Alignment.TopEnd).offset(x = 5.dp, y = (-4).dp))
        }
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(title, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = Color.White)
            if (value != null) Text(value, fontSize = 12.sp, color = Theme.dim)
        }
        Icon(sym("chevron.right"), null, tint = Theme.dim, modifier = Modifier.size(14.dp))
    }
}
