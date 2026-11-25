package com.taoo.xiutu.batch

import android.content.Context
import android.graphics.Bitmap
import android.util.LruCache
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.core.Img
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID

/** 存下来的一种照片风格：就是一张修好的图，批量统一风格时给 AI 当参考。date 是毫秒时间戳。 */
@Serializable
data class SavedStyle(val id: String, val name: String, val date: Long)

/** 存好的风格，图在 App 私有目录里。只在主线程上改。 */
object StyleStore {
    /** 新的在前。 */
    var styles by mutableStateOf<List<SavedStyle>>(emptyList())
        private set

    private var folder: File? = null
    private val cache = LruCache<String, Bitmap>(12)
    private val json = Json { ignoreUnknownKeys = true }

    fun init(context: Context) {
        if (folder != null) return
        val dir = File(context.filesDir, "Styles").apply { mkdirs() }
        folder = dir
        styles = runCatching { json.decodeFromString<List<SavedStyle>>(File(dir, "index.json").readText()) }
            .getOrDefault(emptyList()).filter { file(it.id).exists() }
    }

    private fun file(id: String) = File(folder, "$id.jpg")

    private fun save() {
        val dir = folder ?: return
        val tmp = File(dir, "index.json.tmp")
        runCatching {
            tmp.writeText(json.encodeToString(styles))
            tmp.renameTo(File(dir, "index.json"))
        }
    }

    /** 读风格图（第一次要解码，在后台线程调用）。 */
    fun image(style: SavedStyle): Bitmap? =
        cache.get(style.id) ?: Img.decode(file(style.id))?.also { cache.put(style.id, it) }

    /** 从一张图存成风格：缩到最长 1600。decode 在后台线程跑。 */
    suspend fun add(decode: () -> Bitmap?): SavedStyle? {
        val jpeg = withContext(Dispatchers.Default) {
            runCatching { decode()?.let { Img.jpeg(Img.downscale(it, SIDE), 92) } }.getOrNull()
        } ?: return null
        val used = styles.map { it.name }.toSet()
        var n = styles.size + 1
        while ("风格 $n" in used) n++
        val style = SavedStyle(UUID.randomUUID().toString(), "风格 $n", System.currentTimeMillis())
        val ok = withContext(Dispatchers.IO) { runCatching { file(style.id).writeBytes(jpeg) }.isSuccess }
        if (!ok) return null
        styles = listOf(style) + styles
        save()
        return style
    }

    suspend fun add(file: File): SavedStyle? = add { Img.decode(file, SIDE) }

    fun rename(style: SavedStyle, name: String) {
        val text = name.trim()
        if (text.isEmpty()) return
        styles = styles.map { if (it.id == style.id) it.copy(name = text) else it }
        save()
    }

    fun remove(style: SavedStyle) {
        file(style.id).delete()
        cache.remove(style.id)
        styles = styles.filter { it.id != style.id }
        save()
    }

    const val SIDE = 1600
}
