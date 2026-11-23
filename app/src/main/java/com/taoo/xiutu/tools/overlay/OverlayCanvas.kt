package com.taoo.xiutu.tools.overlay

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.taoo.xiutu.editor.ImageFrame
import com.taoo.xiutu.editor.ZoomableCanvas
import com.taoo.xiutu.ui.sym
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin

/** 文字和贴纸的编辑画布：拖动移动，双指或右下角手柄缩放旋转，双击改文字。 */
@Composable
fun OverlayCanvas(s: OverlaySession, modifier: Modifier) {
    val cache = remember { OverlayRenderCache() }
    Box(modifier) {
        ZoomableCanvas(
            s.model.displayImage,
            onTap = { s.selectedId = null },
            overlay = { frame -> OverlayLayer(s, frame, cache) },
        )
    }
}

/** 按"长什么样"缓存每一项的位图：位置和角度变了不用重画，样式、文字、大小变了才重画。 */
private class OverlayRenderCache {
    class Entry(val look: OverlayItem, val width: Float, val image: ImageBitmap, val pixelW: Int, val pixelH: Int, val k: Float)

    private val entries = HashMap<String, Entry>()

    fun render(item: OverlayItem, imageWidth: Float): Entry? {
        val look = item.appearance
        entries[item.id]?.let { if (it.width == imageWidth && it.look == look) return it }
        val r = OverlayRenderer.render(item, imageWidth, 3000f)
        if (r == null) {
            entries.remove(item.id)
            return null
        }
        if (entries.size > 60) entries.clear()
        val e = Entry(look, imageWidth, r.bitmap.asImageBitmap(), r.bitmap.width, r.bitmap.height, r.k)
        entries[item.id] = e
        return e
    }
}

/** 渲染用的图片宽度：缩放画布时分档变化，不用每一帧都重画。 */
private fun renderWidth(frameWidth: Float): Float {
    val w = max(frameWidth, 64f)
    val step = (ln(w) / ln(2f) * 4f).roundToInt() / 4f
    return 2f.pow(step)
}

/** 局部坐标（随项一起旋转）里的位移换回画布坐标。 */
private fun rotated(d: Offset, angle: Float): Offset {
    val c = cos(angle)
    val sn = sin(angle)
    return Offset(d.x * c - d.y * sn, d.x * sn + d.y * c)
}

@Composable
private fun OverlayLayer(s: OverlaySession, frame: ImageFrame, cache: OverlayRenderCache) {
    val rw = renderWidth(frame.width)
    // 图片之外的部分不显示（和导出一致）
    Box(
        Modifier
            .offset { IntOffset(frame.left.roundToInt(), frame.top.roundToInt()) }
            .pxSize(frame.width, frame.height)
            .clipToBounds(),
    ) {
        for (item in s.items) {
            key(item.id) {
                val e = cache.render(item, rw)
                if (e != null) ItemView(s, item, e, frame, rw)
            }
        }
    }
    val sel = s.selected
    if (sel != null) {
        val e = cache.render(sel, rw)
        if (e != null) SelectionChrome(s, sel, e, frame, rw)
    }
}

/**
 * 按像素定死大小，但对外只报 0×0：放大画布后比外框还大时，不会被父布局挤到中间去。
 * 后面的修饰符（旋转、手势）和内容都按这个大小来。
 */
private fun Modifier.pxSize(w: Float, h: Float): Modifier = layout { m, _ ->
    val p = m.measure(Constraints.fixed(max(1, w.roundToInt()), max(1, h.roundToInt())))
    layout(0, 0) { p.place(0, 0) }
}

@Composable
private fun ItemView(s: OverlaySession, item: OverlayItem, e: OverlayRenderCache.Entry, frame: ImageFrame, rw: Float) {
    val f = frame.width / rw / e.k
    val w = e.pixelW * f
    val h = e.pixelH * f
    val id = item.id
    val currentFrame by rememberUpdatedState(frame)
    val lastTap = remember { longArrayOf(0L) }
    Image(
        e.image, null, contentScale = ContentScale.FillBounds,
        modifier = Modifier
            .offset { IntOffset((item.cx * frame.width - w / 2).roundToInt(), (item.cy * frame.height - h / 2).roundToInt()) }
            .pxSize(w, h)
            .graphicsLayer { rotationZ = Math.toDegrees(item.rotation.toDouble()).toFloat() }
            .pointerInput(id) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    s.selectedId = id
                    var moved = false
                    var multi = false
                    while (true) {
                        val ev = awaitPointerEvent()
                        val pressed = ev.changes.filter { it.pressed }
                        if (pressed.isEmpty()) {
                            val t = ev.changes.first().uptimeMillis
                            if (!moved && !multi && t - down.uptimeMillis < 300) {
                                // 双击改文字
                                if (t - lastTap[0] < 350) {
                                    lastTap[0] = 0L
                                    val cur = s.items.firstOrNull { it.id == id }
                                    if (cur != null && !cur.isSticker && !cur.isImage) s.editText(id)
                                } else lastTap[0] = t
                            }
                            break
                        }
                        val cur = s.items.firstOrNull { it.id == id } ?: break
                        val fr = currentFrame
                        if (pressed.size >= 2) {
                            multi = true
                            val a = pressed[0]
                            val b = pressed[1]
                            val now = b.position - a.position
                            val before = b.previousPosition - a.previousPosition
                            val lenNow = now.getDistance()
                            val lenBefore = before.getDistance()
                            val zoom = if (lenBefore > 1f) lenNow / lenBefore else 1f
                            val turn = atan2(now.y, now.x) - atan2(before.y, before.x)
                            val pan = rotated((a.position + b.position) / 2f - (a.previousPosition + b.previousPosition) / 2f, cur.rotation)
                            s.update(id) {
                                it.copy(
                                    scale = (it.scale * zoom).coerceIn(0.2f, 10f),
                                    rotation = it.rotation + normalized(turn),
                                    cx = (it.cx + pan.x / fr.width).coerceIn(-0.1f, 1.1f),
                                    cy = (it.cy + pan.y / fr.height).coerceIn(-0.1f, 1.1f),
                                )
                            }
                            ev.changes.forEach { it.consume() }
                        } else {
                            val c = pressed[0]
                            val d = c.position - c.previousPosition
                            if (!moved && (c.position - down.position).getDistance() > 4f) moved = true
                            if (moved && d != Offset.Zero) {
                                val p = rotated(d, cur.rotation)
                                s.update(id) {
                                    it.copy(
                                        cx = (it.cx + p.x / fr.width).coerceIn(-0.1f, 1.1f),
                                        cy = (it.cy + p.y / fr.height).coerceIn(-0.1f, 1.1f),
                                    )
                                }
                            }
                            c.consume()
                        }
                    }
                }
            },
    )
}

/** 角度差换到 -π...π，跨过 ±180° 时不会突然转一圈。 */
private fun normalized(a: Float): Float {
    var x = a
    while (x > Math.PI) x -= (2 * Math.PI).toFloat()
    while (x < -Math.PI) x += (2 * Math.PI).toFloat()
    return x
}

/** 选中状态的虚线框，加上删除、复制和缩放旋转三个手柄。 */
@Composable
private fun SelectionChrome(s: OverlaySession, item: OverlayItem, e: OverlayRenderCache.Entry, frame: ImageFrame, rw: Float) {
    val density = LocalDensity.current.density
    val f = frame.width / rw / e.k
    val w = e.pixelW * f
    val h = e.pixelH * f
    // 手柄的点按范围
    val hb = 40f * density
    val cw = w + hb
    val ch = h + hb
    val cx = frame.left + item.cx * frame.width
    val cy = frame.top + item.cy * frame.height
    val id = item.id
    val size by rememberUpdatedState(Offset(cw, ch))
    val currentFrame by rememberUpdatedState(frame)
    Box(
        Modifier
            .offset { IntOffset((cx - cw / 2).roundToInt(), (cy - ch / 2).roundToInt()) }
            .pxSize(cw, ch)
            .graphicsLayer { rotationZ = Math.toDegrees(item.rotation.toDouble()).toFloat() },
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val pad = hb / 2
            drawRect(
                Color.White, topLeft = Offset(pad, pad), size = androidx.compose.ui.geometry.Size(w, h),
                style = Stroke(width = density, pathEffect = PathEffect.dashPathEffect(floatArrayOf(5 * density, 4 * density))),
            )
        }
        Handle("xmark", Modifier.align(Alignment.TopStart).pointerInput(id) {
            awaitEachGesture {
                awaitFirstDown().consume()
                val up = awaitRelease()
                if (up) s.remove(id)
            }
        })
        Handle("plus.square.on.square", Modifier.align(Alignment.TopEnd).pointerInput(id) {
            awaitEachGesture {
                awaitFirstDown().consume()
                if (awaitRelease()) s.duplicate(id)
            }
        })
        Handle("arrow.up.left.and.arrow.down.right", Modifier.align(Alignment.BottomEnd).pointerInput(id) {
            awaitEachGesture {
                awaitFirstDown().consume()
                while (true) {
                    val ev = awaitPointerEvent()
                    val c = ev.changes.firstOrNull { it.pressed } ?: break
                    // 框的中心在这个手柄自己的坐标里的位置
                    val sz = size
                    val center = Offset(hb - sz.x / 2, hb - sz.y / 2)
                    val now = c.position - center
                    val before = c.previousPosition - center
                    val lenNow = max(now.getDistance(), 1f)
                    val lenBefore = max(before.getDistance(), 1f)
                    val turn = atan2(now.y, now.x) - atan2(before.y, before.x)
                    s.update(id) {
                        it.copy(scale = (it.scale * lenNow / lenBefore).coerceIn(0.2f, 10f), rotation = it.rotation + normalized(turn))
                    }
                    c.consume()
                }
            }
        })
        // 文字可以拉边改框的长度：横排拉右边改宽，竖排拉下边改高；拉的边跟着手走，对面那条边不动，字排满了自动换行。
        if (!item.isSticker && !item.isImage && item.graphic == null) {
            val vertical = item.vertical
            EdgeHandle(vertical, Modifier.align(if (vertical) Alignment.BottomCenter else Alignment.CenterEnd).pointerInput(id, vertical) {
                awaitEachGesture {
                    awaitFirstDown().consume()
                    val start = s.items.firstOrNull { it.id == id } ?: return@awaitEachGesture
                    val fr = currentFrame
                    val fs = max(start.size * start.scale * fr.width, 1f)
                    // 没拉过的框，从现在字实际占的长度开始拉。
                    val startLen = if (start.wrap > 0f) start.wrap * fs else {
                        val c = OverlayDrawing.layout(start, fs)?.content
                        if (c == null) fs else if (vertical) c.height() else c.width()
                    }
                    var total = 0f
                    while (true) {
                        val ev = awaitPointerEvent()
                        val c = ev.changes.firstOrNull { it.pressed } ?: break
                        // 手柄跟着框一起转，坐标已经是框自己的方向。
                        val d = c.position - c.previousPosition
                        total += if (vertical) d.y else d.x
                        val len = (startLen + total).coerceIn(fs * 1.05f, fs * 80f)
                        val moved = (len - startLen) / 2
                        val shift = rotated(if (vertical) Offset(0f, moved) else Offset(moved, 0f), start.rotation)
                        s.update(id) {
                            it.copy(wrap = len / fs, cx = start.cx + shift.x / fr.width, cy = start.cy + shift.y / fr.height)
                        }
                        c.consume()
                    }
                }
            })
        }
    }
}

@Composable
private fun EdgeHandle(vertical: Boolean, modifier: Modifier) {
    Box(modifier.size(40.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(if (vertical) 26.dp else 8.dp, if (vertical) 8.dp else 26.dp).clip(CircleShape).background(Color.White))
    }
}

/** 等手指抬起；抬起时还在原处附近就算点了一下。 */
private suspend fun androidx.compose.ui.input.pointer.AwaitPointerEventScope.awaitRelease(): Boolean {
    var start: Offset? = null
    while (true) {
        val ev = awaitPointerEvent()
        val c = ev.changes.first()
        if (start == null) start = c.previousPosition
        c.consume()
        if (!c.pressed) return abs(c.position.x - start.x) + abs(c.position.y - start.y) < 40f
    }
}

@Composable
private fun Handle(symbol: String, modifier: Modifier) {
    Box(modifier.size(40.dp), contentAlignment = Alignment.Center) {
        Box(Modifier.size(26.dp).clip(CircleShape).background(Color.White), contentAlignment = Alignment.Center) {
            Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(13.dp))
        }
    }
}

