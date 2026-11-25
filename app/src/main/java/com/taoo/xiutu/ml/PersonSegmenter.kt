package com.taoo.xiutu.ml

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.segmentation.Segmentation
import com.google.mlkit.vision.segmentation.selfie.SelfieSegmenterOptions
import com.taoo.xiutu.core.Img
import java.nio.ByteOrder
import java.util.concurrent.TimeUnit

/**
 * 人像分割（ML Kit 自拍分割，全部在本机完成）。
 * mask 返回和输入一样大的不透明灰度图（ARGB_8888，R=G=B）：白 = 人，黑 = 背景。几乎找不到人时返回 null。
 * 会阻塞，必须在后台线程调用。
 */
object PersonSegmenter {
    private val lock = Any()

    fun mask(bitmap: Bitmap): Bitmap? = maskData(bitmap)?.toGrayBitmap()

    /** 只留最大的一块和跟它差不多大的：建筑、花纹上零星误认成人的不要。 */
    fun main(mask: Mask8): Mask8 {
        val w = 192
        val h = 192
        val px = Mask8.resized(mask, w, h)
        val label = IntArray(w * h)
        val sizes = arrayListOf(0)
        val stack = IntArray(w * h)
        for (start in 0 until w * h) {
            if (px[start] <= 70 || label[start] != 0) continue
            val id = sizes.size
            sizes += 0
            var top = 0
            stack[top++] = start
            label[start] = id
            var n = 0
            while (top > 0) {
                val i = stack[--top]
                n++
                val x = i % w
                val y = i / w
                fun visit(nx: Int, ny: Int) {
                    if (nx !in 0 until w || ny !in 0 until h) return
                    val j = ny * w + nx
                    if (px[j] > 70 && label[j] == 0) { label[j] = id; stack[top++] = j }
                }
                visit(x - 1, y); visit(x + 1, y); visit(x, y - 1); visit(x, y + 1)
            }
            sizes[id] = n
        }
        val biggest = sizes.max()
        if (biggest <= 0) return mask
        // 往外扩两格，别把边缘的半透明切掉。
        val keep = ByteArray(w * h)
        for (y in 0 until h) for (x in 0 until w) {
            val l = label[y * w + x]
            if (l == 0 || sizes[l] * 4 < biggest) continue
            for (ny in maxOf(0, y - 2)..minOf(h - 1, y + 2)) for (nx in maxOf(0, x - 2)..minOf(w - 1, x + 2)) keep[ny * w + nx] = -1
        }
        val gate = Mask8.resized(Mask8(keep, w, h), mask.w, mask.h)
        return Mask8(ByteArray(mask.w * mask.h) { (mask[it] * gate[it] / 255).toByte() }, mask.w, mask.h)
    }

    /** 同上，但返回 8 位数据（省一次转换）。 */
    fun maskData(bitmap: Bitmap): Mask8? = synchronized(lock) {
        runCatching {
            val input = Img.soft(bitmap)
            val options = SelfieSegmenterOptions.Builder()
                .setDetectorMode(SelfieSegmenterOptions.SINGLE_IMAGE_MODE)
                .build()
            val client = Segmentation.getClient(options)
            try {
                val result = Tasks.await(client.process(InputImage.fromBitmap(input, 0)), 30, TimeUnit.SECONDS)
                val w = result.width
                val h = result.height
                val buf = result.buffer.order(ByteOrder.nativeOrder())
                buf.rewind()
                val floats = buf.asFloatBuffer()
                val px = ByteArray(w * h) { (floats.get(it).coerceIn(0f, 1f) * 255f + 0.5f).toInt().toByte() }
                var m = Mask8(px, w, h)
                if (w != input.width || h != input.height) m = Mask8.resized(m, input.width, input.height)
                // 几乎没有白色就当作没找到人
                val small = Mask8.resized(m, 64, 64)
                var found = 0
                for (i in 0 until 64 * 64) if (small[i] > 128) found++
                if (found * 200 > 64 * 64) m else null
            } finally {
                client.close()
            }
        }.getOrNull()
    }
}
