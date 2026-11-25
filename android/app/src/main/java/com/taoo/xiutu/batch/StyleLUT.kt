package com.taoo.xiutu.batch

import android.graphics.Bitmap
import android.util.Half
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.gpu.Gpu
import com.taoo.xiutu.gpu.GpuScope
import com.taoo.xiutu.gpu.Shaders
import com.taoo.xiutu.gpu.Tex
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import kotlin.math.max

/**
 * 比较"原图"和"AI 调过色的图"，算出一张整图通用的颜色对照表，再套回原图。
 * 整张照片同一种颜色永远变成同一种颜色，像换了一卷胶片：没有局部光晕，清晰度和纹理全是原图的。
 */
object StyleLUT {
    const val SIZE = 25
    private const val COUNT = SIZE * SIZE * SIZE

    /** 两张图要对齐（同样的构图）；大小可以不一样。返回 SIZE³ × 3 个数（r 变得最快）。 */
    fun fit(original: Bitmap, graded: Bitmap): FloatArray? {
        val k = 420f / max(original.width, original.height)
        val w = max(8, (original.width * k).toInt())
        val h = max(8, (original.height * k).toInt())
        return fit(pixels(original, w, h), pixels(graded, w, h), w, h)
    }

    private fun pixels(b: Bitmap, w: Int, h: Int): FloatArray {
        val s = Img.scaled(Img.downscale(Img.soft(b), max(w, h)), w, h)
        val px = IntArray(w * h)
        s.getPixels(px, 0, w, 0, 0, w, h)
        val out = FloatArray(w * h * 3)
        for (i in px.indices) {
            val p = px[i]
            out[i * 3] = (p shr 16 and 255) / 255f
            out[i * 3 + 1] = (p shr 8 and 255) / 255f
            out[i * 3 + 2] = (p and 255) / 255f
        }
        return out
    }

    private fun index(r: Int, g: Int, b: Int) = (b * SIZE + g) * SIZE + r

    /** a、b：原图和调过色的图，每像素 r、g、b 三个 0...1 的数。 */
    internal fun fit(a: FloatArray, b: FloatArray, w: Int, h: Int): FloatArray? {
        val n = SIZE
        val delta = FloatArray(COUNT * 3)
        val weight = FloatArray(COUNT)
        // 局部起伏大的地方（边缘、树叶）AI 图容易对不齐，权重放低。
        for (y in 1 until h - 1) {
            for (x in 1 until w - 1) {
                val i = (y * w + x) * 3
                val cr = a[i]
                val cg = a[i + 1]
                val cb = a[i + 2]
                var edge = 0f
                for (s in 0 until 4) {
                    val j = when (s) { 0 -> i - 3; 1 -> i + 3; 2 -> i - w * 3; else -> i + w * 3 }
                    edge = max(edge, max(abs(a[j] - cr), max(abs(a[j + 1] - cg), abs(a[j + 2] - cb))))
                }
                val trust = 1f / (1f + edge * edge * 160f)
                val pr = cr * (n - 1)
                val pg = cg * (n - 1)
                val pb = cb * (n - 1)
                val r0 = minOf(pr.toInt(), n - 2)
                val g0 = minOf(pg.toInt(), n - 2)
                val b0 = minOf(pb.toInt(), n - 2)
                val fr = pr - r0
                val fg = pg - g0
                val fb = pb - b0
                for (corner in 0 until 8) {
                    val dr = corner and 1
                    val dg = corner shr 1 and 1
                    val db = corner shr 2
                    val t = (if (dr == 1) fr else 1 - fr) * (if (dg == 1) fg else 1 - fg) * (if (db == 1) fb else 1 - fb) * trust
                    val at = index(r0 + dr, g0 + dg, b0 + db)
                    delta[at * 3] += (b[i] - cr) * t
                    delta[at * 3 + 1] += (b[i + 1] - cg) * t
                    delta[at * 3 + 2] += (b[i + 2] - cb) * t
                    weight[at] += t
                }
            }
        }
        for (i in 0 until COUNT) if (weight[i] > 0) for (c in 0..2) delta[i * 3 + c] /= weight[i]

        // 照片里没有的颜色跟着最接近的颜色走；有的颜色也稍微和邻居拉平，过渡才顺。
        var out = delta
        val known = FloatArray(COUNT) { weight[it] / (weight[it] + 3) }
        // 完全没数据的格子先从最近的有数据格子往外填。
        var filled = BooleanArray(COUNT) { weight[it] > 0.05f }
        if (filled.none { it }) return null
        while (filled.any { !it }) {
            val next = filled.copyOf()
            each { r0, g0, b0, i ->
                if (!filled[i]) {
                    var x = 0f
                    var y = 0f
                    var z = 0f
                    var c = 0f
                    around(r0, g0, b0) { j ->
                        if (filled[j]) { x += out[j * 3]; y += out[j * 3 + 1]; z += out[j * 3 + 2]; c += 1f }
                    }
                    if (c > 0) {
                        out[i * 3] = x / c
                        out[i * 3 + 1] = y / c
                        out[i * 3 + 2] = z / c
                        next[i] = true
                        known[i] = 0f
                    }
                }
            }
            filled = next
        }
        val anchor = out.copyOf()
        repeat(40) {
            val next = FloatArray(COUNT * 3)
            each { r0, g0, b0, i ->
                var x = 0f
                var y = 0f
                var z = 0f
                var c = 0f
                around(r0, g0, b0) { j -> x += out[j * 3]; y += out[j * 3 + 1]; z += out[j * 3 + 2]; c += 1f }
                val k = known[i]
                next[i * 3] = anchor[i * 3] * k + x / c * (1 - k)
                next[i * 3 + 1] = anchor[i * 3 + 1] * k + y / c * (1 - k)
                next[i * 3 + 2] = anchor[i * 3 + 2] * k + z / c * (1 - k)
            }
            out = next
        }
        // 有数据的格子再轻轻抹一遍，去掉个别颜色跳动。
        repeat(2) {
            val next = FloatArray(COUNT * 3)
            each { r0, g0, b0, i ->
                var x = out[i * 3] * 2
                var y = out[i * 3 + 1] * 2
                var z = out[i * 3 + 2] * 2
                var c = 2f
                around(r0, g0, b0) { j -> x += out[j * 3] * 0.5f; y += out[j * 3 + 1] * 0.5f; z += out[j * 3 + 2] * 0.5f; c += 0.5f }
                next[i * 3] = x / c
                next[i * 3 + 1] = y / c
                next[i * 3 + 2] = z / c
            }
            out = next
        }
        val cube = FloatArray(COUNT * 3)
        val inv = 1f / (n - 1)
        each { r0, g0, b0, i ->
            // 变化太猛的压住：单个颜色最多挪 0.3，避免夸张。
            val reach = max(abs(out[i * 3]), max(abs(out[i * 3 + 1]), abs(out[i * 3 + 2])))
            val k = if (reach > 0.3f) 0.3f / reach else 1f
            cube[i * 3] = (r0 * inv + out[i * 3] * k).coerceIn(0f, 1f)
            cube[i * 3 + 1] = (g0 * inv + out[i * 3 + 1] * k).coerceIn(0f, 1f)
            cube[i * 3 + 2] = (b0 * inv + out[i * 3 + 2] * k).coerceIn(0f, 1f)
        }
        return cube
    }

    private inline fun each(f: (r: Int, g: Int, b: Int, i: Int) -> Unit) {
        var i = 0
        for (b in 0 until SIZE) for (g in 0 until SIZE) for (r in 0 until SIZE) f(r, g, b, i++)
    }

    private inline fun around(r: Int, g: Int, b: Int, f: (Int) -> Unit) {
        if (r > 0) f(index(r - 1, g, b))
        if (r < SIZE - 1) f(index(r + 1, g, b))
        if (g > 0) f(index(r, g - 1, b))
        if (g < SIZE - 1) f(index(r, g + 1, b))
        if (b > 0) f(index(r, g, b - 1))
        if (b < SIZE - 1) f(index(r, g, b + 1))
    }

    /** CPU 上查表（三线性），和着色器一样；验证用。 */
    internal fun map(cube: FloatArray, r: Float, g: Float, b: Float): FloatArray {
        val n = SIZE - 1
        val p = floatArrayOf(r * n, g * n, b * n)
        val lo = IntArray(3) { minOf(p[it].toInt(), n - 1) }
        val f = FloatArray(3) { p[it] - lo[it] }
        val out = FloatArray(3)
        for (corner in 0 until 8) {
            val dr = corner and 1
            val dg = corner shr 1 and 1
            val db = corner shr 2
            val t = (if (dr == 1) f[0] else 1 - f[0]) * (if (dg == 1) f[1] else 1 - f[1]) * (if (db == 1) f[2] else 1 - f[2])
            val i = index(lo[0] + dr, lo[1] + dg, lo[2] + db)
            for (c in 0..2) out[c] += cube[i * 3 + c] * t
        }
        return out
    }

    fun apply(cube: FloatArray, image: Bitmap, strength: Float): Bitmap {
        if (strength <= 0.005f) return image
        return Gpu.run {
            val s = upload(image)
            read(pass(APPLY, mapOf("src" to s, "cube" to table(this, cube)), mapOf("t" to if (strength >= 0.995f) 1f else strength), s.width, s.height))
        }
    }

    /** 按 b 把每一层横着排开：宽 SIZE²、高 SIZE 的半精度纹理。 */
    private fun table(g: GpuScope, cube: FloatArray): Tex {
        val w = SIZE * SIZE
        val buf = ByteBuffer.allocateDirect(w * SIZE * 4 * 2).order(ByteOrder.nativeOrder())
        val out = buf.asShortBuffer()
        val one = Half.toHalf(1f)
        for (y in 0 until SIZE) for (b in 0 until SIZE) for (r in 0 until SIZE) {
            val i = index(r, y, b) * 3
            for (c in 0..2) out.put(Half.toHalf(cube[i + c]))
            out.put(one)
        }
        return g.uploadHalf(buf, w, SIZE, channels = 4)
    }

    private const val APPLY = Shaders.HEADER + """
uniform sampler2D src;
uniform sampler2D cube;
uniform float t;
const float N = 25.0;
vec3 slice(float b, vec2 rg) {
    return texture(cube, vec2((b * N + rg.x * (N - 1.0) + 0.5) / (N * N), (rg.y * (N - 1.0) + 0.5) / N)).rgb;
}
void main() {
    vec4 s = texture(src, uv);
    vec3 c = clamp(s.rgb, 0.0, 1.0);
    float b = c.b * (N - 1.0);
    float b0 = min(floor(b), N - 2.0);
    vec3 v = mix(slice(b0, c.rg), slice(b0 + 1.0, c.rg), b - b0);
    o = vec4(mix(s.rgb, v, t), s.a);
}
"""
}
