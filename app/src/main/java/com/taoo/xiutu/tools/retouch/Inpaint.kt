package com.taoo.xiutu.tools.retouch

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * 本机的智能消除：用周围的纹理把涂掉的地方补上（PatchMatch，多尺度）。照搬 iOS Inpaint.swift，参数一样。
 * 在后台线程调用。
 */
object Inpaint {
    /** 一张浮点图。 */
    private class Plane(val w: Int, val h: Int) {
        val rgb = FloatArray(w * h * 3)
        var hole = BooleanArray(w * h)

        fun half(): Plane {
            val out = Plane(max(1, w / 2), max(1, h / 2))
            for (y in 0 until out.h) for (x in 0 until out.w) {
                var s0 = 0f
                var s1 = 0f
                var s2 = 0f
                var n = 0f
                var holes = 0
                for (dy in 0..1) for (dx in 0..1) {
                    val i = min(y * 2 + dy, h - 1) * w + min(x * 2 + dx, w - 1)
                    if (hole[i]) { holes++; continue }
                    s0 += rgb[i * 3]; s1 += rgb[i * 3 + 1]; s2 += rgb[i * 3 + 2]
                    n += 1f
                }
                val o = y * out.w + x
                out.hole[o] = holes > 0
                if (n > 0) {
                    out.rgb[o * 3] = s0 / n
                    out.rgb[o * 3 + 1] = s1 / n
                    out.rgb[o * 3 + 2] = s2 / n
                }
            }
            return out
        }
    }

    private const val R = 3

    /** px：ARGB；mask：大于 40 = 要补的。返回补好的整块。补不了（到处都涂了）返回 null。 */
    fun fill(px: IntArray, mask: ByteArray, w: Int, h: Int): IntArray? {
        val full = Plane(w, h)
        var holes = 0
        for (i in 0 until w * h) {
            full.hole[i] = (mask[i].toInt() and 255) > 40
            if (full.hole[i]) holes++
            full.rgb[i * 3] = (px[i] shr 16 and 255) / 255f
            full.rgb[i * 3 + 1] = (px[i] shr 8 and 255) / 255f
            full.rgb[i * 3 + 2] = (px[i] and 255) / 255f
        }
        if (holes == 0) return px
        if (holes * 10 >= w * h * 9) return null
        val levels = arrayListOf(full)
        while (min(levels.last().w, levels.last().h) > 110 && levels.size < 7 && thickness(levels.last()) > 4) levels += levels.last().half()

        // 最粗一层：从边上一块块往里补（先补纹理和线条最明确的），当作起点。
        exemplar(levels.last())
        var field = IntArray(0)
        val top = levels.size - 1
        for (l in top downTo 0) {
            val p = levels[l]
            val passes = if (l == top) 4 else if (l == 0) 4 else 8
            field = Solver(p, if (l == top) null else levels[l + 1], field).solve(passes) ?: return null
            if (l > 0) upsample(p, levels[l - 1])
        }
        val out = px.copyOf()
        fun byte(v: Float) = (v.coerceIn(0f, 1f) * 255f + 0.5f).toInt()
        for (i in 0 until w * h) if (full.hole[i]) {
            out[i] = (0xFF shl 24) or (byte(full.rgb[i * 3]) shl 16) or (byte(full.rgb[i * 3 + 1]) shl 8) or byte(full.rgb[i * 3 + 2])
        }
        return out
    }

    /** 每个洞里的点离洞外多远。 */
    private fun distances(p: Plane): IntArray {
        val w = p.w
        val h = p.h
        val dist = IntArray(w * h) { 1 shl 20 }
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * w + x
            if (!p.hole[i]) { dist[i] = 0; continue }
            if (x > 0) dist[i] = min(dist[i], dist[i - 1] + 1)
            if (y > 0) dist[i] = min(dist[i], dist[i - w] + 1)
        }
        for (y in h - 1 downTo 0) for (x in w - 1 downTo 0) {
            val i = y * w + x
            if (x + 1 < w) dist[i] = min(dist[i], dist[i + 1] + 1)
            if (y + 1 < h) dist[i] = min(dist[i], dist[i + w] + 1)
        }
        return dist
    }

    private fun thickness(p: Plane): Int {
        var best = 0
        for (d in distances(p)) if (d < 1 shl 19 && d > best) best = d
        return best
    }

    /** 从洞的边上往里补：每次挑已知最多、结构最强的小块，整块照着洞外最像的抄。 */
    private fun exemplar(p: Plane) {
        val w = p.w
        val h = p.h
        val r = min(4, (min(w, h) - 3) / 2)
        if (r < 2) return seed(p, p.hole)
        val rgb = p.rgb
        val open = p.hole.copyOf()
        val conf = FloatArray(w * h) { if (p.hole[it]) 0f else 1f }
        // 能抄的：整块都在原来的洞外。
        val list = ArrayList<Int>()
        for (y in r until h - r) for (x in r until w - r) {
            var ok = true
            check@ for (dy in -r..r) for (dx in -r..r) if (p.hole[(y + dy) * w + x + dx]) { ok = false; break@check }
            if (ok) list += y * w + x
        }
        if (list.isEmpty()) return seed(p, p.hole)
        val sources = list.toIntArray()
        fun luma(i: Int) = rgb[i * 3] * 0.3f + rgb[i * 3 + 1] * 0.59f + rgb[i * 3 + 2] * 0.11f
        val diag = (w * w + h * h).toFloat()
        var remaining = open.count { it }
        var rounds = 0
        while (remaining > 0 && rounds < w * h) {
            rounds++
            // 洞的边：自己没补、旁边有补好的。
            var best = -1
            var bestScore = -1f
            for (y in 0 until h) for (x in 0 until w) {
                val i = y * w + x
                if (!open[i]) continue
                val edge = (x > 0 && !open[i - 1]) || (x + 1 < w && !open[i + 1]) || (y > 0 && !open[i - w]) || (y + 1 < h && !open[i + w])
                if (!edge) continue
                var c = 0f
                var n = 0f
                var g = 0f
                for (dy in -r..r) for (dx in -r..r) {
                    val nx = x + dx
                    val ny = y + dy
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                    n += 1f
                    val j = ny * w + nx
                    c += conf[j]
                    if (!open[j] && nx + 1 < w && ny + 1 < h && !open[j + 1] && !open[j + w]) {
                        g = max(g, abs(luma(j + 1) - luma(j)) + abs(luma(j + w) - luma(j)))
                    }
                }
                val score = c / n * (0.15f + min(g, 0.6f))
                if (score > bestScore) { bestScore = score; best = i }
            }
            if (best < 0) break
            val bx = best % w
            val by = best / w
            var pick = -1
            var pickCost = Float.POSITIVE_INFINITY
            for (s in sources) {
                val sx = s % w
                val sy = s / w
                var d = ((sx - bx) * (sx - bx) + (sy - by) * (sy - by)).toFloat() / diag * 40f
                for (dy in -r..r) {
                    for (dx in -r..r) {
                        val nx = bx + dx
                        val ny = by + dy
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                        val j = ny * w + nx
                        if (open[j]) continue
                        val o = (sy + dy) * w + sx + dx
                        val a = rgb[j * 3] - rgb[o * 3]
                        val b = rgb[j * 3 + 1] - rgb[o * 3 + 1]
                        val c = rgb[j * 3 + 2] - rgb[o * 3 + 2]
                        d += a * a + b * b + c * c
                    }
                    if (d >= pickCost) break
                }
                if (d < pickCost) { pickCost = d; pick = s }
            }
            if (pick < 0) break
            val level = conf[best]
            for (dy in -r..r) for (dx in -r..r) {
                val nx = bx + dx
                val ny = by + dy
                if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                val j = ny * w + nx
                if (!open[j]) continue
                val o = (pick / w + dy) * w + pick % w + dx
                for (k in 0..2) rgb[j * 3 + k] = rgb[o * 3 + k]
                open[j] = false
                conf[j] = max(level, 0.6f) * 0.8f
                remaining--
            }
        }
        if (remaining > 0) seed(p, open)
    }

    private fun seed(p: Plane, hole: BooleanArray) {
        val w = p.w
        val h = p.h
        val rgb = p.rgb
        var known = BooleanArray(w * h) { !hole[it] }
        var left = known.any { !it }
        while (left) {
            left = false
            val next = known.copyOf()
            var moved = false
            for (y in 0 until h) for (x in 0 until w) {
                val i = y * w + x
                if (known[i]) continue
                var s0 = 0f
                var s1 = 0f
                var s2 = 0f
                var n = 0f
                for (dy in -1..1) for (dx in -1..1) {
                    val nx = x + dx
                    val ny = y + dy
                    if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue
                    val j = ny * w + nx
                    if (known[j]) { s0 += rgb[j * 3]; s1 += rgb[j * 3 + 1]; s2 += rgb[j * 3 + 2]; n += 1f }
                }
                if (n > 0) {
                    rgb[i * 3] = s0 / n; rgb[i * 3 + 1] = s1 / n; rgb[i * 3 + 2] = s2 / n
                    next[i] = true
                    moved = true
                } else {
                    left = true
                }
            }
            known = next
            if (!moved) break
        }
    }

    /** 粗的一层补好的颜色放大到细的一层的洞里。 */
    private fun upsample(a: Plane, b: Plane) {
        for (y in 0 until b.h) for (x in 0 until b.w) {
            val i = y * b.w + x
            if (!b.hole[i]) continue
            val j = min(y / 2, a.h - 1) * a.w + min(x / 2, a.w - 1)
            for (c in 0..2) b.rgb[i * 3 + c] = a.rgb[j * 3 + c]
        }
    }

    /** 一层：找每个碰到洞的小块最像的外面小块，再投票填色，来回几次。solve 返回每个点的最近邻（源的下标），-1 = 不用找。 */
    private class Solver(private val p: Plane, private val coarse: Plane?, private val coarseField: IntArray) {
        private val w = p.w
        private val h = p.h
        private val rgb = p.rgb
        private val isSource = BooleanArray(w * h)
        private val field = IntArray(w * h) { -1 }
        private val cost = FloatArray(w * h) { Float.POSITIVE_INFINITY }
        private lateinit var trust: FloatArray
        /** 每个点在距离里占多重。 */
        private lateinit var heft: FloatArray
        private var state = 0x9E37_79B9_7F4A_7C15UL
        // 优先用近处的纹理。
        private val far = 0.5f / (w * w + h * h).toFloat() * ((2 * R + 1) * (2 * R + 1)).toFloat()

        private fun random(n: Int): Int {
            state = state xor (state shl 13)
            state = state xor (state shr 7)
            state = state xor (state shl 17)
            return (state % max(n, 1).toULong()).toInt()
        }

        private fun distance(a: Int, b: Int, limit: Float): Float {
            val dx = (a % w - b % w).toFloat()
            val dy0 = (a / w - b / w).toFloat()
            var d = (dx * dx + dy0 * dy0) * far
            for (dy in -R..R) {
                var qa = a + dy * w - R
                var ia = qa * 3
                var ib = (b + dy * w - R) * 3
                for (k in 0..2 * R) {
                    val x = rgb[ia] - rgb[ib]
                    val y = rgb[ia + 1] - rgb[ib + 1]
                    val z = rgb[ia + 2] - rgb[ib + 2]
                    d += (x * x + y * y + z * z) * heft[qa]
                    qa++
                    ia += 3
                    ib += 3
                }
                if (d > limit) return d
            }
            return d
        }

        private fun attempt(i: Int, s: Int) {
            if (s < 0 || s >= w * h || !isSource[s]) return
            val d = distance(i, s, cost[i])
            if (d < cost[i]) {
                cost[i] = d
                field[i] = s
            }
        }

        fun solve(passes: Int): IntArray? {
            if (w <= R * 2 + 2 || h <= R * 2 + 2) return field
            // 能当源的：整块都在洞外。能当目标的：碰到洞。积分图快速数洞。
            val sum = IntArray((w + 1) * (h + 1))
            for (y in 0 until h) for (x in 0 until w) {
                sum[(y + 1) * (w + 1) + x + 1] =
                    (if (p.hole[y * w + x]) 1 else 0) + sum[y * (w + 1) + x + 1] + sum[(y + 1) * (w + 1) + x] - sum[y * (w + 1) + x]
            }
            val sourceList = ArrayList<Int>()
            val targetList = ArrayList<Int>()
            for (y in R until h - R) for (x in R until w - R) {
                val n = sum[(y + R + 1) * (w + 1) + x + R + 1] - sum[(y - R) * (w + 1) + x + R + 1] -
                    sum[(y + R + 1) * (w + 1) + x - R] + sum[(y - R) * (w + 1) + x - R]
                val i = y * w + x
                if (n == 0) {
                    isSource[i] = true
                    sourceList += i
                } else {
                    targetList += i
                }
            }
            if (sourceList.isEmpty() || targetList.isEmpty()) return null
            val sources = sourceList.toIntArray()
            val targets = targetList.toIntArray()
            // 信任度：洞外是 1，洞里越深越低。
            val dist = distances(p)
            trust = FloatArray(w * h) { if (dist[it] == 0) 1f else 1.3f.pow(-min(dist[it], 60).toFloat()) }
            heft = FloatArray(w * h) { if (trust[it] < 1f) max(trust[it], 0.5f) * 0.15f else 1f }
            val c = coarse
            for (i in targets) {
                if (c != null) {
                    val x = i % w
                    val y = i / w
                    val f = coarseField[min(y / 2, c.h - 1) * c.w + min(x / 2, c.w - 1)]
                    if (f >= 0) {
                        val sx = min(max(f % c.w * 2 + (x and 1), R), w - R - 1)
                        val sy = min(max(f / c.w * 2 + (y and 1), R), h - R - 1)
                        if (isSource[sy * w + sx]) field[i] = sy * w + sx
                    }
                }
                if (field[i] < 0) field[i] = sources[random(sources.size)]
            }
            for (pass in 0 until passes) {
                for (t in targets) cost[t] = distance(t, field[t], Float.POSITIVE_INFINITY)
                for (iteration in 0 until 3) {
                    val forward = (pass + iteration) % 2 == 0
                    val step = if (forward) 1 else -1
                    for (k in targets.indices) {
                        val i = targets[if (forward) k else targets.size - 1 - k]
                        // 传播：邻居的匹配挪一格。
                        val a = i - step
                        val b = i - step * w
                        if (a >= 0 && a < w * h && field[a] >= 0) attempt(i, field[a] + step)
                        if (b >= 0 && b < w * h && field[b] >= 0) attempt(i, field[b] + step * w)
                        // 随机找。
                        var radius = max(w, h)
                        while (radius >= 1) {
                            val f = field[i]
                            val sx = f % w + random(radius * 2 + 1) - radius
                            val sy = f / w + random(radius * 2 + 1) - radius
                            if (sx >= R && sy >= R && sx < w - R && sy < h - R) attempt(i, sy * w + sx)
                            radius /= 2
                        }
                    }
                }
                vote(targets, last = pass == passes - 1)
            }
            return field
        }

        /** 投票：越像的小块说话越算数。 */
        private fun vote(targets: IntArray, last: Boolean) {
            val acc = FloatArray(w * h * 3)
            val weight = FloatArray(w * h)
            val sorted = FloatArray(targets.size) { cost[targets[it]] }
            sorted.sort()
            val sigma = max(sorted[sorted.size / 2], 1e-4f) * 0.12f
            // 最后一遍只听离得近的，细节不会被平均糊掉。
            val side = 2 * R + 1
            val near = FloatArray(side * side) {
                val dx = it % side - R
                val dy = it / side - R
                exp(-(dx * dx + dy * dy).toFloat() / (if (last) 1.6f else 6f))
            }
            for (i in targets) {
                val s = field[i]
                val v = max(exp(-cost[i] / sigma), 1e-6f) * trust[i]
                for (dy in -R..R) for (dx in -R..R) {
                    val q = i + dy * w + dx
                    if (!p.hole[q]) continue
                    val m = v * near[(dy + R) * side + dx + R]
                    val o = (s + dy * w + dx) * 3
                    acc[q * 3] += rgb[o] * m
                    acc[q * 3 + 1] += rgb[o + 1] * m
                    acc[q * 3 + 2] += rgb[o + 2] * m
                    weight[q] += m
                }
            }
            for (q in 0 until w * h) if (p.hole[q] && weight[q] > 0) {
                rgb[q * 3] = acc[q * 3] / weight[q]
                rgb[q * 3 + 1] = acc[q * 3 + 1] / weight[q]
                rgb[q * 3 + 2] = acc[q * 3 + 2] / weight[q]
            }
        }
    }
}
