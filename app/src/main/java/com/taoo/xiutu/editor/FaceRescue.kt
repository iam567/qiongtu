package com.taoo.xiutu.editor

import android.graphics.Bitmap
import android.graphics.PointF
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ai.AIClient
import com.taoo.xiutu.ai.AIError
import com.taoo.xiutu.ai.AIOneShot
import com.taoo.xiutu.ai.AISettings
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.FaceFinder
import com.taoo.xiutu.ml.FaceInfo
import com.taoo.xiutu.tools.smartcrop.SmartCrop
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.abs

/** 要用到脸的工具（美颜、面部重塑、美妆、皮肤）。 */
interface FaceSeeker {
    /** 现在没有脸可用。 */
    val lacksFace: Boolean

    /** 有了用户点的、AI 指的脸：重新找一遍。 */
    fun redetectFaces()
}

/** 找脸：先用预览图，找不到就用大图放大找；还找不到就让用户点、让 AI 指。 */
class FaceSearch(private val model: EditorModel) {
    var busy by mutableStateOf(false)
        private set
    var error by mutableStateOf<String?>(null)
        private set

    /** 用户点的、AI 指出来的脸（画布大小没变就一直用）。 */
    private var forced: List<FaceInfo> = emptyList()
    private var forcedSize: Pair<Int, Int>? = null

    private fun baseSize() = model.base?.let { it.width to it.height }

    /** 给工具用：用户点的、AI 指的脸优先。 */
    suspend fun find(): List<FaceInfo> {
        if (forced.isNotEmpty() && forcedSize == baseSize()) return forced
        val base = model.base ?: return emptyList()
        return withContext(Dispatchers.Default) {
            runCatching {
                FaceDetector.direct(base).ifEmpty {
                    val big = source() ?: return@ifEmpty emptyList()
                    FaceDetector.direct(big).ifEmpty { FaceFinder.deep(big, thorough = true) }
                }
            }.onFailure { it.printStackTrace() }.getOrDefault(emptyList())
        }
    }

    /** 找脸用的大图（最长 4096）。在后台线程调用。 */
    private fun source(): Bitmap? {
        val base = model.base ?: return null
        val proxy = model.proxy ?: return base
        val big = runCatching { EditOp.applyAll(model.photoOps, proxy) }.getOrNull() ?: return base
        // 正在改历史中间的某一步时画布可能不一样，比例对不上就只用预览图
        val same = abs(big.width.toFloat() / big.height - base.width.toFloat() / base.height) < 0.01f
        return if (same) big else base
    }

    /** 找不到脸时点了画面：就当脸在那儿。返回 true = 处理了这次点击。 */
    fun tap(p: PointF): Boolean {
        val seeker = model.session as? FaceSeeker ?: return false
        if (!seeker.lacksFace || busy) return false
        busy = true
        error = null
        val session = model.session
        model.scope.launch {
            val face = withContext(Dispatchers.Default) { runCatching { source()?.let { FaceFinder.at(p, it) } }.getOrNull() }
            busy = false
            if (face != null && model.session === session) use(listOf(face))
        }
        return true
    }

    /** 让能看图的 AI 指出脸在哪儿。 */
    fun askAI() {
        if (busy) return
        val endpoint = AISettings.endpoint() ?: run {
            error = "还没有设置 ${AISettings.active.shortTitle} 的 API Key。"
            return
        }
        busy = true
        error = null
        val session = model.session
        model.scope.launch {
            try {
                val big = withContext(Dispatchers.Default) { source() } ?: throw AIError("图片读不出来。")
                val jpeg = withContext(Dispatchers.Default) { Img.jpeg(AIOneShot.prepared(big, 2048), 88) }
                val text = AIClient.look(endpoint, FaceFinder.PROMPT, jpeg)
                val boxes = SmartCrop.boxes(text, "faces")
                if (boxes.isEmpty()) throw AIError("AI 也没有找到人脸，可以直接点一下脸的位置。")
                val found = withContext(Dispatchers.Default) {
                    boxes.map { FaceFinder.refine(android.graphics.RectF(it.x, it.y, it.maxX, it.maxY), big) }
                }
                if (model.session === session) use(found.sortedByDescending { it.box.width() * it.box.height() })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Throwable) {
                error = (e as? AIError)?.text ?: e.message ?: "请求失败。"
            } finally {
                busy = false
            }
        }
    }

    private fun use(faces: List<FaceInfo>) {
        forced = faces
        forcedSize = baseSize()
        (model.session as? FaceSeeker)?.redetectFaces()
    }
}

/** 没找到脸时面板里显示的：原因，加"AI 找脸"。画面上点一下脸的位置也可以。 */
@Composable
fun FaceRescue(model: EditorModel, message: String) {
    val search = model.faceSearch
    Column(
        Modifier.fillMaxWidth().padding(vertical = 20.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (search.busy) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Text("正在找人脸…", fontSize = 14.sp, color = Color.White)
            }
            return@Column
        }
        Text(
            search.error ?: "$message，可以点一下脸的位置，或者让 AI 找", fontSize = 13.sp, color = Color(1f, 0.45f, 0.4f), textAlign = TextAlign.Center,
        )
        Box {
            Row(
                Modifier.height(40.dp).clip(CircleShape).background(Theme.accent).press { search.askAI() }.padding(horizontal = 26.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(sym("face.dashed"), null, tint = Color.Black, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
                Text("AI 找脸", fontSize = 14.sp, fontWeight = FontWeight.Bold, color = Color.Black)
            }
            CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-5).dp))
        }
    }
}
