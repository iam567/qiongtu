package com.taoo.xiutu.ai.outfit

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.LruCache
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.ai.ChangeKeep
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.ml.PersonSegmenter
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.util.UUID
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

/** 衣橱里的一身衣服：从照片里抠下来的图（最多三个角度）加一份详细说明，换到别的照片上时照着来。 */
@Serializable
data class WardrobeItem(
    val id: String,
    val name: String,
    val date: Long,
    /** AI 写的款式说明；还没写好是空的。 */
    val desc: String = "",
    /** 存了几张图（0.jpg、1.jpg……）。 */
    val count: Int = 0,
)

/** 我的衣橱，图在 App 私有目录里。只在主线程上改。 */
object WardrobeStore {
    /** 新的在前。 */
    var items by mutableStateOf<List<WardrobeItem>>(emptyList())
        private set

    private var folder: File? = null
    private val cache = LruCache<String, Bitmap>(16)
    private val json = Json { ignoreUnknownKeys = true }

    fun init(context: Context) {
        if (folder != null) return
        val dir = File(context.filesDir, "Wardrobe").apply { mkdirs() }
        folder = dir
        items = runCatching { json.decodeFromString<List<WardrobeItem>>(File(dir, "index.json").readText()) }
            .getOrDefault(emptyList()).filter { file(it.id, 0).exists() }
    }

    private fun file(id: String, i: Int) = File(folder, "$id-$i.jpg")

    private fun save() {
        val dir = folder ?: return
        val tmp = File(dir, "index.json.tmp")
        runCatching {
            tmp.writeText(json.encodeToString(items))
            tmp.renameTo(File(dir, "index.json"))
        }
    }

    fun find(id: String) = items.firstOrNull { it.id == id }

    /** 读图（第一次要解码，在后台线程调用）。 */
    fun image(item: WardrobeItem, i: Int = 0): Bitmap? {
        val key = "${item.id}-$i"
        return cache.get(key) ?: Img.decode(file(item.id, i))?.also { cache.put(key, it) }
    }

    /** 发给 AI 的参考图。在后台线程调用。 */
    fun references(item: WardrobeItem): List<Bitmap> = (0 until item.count).mapNotNull { image(item, it) }

    fun add(images: List<ByteArray>): WardrobeItem? {
        if (images.isEmpty()) return null
        val used = items.map { it.name }.toSet()
        var n = items.size + 1
        while ("衣服 $n" in used) n++
        val id = UUID.randomUUID().toString()
        var count = 0
        for (data in images) if (runCatching { file(id, count).writeBytes(data) }.isSuccess) count++
        if (count == 0) return null
        val item = WardrobeItem(id, "衣服 $n", System.currentTimeMillis(), count = count)
        items = listOf(item) + items
        save()
        return item
    }

    /** 补一个角度（最多三张图）。 */
    fun addAngle(id: String, data: ByteArray): Boolean {
        val item = find(id) ?: return false
        if (item.count >= 3 || runCatching { file(id, item.count).writeBytes(data) }.isFailure) return false
        items = items.map { if (it.id == id) it.copy(count = it.count + 1) else it }
        save()
        return true
    }

    fun update(id: String, desc: String? = null, name: String? = null) {
        val text = name?.trim().orEmpty()
        items = items.map {
            if (it.id != id) it else it.copy(desc = desc ?: it.desc, name = text.ifEmpty { it.name })
        }
        save()
    }

    fun remove(item: WardrobeItem) {
        for (i in 0 until 3) {
            file(item.id, i).delete()
            cache.remove("${item.id}-$i")
        }
        items = items.filter { it.id != item.id }
        save()
    }
}

object Wardrobe {
    /** 从照片里抠出穿着的衣服：全身一张、上半身细节一张，灰底，头去掉。认不出人返回空。在后台线程调用。 */
    fun cutouts(image: Bitmap): List<ByteArray> {
        val mask = PersonSegmenter.maskData(Img.downscale(image, 1024))?.let { PersonSegmenter.main(it) } ?: return emptyList()
        val box = bounds(mask) ?: return emptyList()
        val w = image.width
        val h = image.height
        val gray = Color.rgb(209, 209, 209)
        val cut = Gpu.run {
            val back = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888).apply { eraseColor(gray) }
            val photo = upload(image)
            val fill = pass(com.taoo.xiutu.gpu.Shaders.COPY, mapOf("src" to upload(back)), width = w, height = h)
            read(ChangeKeep.blend(this, fill, photo, upload(mask.toGrayBitmap())))
        }
        val c = Canvas(cut)
        val paint = Paint().apply { color = gray }
        val faces = FaceDetector.detect(image)
        for (f in faces) {
            val b = f.box
            val chin = f.contour.maxOfOrNull { it.y } ?: b.bottom
            c.drawRect((b.centerX() - b.width() * 0.95f) * w, (b.top - b.height() * 1.1f) * h, (b.centerX() + b.width() * 0.95f) * w, chin * h, paint)
        }
        fun piece(r: RectF): ByteArray? {
            val x0 = floor(r.left * w).toInt().coerceIn(0, w)
            val y0 = floor(r.top * h).toInt().coerceIn(0, h)
            val x1 = ceil(r.right * w).toInt().coerceIn(0, w)
            val y1 = ceil(r.bottom * h).toInt().coerceIn(0, h)
            if (x1 - x0 <= 60 || y1 - y0 <= 60) return null
            val p = Bitmap.createBitmap(cut, x0, y0, x1 - x0, y1 - y0).apply { setHasAlpha(false) }
            return Img.jpeg(Img.downscale(p, 1600), 93)
        }
        val fw = box[2] - box[0]
        val fh = box[3] - box[1]
        val full = RectF(max(box[0] - fw * 0.03f, 0f), max(box[1] - fh * 0.02f, 0f), min(box[2] + fw * 0.03f, 1f), min(box[3] + fh * 0.02f, 1f))
        // 上半身：下巴往下一截，看清领口、袖子和装饰。
        val upper = faces.maxByOrNull { it.box.width() }?.let { f ->
            val uh = max(f.box.height() * 4.2f, 0.05f)
            val uw = f.box.width() * 5.5f
            val top = f.box.bottom - f.box.height() * 0.1f
            RectF(max(f.box.centerX() - uw / 2, 0f), max(top, 0f), min(f.box.centerX() + uw / 2, 1f), min(top + uh, 1f))
        } ?: RectF(full.left, full.top, full.right, full.top + full.height() * 0.5f)
        return listOfNotNull(piece(full), piece(upper))
    }

    /** 人的范围：左、上、右、下（归一化）。 */
    internal fun bounds(mask: Mask8): FloatArray? {
        val n = 160
        val m = Mask8.resized(mask, n, n)
        var x0 = n
        var x1 = -1
        var y0 = n
        var y1 = -1
        for (y in 0 until n) for (x in 0 until n) if (m[y * n + x] > 110) {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        if (x1 <= x0 || y1 <= y0) return null
        return floatArrayOf(x0 / n.toFloat(), y0 / n.toFloat(), (x1 + 1) / n.toFloat(), (y1 + 1) / n.toFloat())
    }

    const val DESCRIBE_PROMPT = "图里是一身衣服（头已经去掉）。请像服装设计师写工艺单一样，把它写清楚，好让另一个人在别的照片里做出一模一样的一件。" +
        "按顺序写：整体款式和廓形；主色和配色（尽量具体到色调）；面料和光泽；领口和肩；袖子（长度、形状、袖口）；上身和腰（结构、系带、扣子、腰带）；" +
        "裙身或下装（层次、褶皱、长度、裙撑、裙摆）；图案和刺绣是什么样、分布在哪里；装饰（花、蝴蝶结、珠宝、蕾丝）各在什么位置、多大、什么颜色；手套、鞋等配饰（看得见才写）。" +
        "只写看得见的，不写人、不写姿势、不写背景。不超过 350 个字，直接写，不要标题和列表。"

    /** 照着衣橱里的这身衣服换。 */
    fun prompt(item: WardrobeItem, skirt: OutfitSkirt): String =
        "把第一张图里主要人物的衣服换成参考图里的那一身。参考图（第二张起）是同一身衣服的全身和细节，头已经去掉，灰底只是背景。" +
            (if (item.desc.isEmpty()) "" else "这身衣服的样子：${item.desc.trimEnd('。')}。") +
            "必须和参考图是同一件：款式、颜色、面料、图案、刺绣、每一处装饰的样子和位置都一致，不要改设计、不要增减装饰。" +
            "这张照片里人的姿势、角度和参考图不同：衣服随姿势自然变化，参考图里看不到的部分（侧面、背面）按同一个设计合理延续；光线和明暗按第一张图的现场来，但衣服本身的颜色不变。" +
            "不要把参考图里的身材、姿势、灰色背景搬过来。" + skirt.prompt + OutfitCatalog.CLEAN + OutfitCatalog.KEEP
}
