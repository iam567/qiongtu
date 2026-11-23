package com.taoo.xiutu.tools.overlay

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout as TextLayout
import android.text.StaticLayout
import android.text.TextPaint
import com.taoo.xiutu.ml.Mask8
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.acos
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.tan

/**
 * 文字 / 贴纸的实际绘制：Canvas + StaticLayout，可以在后台线程跑。
 * 坐标系是安卓的：原点左上角，y 向下。
 */
object OverlayDrawing {
    /** 排好版、还没画的一项。 */
    /** 竖排的一个字：中心横坐标、基线纵坐标。 */
    class VGlyph(val text: String, val x: Float, val baseline: Float)

    class Layout(
        val item: OverlayItem,
        val fontSize: Float,
        /** 位图大小（像素）。 */
        val width: Int,
        val height: Int,
        /** 文字排版框 / 图片所在的位置。 */
        val content: RectF,
        val text: StaticLayout?,
        val paint: TextPaint?,
        /** 竖排时每个字画在哪（相对 content 左上角）；横排是 null，用 text 画。 */
        val glyphs: List<VGlyph>? = null,
        val fakeBold: Boolean,
        val boxPath: Path?,
    )

    // MARK: 各种效果的实际大小（都按字号折算）

    private fun strokeLine(item: OverlayItem, fs: Float) = if (item.strokeOn) fs * 0.3f * item.strokeWidth.coerceIn(0f, 1f) else 0f

    /** 阴影偏移。90° 是向下。 */
    private fun shadowOffset(item: OverlayItem, fs: Float, unit: Float = 0.5f): Pair<Float, Float> {
        val d = fs * unit * item.shadowDistance.coerceIn(0f, 1f)
        val a = Math.toRadians(item.shadowAngle.toDouble())
        return (d * cos(a)).toFloat() to (d * sin(a)).toFloat()
    }

    private fun shadowBlur(item: OverlayItem, fs: Float, unit: Float = 0.35f) = fs * unit * item.shadowBlur.coerceIn(0f, 1f)

    private fun glowBlur(item: OverlayItem, fs: Float) = fs * (0.08f + 0.42f * item.glowSize.coerceIn(0f, 1f))

    // MARK: 排版

    fun layout(item: OverlayItem, fs: Float): Layout? {
        if (fs < 1f) return null
        item.image?.let { return imageLayout(item, it.bitmap, fs) }
        item.graphic?.let { return graphicLayout(item, it, fs) }
        if (item.text.isEmpty()) return null

        var fakeBold = false
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG)
        paint.textSize = fs
        if (item.isSticker) {
            paint.typeface = OverlayFonts.resolve(OverlayItem.DEFAULT_FONT_ID).typeface
        } else {
            val r = OverlayFonts.resolve(item.fontID)
            var weight = r.weight
            if (item.bold) {
                // 字体本身已经很粗：用描一圈同色的边来再加粗
                if (weight >= 700) fakeBold = true else weight = 700
            }
            paint.typeface = if (weight != r.weight || item.italic) Typeface.create(r.typeface, weight, item.italic) else r.typeface
            if (item.letterSpacing != 0f) paint.letterSpacing = item.letterSpacing.coerceIn(-0.2f, 2f)
        }
        val spacing = if (item.isSticker) 0f else fs * item.lineSpacing.coerceIn(-0.3f, 2f)
        val align = when {
            item.isSticker -> TextLayout.Alignment.ALIGN_CENTER
            item.align == OverlayAlign.LEFT -> TextLayout.Alignment.ALIGN_NORMAL
            item.align == OverlayAlign.RIGHT -> TextLayout.Alignment.ALIGN_OPPOSITE
            else -> TextLayout.Alignment.ALIGN_CENTER
        }
        // 拉过文字框的边：这个方向上框就是这么长，字排满了自动换行（竖排换列），对齐按这个框来。
        val wrap = if (!item.isSticker && item.wrap > 0f) max(item.wrap, 1.05f) * fs else 0f
        val vertical = !item.isSticker && item.vertical
        var columns: List<VGlyph>? = null
        val static: StaticLayout
        val text: RectF
        if (vertical) {
            val v = verticalLayout(item, paint, fs, wrap)
            columns = v.first
            text = v.second
            static = StaticLayout.Builder.obtain("", 0, 0, paint, 1).build()
        } else {
            val desired = ceil(TextLayout.getDesiredWidth(item.text, paint)).toInt() + 2
            val fitW = if (wrap > 0f) ceil(wrap).toInt() else desired
            static = StaticLayout.Builder.obtain(item.text, 0, item.text.length, paint, max(1, fitW))
                .setAlignment(align)
                .setLineSpacing(spacing, 1f)
                .setIncludePad(false)
                .build()
            text = RectF(0f, 0f, fitW.toFloat(), static.height.toFloat() + 2f)
        }

        var box: Path? = null
        var anchor = RectF(text)
        // 字形可能比排版框大一圈（斜体、花体的笔画），四周至少留这么多。
        var margin = fs * (if (item.isSticker) 0.06f else 0.25f)
        if (!item.isSticker) {
            val line = strokeLine(item, fs) / 2 + (if (fakeBold) fs * 0.03f else 0f)
            margin = max(margin, line + fs * 0.06f)
            if (item.glowOn) margin = max(margin, glowBlur(item, fs) * 1.7f + line)
            if (item.shadowOn) {
                val (ox, oy) = shadowOffset(item, fs)
                margin = max(margin, max(abs(ox), abs(oy)) + shadowBlur(item, fs) * 1.7f + line)
            }
            if (item.boxOn) {
                // 竖排时底色按整块文字画（按行的荧光笔效果只对横排）。
                val lines = if (vertical) listOf(RectF(text)) else lineRects(static, paint, text)
                val p = boxShape(item, text, lines, fs)
                box = p
                val b = RectF()
                @Suppress("DEPRECATION") p.computeBounds(b, true)
                anchor = b
            }
        }
        val union = RectF(text.left - margin, text.top - margin, text.right + margin, text.bottom + margin)
        if (box != null) union.union(RectF(anchor.left - 1, anchor.top - 1, anchor.right + 1, anchor.bottom + 1))
        // 以"底色形状（没有就是文字）"的中心为中心，上下左右对称地留边：调阴影、发光时字的位置不会跳。
        val cx = anchor.centerX()
        val cy = anchor.centerY()
        val halfW = ceil(max(cx - union.left, union.right - cx))
        val halfH = ceil(max(cy - union.top, union.bottom - cy))
        val dx = halfW - cx
        val dy = halfH - cy
        box?.offset(dx, dy)
        text.offset(dx, dy)
        return Layout(item, fs, (halfW * 2).toInt(), (halfH * 2).toInt(), text, static, paint, columns, fakeBold, box)
    }

    /** 竖排标点换成竖排写法（直排用的标点形状）。 */
    private val verticalForms = mapOf(
        '，' to "︐", '、' to "︑", '。' to "︒", '：' to "︓", '；' to "︔", '！' to "︕", '？' to "︖",
        '（' to "︵", '）' to "︶", '《' to "︽", '》' to "︾", '〈' to "︿", '〉' to "﹀", '「' to "﹁", '」' to "﹂",
        '『' to "﹃", '』' to "﹄", '【' to "︻", '】' to "︼", '〔' to "︹", '〕' to "︺", '｛' to "︷", '｝' to "︸",
        '…' to "︙", '—' to "︱", '–' to "︲", '～' to "≀", '~' to "≀", '(' to "︵", ')' to "︶", ',' to "︐",
    )

    /**
     * 竖排：一个字一个字从上往下摆，一列满了（或遇到回车）换到左边一列。
     * 每列宽度定死：字号 ×（1.25 + 行距）；每个字占一个字高（英文数字窄一点），加字距。
     * 返回每个字的位置和整块文字的框（左上角为原点）。
     */
    private fun verticalLayout(item: OverlayItem, paint: TextPaint, fs: Float, wrap: Float): Pair<List<VGlyph>, RectF> {
        val pitch = max(fs * 0.8f, fs * (1.25f + item.lineSpacing.coerceIn(-0.3f, 2f)))
        val kern = if (item.letterSpacing != 0f) fs * item.letterSpacing.coerceIn(-0.2f, 2f) else 0f
        // letterSpacing 已经设在 paint 上；量字宽时先去掉，免得算两遍。
        val saved = paint.letterSpacing
        paint.letterSpacing = 0f
        class Cell(val s: String, val h: Float)
        val cols = ArrayList<ArrayList<Cell>>()
        var col = ArrayList<Cell>()
        var used = 0f
        val points = item.text.codePoints().toArray()
        var i = 0
        while (i < points.size) {
            val cp = points[i]
            i++
            if (cp == '\n'.code) { cols += col; col = ArrayList(); used = 0f; continue }
            val raw = String(Character.toChars(cp))
            val s = if (cp <= 0xFFFF) verticalForms[cp.toChar()] ?: raw else raw
            val w = paint.measureText(s)
            val h = (if (w > fs * 0.8f || verticalForms.containsKey(cp.toChar())) fs else max(w, fs * 0.86f)) + kern
            if (wrap > 0f && col.isNotEmpty() && used + h > wrap + 0.5f) { cols += col; col = ArrayList(); used = 0f }
            col += Cell(s, h)
            used += h
        }
        cols += col
        paint.letterSpacing = 0f
        val fm = paint.fontMetrics
        val lengths = cols.map { c -> c.sumOf { it.h.toDouble() }.toFloat() - (if (c.isNotEmpty()) kern else 0f) }
        val height = max(if (wrap > 0f) wrap else 0f, lengths.maxOrNull() ?: 0f)
        val width = pitch * cols.size
        val out = ArrayList<VGlyph>()
        for ((k, c) in cols.withIndex()) {
            val x = width - pitch * (k + 0.5f)
            val free = height - lengths[k]
            var y = when (item.align) {
                OverlayAlign.LEFT -> 0f
                OverlayAlign.RIGHT -> free
                else -> free / 2
            }
            for (cell in c) {
                val glyphH = cell.h - kern
                out += VGlyph(cell.s, x, y + glyphH / 2 - (fm.ascent + fm.descent) / 2)
                y += cell.h
            }
        }
        paint.letterSpacing = saved
        return out to RectF(0f, 0f, ceil(width) + 2f, ceil(height) + 2f)
    }

    private fun imageLayout(item: OverlayItem, image: Bitmap, width: Float): Layout? {
        if (image.width <= 0 || image.height <= 0) return null
        val w = max(1f, width.roundToInt().toFloat())
        val h = max(1f, (w * image.height / image.width).roundToInt().toFloat())
        var margin = 1f
        val line = if (item.strokeOn) imageOutline(item, w) else 0f
        margin += line * 1.3f
        if (item.shadowOn) {
            val (ox, oy) = shadowOffset(item, w, 0.12f)
            margin = max(margin, max(abs(ox), abs(oy)) + shadowBlur(item, w, 0.08f) * 1.7f + line * 1.3f + 1f)
        }
        margin = ceil(margin)
        return Layout(
            item, w, (w + margin * 2).toInt(), (h + margin * 2).toInt(),
            RectF(margin, margin, margin + w, margin + h), null, null, null, false, null,
        )
    }

    /** 图片贴纸的白边宽度（像素）。 */
    private fun imageOutline(item: OverlayItem, width: Float) = width * 0.06f * item.strokeWidth.coerceIn(0.05f, 1f)

    /** 每一行文字占的位置（荧光笔底色按行画）。 */
    private fun lineRects(layout: StaticLayout, paint: TextPaint, rect: RectF): List<RectF> {
        val fm = paint.fontMetrics
        val out = ArrayList<RectF>()
        for (i in 0 until layout.lineCount) {
            val w = layout.getLineMax(i)
            if (w <= 0.5f) continue
            val left = rect.left + layout.getLineLeft(i)
            val base = rect.top + layout.getLineBaseline(i)
            out += RectF(left, base + fm.ascent, left + w, base + fm.descent)
        }
        return out
    }

    // MARK: 底色形状

    private fun boxShape(item: OverlayItem, t: RectF, lines: List<RectF>, fs: Float): Path {
        val pad = fs * (0.06f + 0.5f * item.boxPadding.coerceIn(0f, 1f))
        val px = pad
        val py = pad * 0.55f
        val body = RectF(t.left - px, t.top - py, t.right + px, t.bottom + py)
        val path = Path()
        when (item.boxShape) {
            OverlayShape.RECT -> path.addRect(body, Path.Direction.CW)
            OverlayShape.ROUNDED -> {
                val r = minOf(fs * 0.28f, body.height() / 2, body.width() / 2)
                path.addRoundRect(body, r, r, Path.Direction.CW)
            }
            OverlayShape.CAPSULE -> {
                val e = body.height() * 0.18f
                val b = RectF(body.left - e, body.top, body.right + e, body.bottom)
                val r = min(b.height(), b.width()) / 2
                path.addRoundRect(b, r, r, Path.Direction.CW)
            }
            OverlayShape.ELLIPSE -> {
                val a = (t.width() / 2 + px * 0.4f) * 1.36f
                val b = (t.height() / 2 + py * 0.6f) * 1.42f
                path.addOval(RectF(t.centerX() - a, t.centerY() - b, t.centerX() + a, t.centerY() + b), Path.Direction.CW)
            }
            OverlayShape.BUBBLE -> {
                val r = minOf(fs * 0.34f, body.height() / 2, body.width() / 2)
                path.addRoundRect(body, r, r, Path.Direction.CW)
                // 左下角的小尾巴
                val x0 = body.left + min(r + fs * 0.1f, body.width() * 0.3f)
                val w = min(fs * 0.5f, body.width() * 0.35f)
                path.moveTo(x0, body.bottom - 1)
                path.lineTo(x0 + w, body.bottom - 1)
                path.lineTo(x0 - fs * 0.08f, body.bottom + fs * 0.42f)
                path.close()
            }
            OverlayShape.SLANT -> {
                val s = body.height() * 0.3f
                val l = body.left - s / 2
                val r = body.right + s / 2
                path.moveTo(l - s / 2, body.bottom)
                path.lineTo(r - s / 2, body.bottom)
                path.lineTo(r + s / 2, body.top)
                path.lineTo(l + s / 2, body.top)
                path.close()
            }
            OverlayShape.TAG -> {
                val d = body.height() * 0.5f
                val r = min(fs * 0.16f, body.height() / 2)
                path.moveTo(body.left - d, body.centerY())
                path.lineTo(body.left, body.top)
                path.lineTo(body.right - r, body.top)
                path.arcTo(RectF(body.right - 2 * r, body.top, body.right, body.top + 2 * r), -90f, 90f)
                path.lineTo(body.right, body.bottom - r)
                path.arcTo(RectF(body.right - 2 * r, body.bottom - 2 * r, body.right, body.bottom), 0f, 90f)
                path.lineTo(body.left, body.bottom)
                path.close()
                // 穿绳子的小孔
                val hole = body.height() * 0.09f
                val hx = body.left - d * 0.38f
                path.addOval(RectF(hx - hole, body.centerY() - hole, hx + hole, body.centerY() + hole), Path.Direction.CW)
                path.fillType = Path.FillType.EVEN_ODD
            }
            OverlayShape.RIBBON -> {
                val d = body.height() * 0.34f
                val l = body.left - d * 1.3f
                val rr = body.right + d * 1.3f
                path.moveTo(l, body.top)
                path.lineTo(rr, body.top)
                path.lineTo(rr - d, body.centerY())
                path.lineTo(rr, body.bottom)
                path.lineTo(l, body.bottom)
                path.lineTo(l + d, body.centerY())
                path.close()
            }
            OverlayShape.MARKER -> {
                // 每一行下半截画一道，像荧光笔划过
                val grow = item.boxPadding.coerceIn(0f, 1f)
                val rects = lines.ifEmpty { listOf(t) }
                for (line in rects) {
                    val h = line.height() * (0.34f + 0.3f * grow)
                    val bottom = line.bottom - line.height() * 0.06f
                    val bar = RectF(line.left - fs * 0.14f, bottom - h, line.right + fs * 0.14f, bottom)
                    val r = min(h * 0.28f, bar.width() / 2)
                    path.addRoundRect(bar, r, r, Path.Direction.CW)
                }
            }
        }
        return path
    }

    // MARK: 画

    fun draw(layout: Layout): Bitmap? {
        val w = layout.width
        val h = layout.height
        if (w < 1 || h < 1) return null
        val out = runCatching { Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888) }.getOrNull() ?: return null
        val canvas = Canvas(out)
        val item = layout.item
        val opacity = item.opacity.coerceIn(0f, 1f)
        if (opacity < 1f) canvas.saveLayerAlpha(null, (opacity * 255).roundToInt())
        when {
            item.image != null -> drawImage(item.image.bitmap, layout, canvas)
            item.graphic != null -> drawGraphic(layout, canvas)
            else -> drawText(layout, canvas)
        }
        if (opacity < 1f) canvas.restore()
        return out
    }

    private fun drawText(layout: Layout, canvas: Canvas) {
        val static = layout.text ?: return
        val paint = layout.paint ?: return
        val item = layout.item
        val fs = layout.fontSize
        val styled = !item.isSticker
        val line = if (styled) strokeLine(item, fs) else 0f
        val bold = if (layout.fakeBold) fs * 0.045f else 0f

        /** 把字画一遍：先描边（如果有），再填充。 */
        fun glyphs(c: Canvas, fill: Int, stroke: Int) {
            c.save()
            c.translate(layout.content.left, layout.content.top)
            paint.strokeJoin = Paint.Join.ROUND
            paint.strokeCap = Paint.Cap.ROUND
            val cells = layout.glyphs
            fun body() {
                if (cells == null) { static.draw(c); return }
                val savedAlign = paint.textAlign
                val savedSpacing = paint.letterSpacing
                paint.textAlign = Paint.Align.CENTER
                paint.letterSpacing = 0f
                for (g in cells) c.drawText(g.text, g.x, g.baseline, paint)
                paint.textAlign = savedAlign
                paint.letterSpacing = savedSpacing
            }
            if (line > 0f) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = line + bold
                paint.color = stroke
                body()
            }
            if (bold > 0f) {
                paint.style = Paint.Style.FILL_AND_STROKE
                paint.strokeWidth = bold
            } else {
                paint.style = Paint.Style.FILL
            }
            paint.color = fill
            body()
            c.restore()
        }

        if (styled && item.boxOn && layout.boxPath != null) {
            val p = Paint(Paint.ANTI_ALIAS_FLAG)
            p.color = item.boxColor.argb(item.boxOpacity)
            canvas.drawPath(layout.boxPath, p)
        }

        if (styled && (item.shadowOn || item.glowOn)) {
            // 先得到"字（连描边）盖住了哪些地方"，阴影和发光都从它模糊出来
            val white = 0xFFFFFFFF.toInt()
            val coverage = coverage(layout.width, layout.height) { glyphs(it, white, white) }
            if (item.shadowOn) {
                val soft = Mask8.softened(coverage, shadowBlur(item, fs))
                val (ox, oy) = shadowOffset(item, fs)
                fill(soft, canvas, RectF(ox, oy, layout.width + ox, layout.height + oy), item.shadowColor.argb(item.shadowOpacity))
            }
            if (item.glowOn) {
                val soft = Mask8.softened(coverage, glowBlur(item, fs))
                val gain = 1.2f + 4.5f * item.glowStrength.coerceIn(0f, 1f)
                Mask8.remap(soft) { (it * gain).toInt() }
                fill(soft, canvas, RectF(0f, 0f, layout.width.toFloat(), layout.height.toFloat()), item.glowColor.argb())
            }
        }

        glyphs(canvas, if (item.isSticker) 0xFFFFFFFF.toInt() else item.color.argb(), item.strokeColor.argb())
    }

    private fun drawImage(image: Bitmap, layout: Layout, canvas: Canvas) {
        val item = layout.item
        val w = layout.width
        val h = layout.height
        val width = layout.fontSize
        val whole = RectF(0f, 0f, w.toFloat(), h.toFloat())
        val bmpPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        if (item.strokeOn || item.shadowOn) {
            // 图片的不透明范围
            var coverage = coverage(w, h) { it.drawBitmap(image, null, layout.content, bmpPaint) }
            if (item.strokeOn) {
                // 往外扩一圈：模糊之后取一个很低的阈值，边缘是圆润的。
                // 模糊可以在缩小的图上做，但取阈值要回到原大小再做，边缘才清楚。
                val line = imageOutline(item, width)
                val soft = Mask8.softened(coverage, line * 1.2f)
                coverage = Mask8.resized(soft, w, h).let { if (it === soft) it.copy() else it }
                Mask8.remap(coverage) { (it - 12) * 18 }
            }
            if (item.shadowOn) {
                val soft = Mask8.softened(coverage, shadowBlur(item, width, 0.08f))
                val (ox, oy) = shadowOffset(item, width, 0.12f)
                fill(soft, canvas, RectF(ox, oy, w + ox, h + oy), item.shadowColor.argb(item.shadowOpacity))
            }
            if (item.strokeOn) fill(coverage, canvas, whole, item.strokeColor.argb())
        }
        canvas.drawBitmap(image, null, layout.content, bmpPaint)
    }

    /** 画一遍，取出"哪些地方被盖住了"（0...255）。 */
    private fun coverage(w: Int, h: Int, draw: (Canvas) -> Unit): Mask8 {
        val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        draw(Canvas(b))
        val m = Mask8.alphaOf(b)
        b.recycle()
        return m
    }

    /** 把覆盖图当蒙版，用指定颜色填到画布里（蒙版会拉伸到 rect 大小）。 */
    private fun fill(mask: Mask8, canvas: Canvas, rect: RectF, color: Int) {
        val a = mask.toAlphaBitmap()
        val p = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        p.color = color
        canvas.drawBitmap(a, null, rect, p)
        a.recycle()
    }

    // MARK: 形状

    /** 形状的描边粗细（像素）：按短边算。 */
    private fun graphicLine(item: OverlayItem, short: Float) =
        if (item.strokeOn) short * 0.12f * item.strokeWidth.coerceIn(0.05f, 1f) else 0f

    private fun graphicLayout(item: OverlayItem, g: GraphicStyle, width: Float): Layout {
        val w = max(2f, width.roundToInt().toFloat())
        val h = max(2f, (w * g.aspect.coerceIn(0.05f, 8f)).roundToInt().toFloat())
        val short = min(w, h)
        val line = graphicLine(item, short)
        var margin = line / 2 + 2f
        if (item.shadowOn) {
            val (ox, oy) = shadowOffset(item, short, 0.15f)
            margin = max(margin, max(abs(ox), abs(oy)) + shadowBlur(item, short, 0.12f) * 1.7f + line / 2 + 2f)
        }
        margin = ceil(margin)
        val rect = RectF(margin, margin, margin + w, margin + h)
        return Layout(item, w, (w + margin * 2).toInt(), (h + margin * 2).toInt(), rect, null, null, null, false, graphicPath(g, rect))
    }

    private fun drawGraphic(layout: Layout, canvas: Canvas) {
        val path = layout.boxPath ?: return
        val item = layout.item
        val g = item.graphic ?: return
        val short = min(layout.content.width(), layout.content.height())
        val line = graphicLine(item, short)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        paint.strokeJoin = Paint.Join.ROUND

        /** 画一遍形状：先填充（如果有），再描边。 */
        fun shape(c: Canvas, fill: Int, stroke: Int) {
            if (g.fill) {
                paint.style = Paint.Style.FILL
                paint.color = fill
                c.drawPath(path, paint)
            }
            if (line > 0f) {
                paint.style = Paint.Style.STROKE
                paint.strokeWidth = line
                paint.color = stroke
                c.drawPath(path, paint)
            }
        }

        if (item.shadowOn) {
            val white = 0xFFFFFFFF.toInt()
            val coverage = coverage(layout.width, layout.height) { shape(it, white, white) }
            val soft = Mask8.softened(coverage, shadowBlur(item, short, 0.12f))
            val (ox, oy) = shadowOffset(item, short, 0.15f)
            fill(soft, canvas, RectF(ox, oy, layout.width + ox, layout.height + oy), item.shadowColor.argb(item.shadowOpacity))
        }
        shape(canvas, item.color.argb(), item.strokeColor.argb())
    }

    /** 形状的轮廓（安卓坐标，y 向下）。 */
    fun graphicPath(g: GraphicStyle, r: RectF): Path {
        val short = min(r.width(), r.height())
        val cx = r.centerX()
        val cy = r.centerY()
        return when (g.kind) {
            GraphicKind.RECT -> cornerPolygon(
                listOf(PointF(r.left, r.top), PointF(r.right, r.top), PointF(r.right, r.bottom), PointF(r.left, r.bottom)),
                radius = g.corner * short / 2, cut = g.cut * short, cutMask = g.cutCorners,
            )
            GraphicKind.ELLIPSE -> Path().apply { addOval(r, Path.Direction.CW) }
            GraphicKind.POLYGON -> {
                val n = g.sides.coerceIn(3, 12)
                val pts = (0 until n).map { i ->
                    val a = PI / 2 - i * 2 * PI / n
                    PointF(cx + cos(a).toFloat() * r.width() / 2, cy - sin(a).toFloat() * r.height() / 2)
                }
                cornerPolygon(pts, radius = g.corner * short / 4)
            }
            GraphicKind.STAR -> {
                val n = g.sides.coerceIn(4, 12)
                val pts = (0 until n * 2).map { i ->
                    val k = if (i % 2 == 0) 1f else 0.45f
                    val a = PI / 2 - i * PI / n
                    PointF(cx + cos(a).toFloat() * r.width() / 2 * k, cy - sin(a).toFloat() * r.height() / 2 * k)
                }
                cornerPolygon(pts, radius = g.corner * short / 10)
            }
            GraphicKind.HEART -> {
                // 单位方框里的爱心（y 向上），再拉到 r。
                fun x(v: Float) = r.left + v * r.width()
                fun y(v: Float) = r.top + (1 - v) * r.height()
                Path().apply {
                    moveTo(x(0.5f), y(0.02f))
                    cubicTo(x(0.25f), y(0.22f), x(0.02f), y(0.4f), x(0.02f), y(0.62f))
                    cubicTo(x(0.02f), y(0.98f), x(0.4f), y(1f), x(0.5f), y(0.8f))
                    cubicTo(x(0.6f), y(1f), x(0.98f), y(0.98f), x(0.98f), y(0.62f))
                    cubicTo(x(0.98f), y(0.4f), x(0.75f), y(0.22f), x(0.5f), y(0.02f))
                    close()
                }
            }
            GraphicKind.ARROW -> {
                val head = min(r.width() * 0.45f, r.height())
                val shaft = r.height() * 0.42f
                val neck = r.right - head
                val pts = listOf(
                    PointF(r.left, cy - shaft / 2), PointF(neck, cy - shaft / 2), PointF(neck, r.top), PointF(r.right, cy),
                    PointF(neck, r.bottom), PointF(neck, cy + shaft / 2), PointF(r.left, cy + shaft / 2),
                )
                cornerPolygon(pts, radius = g.corner * short / 8)
            }
            GraphicKind.BUBBLE -> {
                // 圆角方框，左下角拖一个小尾巴。
                val tail = short * 0.22f
                val body = RectF(r.left, r.top, r.right, r.bottom - tail)
                val rad = max(g.corner, 0.15f) * min(body.width(), body.height()) / 2
                val box = Path().apply { addRoundRect(body, rad, rad, Path.Direction.CW) }
                val tip = Path().apply {
                    moveTo(body.left + body.width() * 0.18f, body.bottom - 1)
                    lineTo(body.left + body.width() * 0.1f, r.bottom)
                    lineTo(body.left + body.width() * 0.34f, body.bottom - 1)
                    close()
                }
                // 合成一个轮廓：描边时尾巴和方框之间不会多出一道线。
                box.op(tip, Path.Op.UNION)
                box
            }
        }
    }

    /** 多边形：每个角可以圆角，也可以切掉（cutMask 里第 i 位 = 第 i 个角）。 */
    private fun cornerPolygon(pts: List<PointF>, radius: Float, cut: Float = 0f, cutMask: Int = 0): Path {
        val n = pts.size
        val p = Path()
        if (n < 3) return p
        fun len(a: PointF, b: PointF) = hypot(b.x - a.x, b.y - a.y)
        fun unit(a: PointF, b: PointF): PointF {
            val d = max(len(a, b), 0.0001f)
            return PointF((b.x - a.x) / d, (b.y - a.y) / d)
        }
        // 从第 0 条边的中点出发，绕一圈。
        p.moveTo((pts[0].x + pts[1].x) / 2, (pts[0].y + pts[1].y) / 2)
        for (k in 1..n) {
            val i = k % n
            val prev = pts[(i - 1 + n) % n]
            val cur = pts[i]
            val next = pts[(i + 1) % n]
            val maxLen = min(len(prev, cur), len(cur, next)) / 2
            val a = unit(cur, prev)
            val b = unit(cur, next)
            if (cut > 0f && cutMask and (1 shl i) != 0) {
                val c = min(cut, maxLen)
                p.lineTo(cur.x + a.x * c, cur.y + a.y * c)
                p.lineTo(cur.x + b.x * c, cur.y + b.y * c)
            } else if (radius > 0.5f) {
                roundCorner(p, cur, a, b, min(radius, maxLen), maxLen)
            } else {
                p.lineTo(cur.x, cur.y)
            }
        }
        p.close()
        return p
    }

    /** 在 cur 这个角画圆角：a、b 是从角出发沿两条边的方向。切点离角最多 maxLen。 */
    private fun roundCorner(p: Path, cur: PointF, a: PointF, b: PointF, radius: Float, maxLen: Float) {
        val theta = acos((a.x * b.x + a.y * b.y).coerceIn(-1f, 1f))
        if (theta < 0.01f || theta > PI.toFloat() - 0.01f) {
            p.lineTo(cur.x, cur.y)
            return
        }
        val half = tan(theta / 2)
        val t = min(radius / half, maxLen)
        val r = t * half
        val turn = PI.toFloat() - theta
        val k = 4f / 3f * tan(turn / 4) * r
        val p1x = cur.x + a.x * t
        val p1y = cur.y + a.y * t
        val p2x = cur.x + b.x * t
        val p2y = cur.y + b.y * t
        p.lineTo(p1x, p1y)
        p.cubicTo(p1x - a.x * k, p1y - a.y * k, p2x - b.x * k, p2y - b.y * k, p2x, p2y)
    }
}
