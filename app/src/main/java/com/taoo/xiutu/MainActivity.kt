package com.taoo.xiutu

import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.navigation.NavHostController
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.ai.MasterCatalog
import com.taoo.xiutu.batch.BatchStyleScreen
import com.taoo.xiutu.batch.StyleStore
import com.taoo.xiutu.core.DraftStore
import com.taoo.xiutu.ui.GenderSetting
import com.taoo.xiutu.ui.Theme
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.tools.collage.AutoStitchLoader
import com.taoo.xiutu.editor.EditorScreen
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.godcover.GodCoverScreen
import com.taoo.xiutu.history.HistoryScreen
import com.taoo.xiutu.history.HistoryStore
import com.taoo.xiutu.home.HomeScreen
import com.taoo.xiutu.manga.MangaScreen
import com.taoo.xiutu.picker.PhotoPickerScreen
import com.taoo.xiutu.raw.RawScreen
import com.taoo.xiutu.studio.StudioScreen
import com.taoo.xiutu.tools.beauty.FavoriteFaceScreen
import com.taoo.xiutu.tools.beauty.FavoriteFaceStore
import com.taoo.xiutu.ui.XiuTuTheme
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        AISettings.init(applicationContext)
        HistoryStore.init(applicationContext)
        FavoriteFaceStore.init(applicationContext)
        DraftStore.init(applicationContext)
        GenderSetting.init(applicationContext)
        MasterCatalog.init(applicationContext)
        StyleStore.init(applicationContext)
        setContent { XiuTuTheme { AppNav() } }
    }
}

private fun enc(s: String) = Uri.encode(s)

/** 页面路由。 */
@Composable
fun AppNav() {
    val nav = rememberNavController()
    // 启动时看看草稿箱：上次编辑到一半 App 退出了，就问要不要接着编辑
    var draftChecked by rememberSaveable { mutableStateOf(false) }
    var askDraft by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        if (draftChecked) return@LaunchedEffect
        draftChecked = true
        if (!DraftStore.exists) return@LaunchedEffect
        askDraft = DraftStore.date?.let {
            SimpleDateFormat("M月d日 HH:mm", Locale.CHINA).format(Date(it)) + " 编辑到一半的图，要接着编辑吗？"
        } ?: "要接着编辑吗？"
    }
    askDraft?.let { message ->
        AlertDialog(
            onDismissRequest = {},
            title = { Text("上次有一张图还没编辑完") },
            text = { Text(message) },
            confirmButton = { TextButton({ askDraft = null; nav.navigate("draft") }) { Text("接着编辑", color = Color.White) } },
            dismissButton = { TextButton({ askDraft = null; DraftStore.clear() }) { Text("不要了", color = Theme.red) } },
            containerColor = Theme.panel,
        )
    }
    NavHost(nav, startDestination = "home") {
        composable("home") {
            HomeScreen(
                start = { t -> nav.navigate("picker/editor/${t?.name ?: "none"}") },
                startCover = { nav.navigate("picker/cover/none") },
                startStudio = { nav.navigate("picker/studio/none") },
                startManga = { nav.navigate("manga") },
                startBatch = { nav.navigate("batch/none") },
                startHistory = { nav.navigate("history") },
                startRaw = { nav.navigate("raw") },
                startFavorite = { nav.navigate("favoriteFace") },
                openStitch = { job -> AutoStitchLoader.pending = job; nav.navigate("autoStitch") },
            )
        }
        composable("picker/{target}/{tool}") { e ->
            val target = e.arguments?.getString("target") ?: "editor"
            val tool = e.arguments?.getString("tool") ?: "none"
            PhotoPickerScreen(
                onPick = { uri ->
                    when (target) {
                        "cover" -> nav.navigate("cover/${enc(uri.toString())}")
                        "studio" -> nav.navigate("studio/${enc(uri.toString())}")
                        // 套用历史图库里某张图的处理步骤：tool 这一段放的是那张图的 id
                        "recipe" -> nav.navigate("recipe/${enc(uri.toString())}/$tool")
                        else -> nav.navigate("editor/${enc(uri.toString())}/$tool")
                    }
                },
                onClose = { if (target == "recipe") nav.popBackStack() else nav.popHome() },
            )
        }
        composable("editor/{uri}/{tool}") { e ->
            val uri = Uri.parse(e.arguments?.getString("uri"))
            val tool = e.arguments?.getString("tool")?.let { n -> Tool.entries.firstOrNull { it.name == n } }
            val context = LocalContext.current
            val model = remember { EditorModel(context).also { it.draftEnabled = true; it.load(uri) } }
            EditorScreen(model, tool) { nav.popBackStack() }
        }
        composable("recipe/{uri}/{id}") { e ->
            val uri = Uri.parse(e.arguments?.getString("uri"))
            val id = e.arguments?.getString("id") ?: ""
            val context = LocalContext.current
            val recipe = remember { HistoryStore.recipe(id) }
            val model = remember { EditorModel(context).also { it.draftEnabled = true; it.load(uri) } }
            EditorScreen(model, null, recipe = recipe) { nav.popBackStack() }
        }
        composable("editorFile/{path}") { e ->
            val file = File(e.arguments?.getString("path") ?: "")
            val context = LocalContext.current
            val model = remember { EditorModel(context).also { it.draftEnabled = true; it.load(file) } }
            EditorScreen(model, null) { nav.popBackStack() }
        }
        composable("autoStitch") {
            val context = LocalContext.current
            val job = remember { AutoStitchLoader.pending.also { AutoStitchLoader.pending = null } }
            val file = job?.files?.firstOrNull()
            if (job == null || file == null) {
                LaunchedEffect(Unit) { nav.popBackStack() }
            } else {
                val model = remember { EditorModel(context).also { it.draftEnabled = true; it.load(file) } }
                EditorScreen(model, Tool.COLLAGE, stitchJob = job) { nav.popBackStack() }
            }
        }
        composable("draft") {
            val context = LocalContext.current
            val model = remember { EditorModel(context).also { it.draftEnabled = true; it.loadDraft() } }
            EditorScreen(model, null) { nav.popBackStack() }
        }
        composable("cover/{uri}") { e ->
            GodCoverScreen(Uri.parse(e.arguments?.getString("uri"))) { nav.popBackStack() }
        }
        composable("studio/{uri}") { e ->
            StudioScreen(Uri.parse(e.arguments?.getString("uri"))) { nav.popBackStack() }
        }
        composable("raw") {
            RawScreen(onEdit = { f -> nav.navigate("editorFile/${enc(f.absolutePath)}") }, onClose = { nav.popHome() })
        }
        composable("batch/{style}") { e ->
            val id = e.arguments?.getString("style")
            BatchStyleScreen(id) { nav.popBackStack() }
        }
        composable("favoriteFace") { FavoriteFaceScreen { nav.popHome() } }
        composable("manga") { MangaScreen { nav.popHome() } }
        composable("history") {
            HistoryScreen(
                onEdit = { f -> nav.navigate("editorFile/${enc(f.absolutePath)}") },
                onApply = { id -> nav.navigate("picker/recipe/${enc(id)}") },
                onBatch = { id -> nav.navigate("batch/${enc(id)}") },
                onClose = { nav.popHome() },
            )
        }
    }
}

private fun NavHostController.popHome() {
    popBackStack("home", inclusive = false)
}
