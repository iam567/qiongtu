package com.taoo.xiutu.ai.outfit

import android.graphics.Bitmap
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.taoo.xiutu.ai.AIMainButton
import com.taoo.xiutu.ai.AIOneShot
import com.taoo.xiutu.ai.AISession
import com.taoo.xiutu.batch.BatchStyleScreen
import com.taoo.xiutu.batch.NameDialog
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.studio.SwatchChip
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.GenderSetting
import com.taoo.xiutu.ui.GenderToggle
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import com.taoo.xiutu.ui.tapOrHold
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val tileShape = RoundedCornerShape(10.dp)
private val tileColor = Color(0.2f, 0.2f, 0.2f)

/** 换衣服：点一款 → 选颜色、裙摆 → 点"开始换"才发给 AI。也可以照着一张图里的衣服换。 */
@Composable
fun OutfitPanel(s: AISession, custom: () -> Unit) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val male = GenderSetting.isMale
    val groups = listOf(MINE) + OutfitCatalog.groups(male)
    var group by remember { mutableStateOf("") }
    val current = if (group in groups) group else if (WardrobeStore.items.isEmpty()) groups.getOrElse(1) { MINE } else MINE
    var renaming by remember { mutableStateOf<WardrobeItem?>(null) }
    val worn = s.wardrobePick
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) scope.launch {
            s.outfitReference = withContext(Dispatchers.IO) { Img.decode(context, uri, 1400)?.let { AIOneShot.prepared(it, 1400) } }
        }
    }
    val reference = s.outfitReference
    val outfit = s.outfitPick
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        when {
            worn != null -> WardrobeCard(s, worn)
            reference != null -> ReferenceCard(s, reference)
            outfit != null -> OutfitCard(s, outfit)
            else -> {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    GenderToggle()
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (name in groups) Chip(name, selected = current == name) { group = name }
                    }
                }
                key(current, male) {
                    Row(Modifier.horizontalScroll(rememberScrollState()).padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (current == MINE) WardrobeTiles(s) { renaming = it }
                        for (o in OutfitCatalog.list(male)) if (o.group == current) {
                            OutfitTile(o.title, { s.pickOutfit(o) }) {
                                OutfitArt(o.shape, OutfitCatalog.color(o.colors.firstOrNull() ?: ""), Modifier.fillMaxSize())
                            }
                        }
                        if (current != MINE) OutfitTile("照着图换", { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }) {
                            Icon(sym("photo.badge.plus"), null, tint = Color.White, modifier = Modifier.size(28.dp))
                        }
                        if (current != MINE) OutfitTile("自己写", custom) {
                            Icon(sym("square.and.pencil"), null, tint = Color.White, modifier = Modifier.size(28.dp))
                        }
                    }
                }
            }
        }
    }
    renaming?.let { item ->
        NameDialog("衣服的名字", item.name, onDismiss = { renaming = null }) { WardrobeStore.update(item.id, name = it) }
    }
    s.batchOutfit?.let { id ->
        // 批量换衣服盖在编辑器上面，关掉以后接着编辑。
        Dialog({ s.batchOutfit = null }, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            BatchStyleScreen(null, outfitMode = true, outfitID = id) { s.batchOutfit = null }
        }
    }
}

private const val MINE = "我的衣橱"

/** 我的衣橱：把这张照片里的衣服存进来，或者点一身存好的来换。 */
@Composable
private fun WardrobeTiles(s: AISession, onRename: (WardrobeItem) -> Unit) {
    OutfitTile(if (s.wardrobeSaving) "正在存…" else "存这身衣服", { s.saveToWardrobe() }) {
        if (s.wardrobeSaving) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(22.dp))
        else Icon(sym("plus"), null, tint = Color.White, modifier = Modifier.size(28.dp))
    }
    for (item in WardrobeStore.items) key(item.id) {
        var menu by remember { mutableStateOf(false) }
        val image by produceState<Bitmap?>(null, item.id) { value = withContext(Dispatchers.IO) { WardrobeStore.image(item)?.let { Img.downscale(it, 320) } } }
        OutfitTile(item.name, { s.pickWardrobe(item) }, onHold = { menu = true }) {
            image?.let { b ->
                val ib = remember(b) { b.asImageBitmap() }
                Image(ib, null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            }
            DropdownMenu(menu, { menu = false }, containerColor = Theme.chip) {
                DropdownMenuItem(text = { Text("批量换到别的照片…", color = Color.White) }, onClick = { menu = false; s.batchOutfit = item.id })
                if (item.count < 3) {
                    DropdownMenuItem(text = { Text("用这张照片补一个角度", color = Color.White) }, onClick = { menu = false; s.saveToWardrobe(item.id) })
                }
                DropdownMenuItem(text = { Text("改名", color = Color.White) }, onClick = { menu = false; onRename(item) })
                DropdownMenuItem(text = { Text("删除", color = Theme.red) }, onClick = { menu = false; WardrobeStore.remove(item) })
            }
        }
    }
}

@Composable
private fun WardrobeCard(s: AISession, picked: WardrobeItem) {
    val item = WardrobeStore.find(picked.id) ?: picked
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            Row(Modifier.weight(1f, fill = false).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val images by produceState(emptyList<Bitmap>(), item.id, item.count) {
                    value = withContext(Dispatchers.IO) { WardrobeStore.references(item).map { Img.downscale(it, 420) } }
                }
                for (b in images) {
                    val ib = remember(b) { b.asImageBitmap() }
                    Image(ib, null, contentScale = ContentScale.Crop, modifier = Modifier.size(78.dp, 104.dp).clip(tileShape))
                }
            }
            Text(item.name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White, maxLines = 1)
        }
        if (item.desc.isNotEmpty()) Text(item.desc, fontSize = 12.sp, lineHeight = 17.sp, color = Theme.dim, maxLines = 3, overflow = TextOverflow.Ellipsis)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (k in OutfitSkirt.entries) Chip("裙摆 " + k.title, selected = s.outfitSkirt == k) { s.outfitSkirt = k }
        }
        Buttons(onBack = { s.pickWardrobe(null) }) {
            s.runOutfit(Wardrobe.prompt(WardrobeStore.find(item.id) ?: item, s.outfitSkirt), item.name)
        }
        Box {
            Box(
                Modifier.fillMaxWidth().height(40.dp).clip(CircleShape).background(Theme.chip).press { s.batchOutfit = item.id },
                contentAlignment = Alignment.Center,
            ) { Text("批量换到别的照片", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White) }
            CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = (-6).dp, y = (-5).dp))
        }
    }
}

@Composable
private fun OutfitTile(title: String, onClick: () -> Unit, onHold: () -> Unit = {}, art: @Composable () -> Unit) {
    Column(Modifier.width(68.dp).tapOrHold(onClick, onHold), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(68.dp, 84.dp).clip(tileShape).background(tileColor), contentAlignment = Alignment.Center) {
            art()
            CornerBadge("AI", Modifier.align(Alignment.TopEnd).padding(4.dp))
        }
        Text(title, fontSize = 12.sp, color = Color.White, maxLines = 1)
    }
}

@Composable
private fun OutfitCard(s: AISession, outfit: Outfit) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            Box(Modifier.size(84.dp, 104.dp).clip(tileShape).background(tileColor)) {
                OutfitArt(outfit.shape, OutfitCatalog.color(s.outfitColor), Modifier.fillMaxSize())
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(outfit.title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Text(outfit.prompt, fontSize = 12.sp, lineHeight = 17.sp, color = Theme.dim)
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (name in outfit.colors) {
                SwatchChip(name, listOf(OutfitCatalog.color(name)), selected = s.outfitColor == name) { s.outfitColor = name }
            }
        }
        if (outfit.skirt) {
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (k in OutfitSkirt.entries) Chip("裙摆 " + k.title, selected = s.outfitSkirt == k) { s.outfitSkirt = k }
            }
        }
        Buttons(onBack = { s.pickOutfit(null) }) {
            s.runOutfit(OutfitCatalog.prompt(outfit, s.outfitColor, s.outfitSkirt), outfit.title)
        }
    }
}

@Composable
private fun ReferenceCard(s: AISession, image: Bitmap) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        val ib = remember(image) { image.asImageBitmap() }
        Image(ib, null, contentScale = ContentScale.Fit, modifier = Modifier.heightIn(max = 120.dp).clip(tileShape))
        Buttons(onBack = { s.outfitReference = null }) { s.runOutfit(OutfitCatalog.REFERENCE_PROMPT, "照着图换") }
    }
}

@Composable
private fun Buttons(onBack: () -> Unit, onStart: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        BackPill("换一款", onBack)
        AIMainButton("开始换", Modifier.weight(1f), onClick = onStart)
    }
}

/** 灰底的返回按钮。 */
@Composable
fun BackPill(title: String, onClick: () -> Unit) {
    Row(
        Modifier.width(104.dp).height(42.dp).clip(CircleShape).background(Theme.chip).press(onClick = onClick),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(sym("chevron.left"), null, tint = Color.White, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(6.dp))
        Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
    }
}
