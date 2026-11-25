package com.taoo.xiutu.picker

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.Settings
import android.util.LruCache
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.ui.*
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** 相簿。id = null 表示全部照片。 */
data class Album(val id: String?, val title: String, val count: Int)

/** 读系统相册。 */
object PhotoLibrary {
    private val cache = object : LruCache<Uri, Bitmap>(64 * 1024 * 1024) {
        override fun sizeOf(key: Uri, value: Bitmap) = value.byteCount
    }

    val permission: String get() = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE

    fun granted(context: Context): Boolean {
        if (ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) return true
        // 安卓 14 起可以只允许部分照片
        return Build.VERSION.SDK_INT >= 34 &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED
    }

    fun images(context: Context, bucket: String?): List<Uri> {
        val out = ArrayList<Uri>()
        val sel = bucket?.let { "${MediaStore.Images.Media.BUCKET_ID}=?" }
        val args = bucket?.let { arrayOf(it) }
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI, arrayOf(MediaStore.Images.Media._ID),
            sel, args, "${MediaStore.Images.Media.DATE_ADDED} DESC",
        )?.use { c ->
            val idCol = c.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            while (c.moveToNext()) out += ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, c.getLong(idCol))
        }
        return out
    }

    fun albums(context: Context): List<Album> {
        val map = LinkedHashMap<String, Pair<String, Int>>()
        var total = 0
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(MediaStore.Images.Media.BUCKET_ID, MediaStore.Images.Media.BUCKET_DISPLAY_NAME),
            null, null, "${MediaStore.Images.Media.DATE_ADDED} DESC",
        )?.use { c ->
            while (c.moveToNext()) {
                total++
                val id = c.getString(0) ?: continue
                val name = c.getString(1) ?: "未命名"
                val cur = map[id]
                map[id] = name to ((cur?.second ?: 0) + 1)
            }
        }
        return listOf(Album(null, "最近项目", total)) + map.map { Album(it.key, it.value.first, it.value.second) }
    }

    suspend fun thumb(context: Context, uri: Uri, side: Int = 256): Bitmap? {
        cache.get(uri)?.let { return it }
        return withContext(Dispatchers.IO) {
            runCatching { context.contentResolver.loadThumbnail(uri, Size(side, side), null) }.getOrNull()
        }?.also { cache.put(uri, it) }
    }
}

/** 相册选图：点缩略图直接进编辑，点右下角的小按钮先放大预览。 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun PhotoPickerScreen(
    onPick: (Uri) -> Unit,
    onClose: () -> Unit,
    /** 大于 0 时可以多选（最多这么多张），点"添加"交给 onPickMany。 */
    limit: Int = 0,
    onPickMany: (List<Uri>) -> Unit = {},
) {
    val context = LocalContext.current
    var access by remember { mutableStateOf<Boolean?>(if (PhotoLibrary.granted(context)) true else null) }
    var albums by remember { mutableStateOf<List<Album>>(emptyList()) }
    var current by remember { mutableStateOf<Album?>(null) }
    var images by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var preview by remember { mutableStateOf<Int?>(null) }
    var menu by remember { mutableStateOf(false) }
    var chosen by remember { mutableStateOf<List<Uri>>(emptyList()) }
    val many = limit > 0
    fun toggle(uri: Uri) {
        chosen = if (uri in chosen) chosen - uri else if (chosen.size < limit) chosen + uri else chosen
    }

    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        access = PhotoLibrary.granted(context)
    }
    LaunchedEffect(Unit) {
        if (access != true) {
            val perms = if (Build.VERSION.SDK_INT >= 34) arrayOf(PhotoLibrary.permission, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) else arrayOf(PhotoLibrary.permission)
            launcher.launch(if (many) perms + Manifest.permission.ACCESS_MEDIA_LOCATION else perms)
        } else if (many && ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            // 导出时要保留照片里的拍摄地点
            launcher.launch(arrayOf(Manifest.permission.ACCESS_MEDIA_LOCATION))
        }
    }
    LaunchedEffect(access, current) {
        if (access != true) return@LaunchedEffect
        val (a, list) = withContext(Dispatchers.IO) { PhotoLibrary.albums(context) to PhotoLibrary.images(context, current?.id) }
        albums = a
        if (current == null) current = a.firstOrNull()
        images = list
    }

    Column(Modifier.fillMaxSize().background(Theme.bg).systemBarsPadding()) {
        Box(Modifier.fillMaxWidth().height(56.dp).padding(horizontal = 8.dp)) {
            Box(Modifier.size(44.dp).align(Alignment.CenterStart).tap(onClick = onClose), contentAlignment = Alignment.Center) {
                Icon(sym("xmark"), "关闭", tint = Color.White)
            }
            if (many && chosen.isNotEmpty()) {
                Box(
                    Modifier.align(Alignment.CenterEnd).clip(CircleShape).background(Color.White).press { onPickMany(chosen) }
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                ) { Text("添加 ${chosen.size} 张", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
            }
            Box(Modifier.align(Alignment.Center)) {
                Row(
                    Modifier.clip(CircleShape).background(Theme.chip).tap { menu = true }.padding(horizontal = 16.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(current?.title ?: "相册", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    Icon(Icons.Filled.KeyboardArrowDown, null, tint = Color.White, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(menu, { menu = false }, containerColor = Theme.panel) {
                    for (a in albums) DropdownMenuItem(text = { Text("${a.title}（${a.count}）", color = Color.White) }, onClick = { menu = false; current = a })
                }
            }
        }
        when (access) {
            null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = Color.White) }
            false -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                Text("没有相册权限", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                Spacer(Modifier.height(14.dp))
                Button({
                    context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + context.packageName)))
                }, colors = ButtonDefaults.buttonColors(containerColor = Theme.accent, contentColor = Color.Black)) { Text("打开设置") }
            }
            true -> if (images.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("这个相簿里没有图片", color = Theme.dim) }
            } else {
                LazyVerticalGrid(GridCells.Fixed(4), horizontalArrangement = Arrangement.spacedBy(2.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    items(images.size, key = { images[it].toString() }) { i ->
                        val uri = images[i]
                        Box(Modifier.aspectRatio(1f).background(Theme.tile)) {
                            var bmp by remember(uri) { mutableStateOf<Bitmap?>(null) }
                            LaunchedEffect(uri) { bmp = PhotoLibrary.thumb(context, uri) }
                            bmp?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize()) }
                            Box(Modifier.fillMaxSize().tap { if (many) toggle(uri) else onPick(uri) })
                            val order = chosen.indexOf(uri)
                            if (order >= 0) {
                                Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)))
                                Box(
                                    Modifier.align(Alignment.TopEnd).padding(5.dp).size(24.dp).clip(CircleShape).background(Theme.accent),
                                    contentAlignment = Alignment.Center,
                                ) { Text("${order + 1}", fontSize = 12.sp, lineHeight = 12.sp, fontWeight = FontWeight.Bold, color = Color.Black) }
                            }
                            Box(
                                Modifier.align(Alignment.BottomEnd).padding(5.dp).size(26.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)).tap { preview = i },
                                contentAlignment = Alignment.Center,
                            ) { Icon(Icons.Filled.OpenInFull, "预览", tint = Color.White, modifier = Modifier.size(13.dp)) }
                        }
                    }
                }
            }
        }
    }

    preview?.let { start ->
        Dialog({ preview = null }, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
            val pager = rememberPagerState(start) { images.size }
            Box(Modifier.fillMaxSize().background(Color.Black)) {
                HorizontalPager(pager, Modifier.fillMaxSize()) { page ->
                    var bmp by remember { mutableStateOf<Bitmap?>(null) }
                    LaunchedEffect(page) { bmp = withContext(Dispatchers.IO) { Img.decode(context, images[page], 2048) } }
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        bmp?.let { Image(it.asImageBitmap(), null, contentScale = ContentScale.Fit, modifier = Modifier.fillMaxSize()) }
                            ?: CircularProgressIndicator(color = Color.White)
                    }
                }
                Row(Modifier.fillMaxWidth().systemBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(44.dp).tap { preview = null }, contentAlignment = Alignment.Center) { Icon(sym("xmark"), "关闭", tint = Color.White) }
                    Spacer(Modifier.weight(1f))
                    Box(Modifier.clip(CircleShape).background(Color.White).press { val u = images[pager.currentPage]; preview = null; if (many) toggle(u) else onPick(u) }.padding(horizontal = 20.dp, vertical = 9.dp)) {
                        val u = images.getOrNull(pager.currentPage)
                        Text(if (!many) "编辑" else if (u in chosen) "取消选择" else "选择", fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black)
                    }
                }
            }
        }
    }
}
