package com.taoo.xiutu.tools.smartcrop

import com.taoo.xiutu.tools.crop.CropRect
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** 智能构图找到的一个取景。original = AI 给的框（归一化，左上原点）；rect = 现在的框（换了比例、手动拖过）。 */
data class SmartCropItem(
    val id: Int,
    val title: String,
    /** 构图手法。 */
    val how: String,
    val why: String,
    val original: CropRect,
    val rect: CropRect,
)

enum class SmartCropRatio(val title: String) {
    FREE("自由"), ORIGINAL("原比例"), PORTRAIT("竖 4:5"), LANDSCAPE("横 3:2"), SQUARE("方形"), WIDE("宽 16:9");

    /** 宽 / 高；null = 不限。 */
    fun value(w: Float, h: Float): Float? = when (this) {
        FREE -> null
        ORIGINAL -> w / max(h, 1f)
        PORTRAIT -> 0.8f
        LANDSCAPE -> 1.5f
        SQUARE -> 1f
        WIDE -> 16f / 9
    }
}

/** 智能构图：让能看图的 AI 从一张大图里找出几个好看的取景。只要坐标，画面从原图上裁，不重画。 */
object SmartCrop {
    fun prompt(width: Int, height: Int, minimum: Float, hint: String = "", again: Boolean): String {
        val least = ceil(minimum * 1000).toInt()
        val extra = if (hint.isEmpty()) "" else "\n6. 另外：$hint"
        val more = if (again) "\n这是第二次找，换一些不常规的角度和局部，不要只给最显眼的。" else ""
        return """
            你是资深图片编辑，负责从一张高像素照片里找出值得单独成片的取景。这张照片原始大小 $width×$height 像素。
            请找出 6 到 8 个最好的裁切取景，按好看程度从高到低排。要求：
            1. 每一个单独看都是一张成立的好照片：主体清楚，边缘干净，留白合理，视线方向留空，不要切在人的关节、手指、脸或头顶上，不要切断重要的东西。
            2. 彼此差别明显：有大场面，也有中景、特写和不起眼但好看的小局部；横、竖、方都要有；不要只是同一个框大一点小一点。
            3. 善用三分法、对称、引导线、框架、前景、留白、重复、色块、光影对比这些手法。
            4. 每个框的宽和高都不小于 $least（按下面的千分坐标），整个框在照片里面。
            5. 最好的那一个不一定是最大的。@EXTRA@
            坐标用千分比：照片左上角是 (0,0)，右下角是 (1000,1000)，box 依次是 左、上、右、下。
            只输出 JSON，不要别的字：{"crops":[{"title":"不超过6个字的名字","how":"用了什么构图手法，不超过6个字","why":"好在哪，不超过20个字","box":[左,上,右,下]}]}
        """.trimIndent().replace("@EXTRA@", extra + more)
    }

    /** 从 AI 的回复里读出取景。坐标不对、太小、和前面几乎一样的不要。 */
    fun parse(text: String, minimum: Float): List<SmartCropItem> {
        val json = jsonIn(text) ?: return emptyList()
        fun objects(e: JsonElement?): List<JsonObject>? {
            val a = e as? JsonArray ?: return null
            return if (a.all { it is JsonObject }) a.map { it as JsonObject } else null
        }
        val list = when (json) {
            is JsonObject -> objects(json["crops"]) ?: json.values.firstNotNullOfOrNull { objects(it) } ?: emptyList()
            else -> objects(json) ?: emptyList()
        }
        val out = ArrayList<SmartCropItem>()
        for (item in list) {
            var box = numbers(item["box"])
            if (box.size != 4) {
                // Gemini 习惯的写法：上、左、下、右。
                val yx = numbers(item["box_2d"])
                if (yx.size == 4) box = listOf(yx[1], yx[0], yx[3], yx[2])
            }
            if (box.size != 4) continue
            // 有的模型会给 0~1 的小数。
            val k = if (box.max() <= 1.001f) 1f else 1000f
            val x0 = (min(box[0], box[2]) / k).coerceIn(0f, 1f)
            val x1 = (max(box[0], box[2]) / k).coerceIn(0f, 1f)
            val y0 = (min(box[1], box[3]) / k).coerceIn(0f, 1f)
            val y1 = (max(box[1], box[3]) / k).coerceIn(0f, 1f)
            val rect = CropRect(x0, y0, x1 - x0, y1 - y0)
            if (rect.w < minimum * 0.8f || rect.h < minimum * 0.8f || rect.w * rect.h >= 0.97f) continue
            if (out.any { overlap(it.rect, rect) > 0.82f }) continue
            out += SmartCropItem(
                out.size, short(item["title"], 8, "取景 ${out.size + 1}"), short(item["how"], 8, ""), short(item["why"], 40, ""), rect, rect,
            )
        }
        return out
    }

    private fun short(value: JsonElement?, limit: Int, fallback: String): String {
        val text = (value as? JsonPrimitive)?.takeIf { it.isString }?.content?.trim().orEmpty()
        return if (text.isEmpty()) fallback else text.take(limit)
    }

    private fun numbers(value: JsonElement?): List<Float> =
        (value as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.content?.toDoubleOrNull()?.toFloat() }

    /** 回复里可能夹着思考过程或 ``` 代码块：从后往前找能解析的那一段。 */
    private fun jsonIn(text: String): JsonElement? {
        fun parse(s: String): JsonElement? =
            runCatching { Json.parseToJsonElement(s) }.getOrNull()?.takeIf { it is JsonObject || it is JsonArray }
        parse(text)?.let { return it }
        val end = text.lastIndexOf('}')
        if (end < 0) return null
        var start = text.indexOf("{\"crops\"").takeIf { it >= 0 } ?: text.indexOf('{')
        while (start in 0 until end) {
            parse(text.substring(start, end + 1))?.let { return it }
            start = text.indexOf('{', start + 1)
        }
        return null
    }

    private fun overlap(a: CropRect, b: CropRect): Float {
        val w = min(a.maxX, b.maxX) - max(a.x, b.x)
        val h = min(a.maxY, b.maxY) - max(a.y, b.y)
        if (w <= 0 || h <= 0) return 0f
        val area = w * h
        return area / (a.w * a.h + b.w * b.h - area)
    }

    /** 把框改成指定比例：以原来的框为中心，面积差不多，不出照片。 */
    fun fit(rect: CropRect, ratio: Float?, width: Float, height: Float): CropRect {
        if (ratio == null || width <= 0 || height <= 0) return rect
        // 归一化坐标里的宽高比。
        val a = ratio * height / width
        val area = rect.w * rect.h
        var h = sqrt(area / a)
        var w = h * a
        val k = min(1f, min(1 / w, 1 / h))
        w *= k
        h *= k
        val cx = rect.x + rect.w / 2
        val cy = rect.y + rect.h / 2
        return CropRect(min(max(cx - w / 2, 0f), 1 - w), min(max(cy - h / 2, 0f), 1 - h), w, h)
    }
}
