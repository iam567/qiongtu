package com.taoo.xiutu.tools.crop

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathFillType
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.editor.EditorModel
import com.taoo.xiutu.editor.Tool
import com.taoo.xiutu.editor.ToolSession
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.IconTile
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.XSlider
import com.taoo.xiutu.ui.tap
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** 裁剪：旋转、翻转、拉直，图片上叠一个可拖动的裁剪框。 */
class CropSession(model: EditorModel) : ToolSession(model, Tool.CROP) {
    var crop by mutableStateOf(CropParams())
    var aspect by mutableStateOf(CropAspect.FREE)

    override val customCanvas: Boolean get() = true

    override fun commitOps(): List<EditOp> = if (crop.isIdentity) emptyList() else listOf(CropOp(crop))

    /** 当前锁定的比例，换算成归一化坐标下的 宽/高；null = 自由。 */
    val lockedAspect: Float?
        get() {
            val b = model.base ?: return null
            val (w, h) = crop.orientedSize(b.width, b.height)
            if (w <= 0 || h <= 0) return null
            return when (aspect) {
                CropAspect.FREE -> null
                CropAspect.ORIGINAL -> 1f
                else -> aspect.ratio?.let { it * h / w }
            }
        }

    fun chooseAspect(a: CropAspect) {
        aspect = a
        val k = lockedAspect ?: return
        val w = if (k >= 1) 1f else k
        val h = if (k >= 1) 1 / k else 1f
        crop = crop.copy(rect = CropRect((1 - w) / 2, (1 - h) / 2, w, h))
    }

    fun rotate() {
        crop = crop.rotateClockwise()
        aspect = CropAspect.FREE
        render()
    }

    fun flipHorizontal() { crop = crop.flipHorizontal(); render() }

    fun flipVertical() { crop = crop.flipVertical(); render() }

    fun setStraighten(degrees: Float) {
        crop = crop.copy(straighten = if (abs(degrees) < 0.3f) 0f else degrees)
        render()
    }

    fun reset() {
        crop = CropParams()
        aspect = CropAspect.FREE
        render()
    }

    private fun render() {
        val p = crop
        model.liveOnBase { p.oriented(it) }
    }

    @Composable
    override fun Canvas(modifier: Modifier) {
        val image = model.displayImage
        BoxWithConstraints(modifier.fillMaxSize()) {
            val density = LocalDensity.current
            val px = density.density
            val margin = 24f * px
            val vw = constraints.maxWidth.toFloat()
            val vh = constraints.maxHeight.toFloat()
            val iw = (image?.width ?: 1).toFloat()
            val ih = (image?.height ?: 1).toFloat()
            val k = min(max(1f, vw - margin * 2) / iw, max(1f, vh - margin * 2) / ih)
            val fw = iw * k
            val fh = ih * k
            val img = Rect(Offset((vw - fw) / 2, (vh - fh) / 2), Size(fw, fh))
            val bmp = remember(image) { image?.asImageBitmap() }
            val r = crop.rect
            val frame = Rect(img.left + r.x * fw, img.top + r.y * fh, img.left + r.maxX * fw, img.top + r.maxY * fh)
            val imgNow by rememberUpdatedState(img)

            Canvas(
                Modifier.fillMaxSize().cropDrag({ imgNow }, { crop.rect }, { lockedAspect }) { crop = crop.copy(rect = it) },
            ) {
                if (bmp != null) {
                    drawImage(
                        bmp, dstOffset = IntOffset(img.left.roundToInt(), img.top.roundToInt()),
                        dstSize = IntSize(fw.roundToInt(), fh.roundToInt()), filterQuality = FilterQuality.High,
                    )
                }
                drawCropFrame(img, frame, px)
            }
        }
    }

    @Composable
    override fun Panel() {
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 14.dp, bottom = 6.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("${crop.straighten.roundToInt()}°", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color.White, modifier = Modifier.width(44.dp))
                XSlider(crop.straighten, { setStraighten(it) }, -30f..30f, Modifier.weight(1f))
                Box(Modifier.height(36.dp).tap { reset() }, contentAlignment = Alignment.Center) {
                    Text("还原", fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (crop.isIdentity) Theme.dim else Color.White)
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                IconTile("rotate.right", "旋转") { rotate() }
                IconTile("arrow.left.and.right.righttriangle.left.righttriangle.right", "水平翻转") { flipHorizontal() }
                IconTile("arrow.up.and.down.righttriangle.up.righttriangle.down", "垂直翻转") { flipVertical() }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (a in CropAspect.entries) Chip(a.title, aspect == a) { chooseAspect(a) }
            }
        }
    }
}

/** 裁剪框：框外压暗、三分线、边框和四个角。px = 1dp 的像素数。 */
internal fun DrawScope.drawCropFrame(img: Rect, frame: Rect, px: Float) {
    // 框外压暗
    val dim = Path().apply {
        fillType = PathFillType.EvenOdd
        addRect(img)
        addRect(frame)
    }
    drawPath(dim, Color.Black.copy(alpha = 0.6f))
    // 三分线
    val grid = Color.White.copy(alpha = 0.45f)
    for (i in 1..2) {
        val x = frame.left + frame.width * i / 3
        val y = frame.top + frame.height * i / 3
        drawLine(grid, Offset(x, frame.top), Offset(x, frame.bottom), 0.5f * px)
        drawLine(grid, Offset(frame.left, y), Offset(frame.right, y), 0.5f * px)
    }
    drawRect(Color.White, frame.topLeft, frame.size, style = Stroke(1f * px))
    // 四个角
    val l = minOf(22f * px, frame.width / 3, frame.height / 3)
    val corners = Path()
    for ((c, sx, sy) in listOf(
        Triple(frame.topLeft, 1f, 1f), Triple(frame.topRight, -1f, 1f),
        Triple(frame.bottomLeft, 1f, -1f), Triple(frame.bottomRight, -1f, -1f),
    )) {
        corners.moveTo(c.x + sx * l, c.y)
        corners.lineTo(c.x, c.y)
        corners.lineTo(c.x, c.y + sy * l)
    }
    drawPath(corners, Color.White, style = Stroke(3.5f * px, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

/** 拖裁剪框的手势。box = 图片在画布里的位置，rect = 现在的框（null = 没有框可拖），locked = 锁定的归一化宽高比。 */
internal fun Modifier.cropDrag(box: () -> Rect, rect: () -> CropRect?, locked: () -> Float?, onChange: (CropRect) -> Unit): Modifier = composed {
    val boxNow by rememberUpdatedState(box)
    val rectNow by rememberUpdatedState(rect)
    val lockedNow by rememberUpdatedState(locked)
    val changeNow by rememberUpdatedState(onChange)
    pointerInput(Unit) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val b = boxNow()
            val s = rectNow() ?: return@awaitEachGesture
            val f = Rect(b.left + s.x * b.width, b.top + s.y * b.height, b.left + s.maxX * b.width, b.top + s.maxY * b.height)
            val aspect = lockedNow()
            val handle = hitTest(down.position, f, aspect == null, density) ?: return@awaitEachGesture
            down.consume()
            while (true) {
                val e = awaitPointerEvent()
                val c = e.changes.firstOrNull { it.id == down.id } ?: break
                if (!c.pressed) break
                if (b.width > 0 && b.height > 0) {
                    val dx = (c.position.x - down.position.x) / b.width
                    val dy = (c.position.y - down.position.y) / b.height
                    changeNow(updated(handle, s, dx, dy, aspect))
                }
                c.consume()
            }
        }
    }
}

private enum class Handle { MOVE, TOP_LEFT, TOP_RIGHT, BOTTOM_LEFT, BOTTOM_RIGHT, LEFT, RIGHT, TOP, BOTTOM }

private const val MIN_SIDE = 0.08f

/** 按下的位置抓的是哪个角 / 哪条边 / 整个框。px = 1dp 的像素数。 */
private fun hitTest(p: Offset, f: Rect, edges: Boolean, px: Float): Handle? {
    val corner = 34f * px
    val edge = 24f * px
    fun near(a: Offset) = hypot(p.x - a.x, p.y - a.y) < corner
    if (near(f.topLeft)) return Handle.TOP_LEFT
    if (near(f.topRight)) return Handle.TOP_RIGHT
    if (near(f.bottomLeft)) return Handle.BOTTOM_LEFT
    if (near(f.bottomRight)) return Handle.BOTTOM_RIGHT
    if (edges) {
        val inX = p.x > f.left && p.x < f.right
        val inY = p.y > f.top && p.y < f.bottom
        if (inY && abs(p.x - f.left) < edge) return Handle.LEFT
        if (inY && abs(p.x - f.right) < edge) return Handle.RIGHT
        if (inX && abs(p.y - f.top) < edge) return Handle.TOP
        if (inX && abs(p.y - f.bottom) < edge) return Handle.BOTTOM
    }
    return if (f.contains(p)) Handle.MOVE else null
}

private fun updated(handle: Handle, s: CropRect, dx: Float, dy: Float, aspect: Float?): CropRect {
    if (handle == Handle.MOVE) {
        val x = min(max(0f, s.x + dx), 1 - s.w)
        val y = min(max(0f, s.y + dy), 1 - s.h)
        return s.copy(x = x, y = y)
    }
    if (aspect != null) return lockedCorner(handle, s, dx, dy, aspect)
    var x0 = s.x
    var y0 = s.y
    var x1 = s.maxX
    var y1 = s.maxY
    when (handle) {
        Handle.LEFT, Handle.TOP_LEFT, Handle.BOTTOM_LEFT -> x0 = min(max(0f, x0 + dx), x1 - MIN_SIDE)
        Handle.RIGHT, Handle.TOP_RIGHT, Handle.BOTTOM_RIGHT -> x1 = max(min(1f, x1 + dx), x0 + MIN_SIDE)
        else -> {}
    }
    when (handle) {
        Handle.TOP, Handle.TOP_LEFT, Handle.TOP_RIGHT -> y0 = min(max(0f, y0 + dy), y1 - MIN_SIDE)
        Handle.BOTTOM, Handle.BOTTOM_LEFT, Handle.BOTTOM_RIGHT -> y1 = max(min(1f, y1 + dy), y0 + MIN_SIDE)
        else -> {}
    }
    return CropRect(x0, y0, x1 - x0, y1 - y0)
}

/** 锁定比例时拖角：对角固定不动，框按比例缩放。 */
private fun lockedCorner(handle: Handle, s: CropRect, dx: Float, dy: Float, aspect: Float): CropRect {
    val sx = if (handle == Handle.TOP_RIGHT || handle == Handle.BOTTOM_RIGHT) 1f else -1f
    val sy = if (handle == Handle.BOTTOM_LEFT || handle == Handle.BOTTOM_RIGHT) 1f else -1f
    val ax = if (sx > 0) s.x else s.maxX
    val ay = if (sy > 0) s.y else s.maxY
    val maxW = if (sx > 0) 1 - ax else ax
    val maxH = if (sy > 0) 1 - ay else ay
    var w = max(s.w + sx * dx, (s.h + sy * dy) * aspect)
    w = minOf(w, maxW, maxH * aspect)
    w = maxOf(w, MIN_SIDE, MIN_SIDE * aspect)
    w = minOf(w, maxW, maxH * aspect)
    val h = w / aspect
    return CropRect(if (sx > 0) ax else ax - w, if (sy > 0) ay else ay - h, w, h)
}
