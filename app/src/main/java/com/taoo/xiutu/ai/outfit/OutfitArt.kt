package com.taoo.xiutu.ai.outfit

import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

/** 衣服的剪影小图。 */
@Composable
fun OutfitArt(shape: String, color: Color, modifier: Modifier = Modifier) {
    Canvas(modifier) { drawOutfit(shape, color) }
}

private fun DrawScope.drawOutfit(shape: String, color: Color) {
    val w = size.width
    val h = size.height
    val dark = Color.Black.copy(alpha = 0.18f)
    val ink = Color.Black.copy(alpha = 0.22f)
    val cloth = Brush.verticalGradient(listOf(color, color.copy(alpha = 0.82f)), 0f, h)
    fun poly(vararg v: Float) = Path().apply {
        for (i in v.indices step 2) if (i == 0) moveTo(v[0] * w, v[1] * h) else lineTo(v[i] * w, v[i + 1] * h)
        close()
    }
    fun oval(x: Float, y: Float, ow: Float, oh: Float) = Path().apply { addOval(Rect(x * w, y * h, (x + ow) * w, (y + oh) * h)) }
    fun curve(x0: Float, y0: Float, x1: Float, y1: Float, cx: Float, cy: Float) = Path().apply {
        moveTo(x0 * w, y0 * h)
        quadraticTo(cx * w, cy * h, x1 * w, y1 * h)
    }
    fun line(path: Path, width: Float) = drawPath(path, ink, style = Stroke(width * density))
    fun fill(path: Path) {
        drawPath(path, cloth)
        line(path, 1f)
    }
    when (shape) {
    "gown" -> {
        val skirt = Path()
        skirt.moveTo(0.42f * w, 0.4f * h)
        skirt.cubicTo(0.34f * w, 0.5f * h, 0.08f * w, 0.62f * h, 0.06f * w, 0.95f * h)
        skirt.quadraticTo(0.5f * w, 1.03f * h, 0.94f * w, 0.95f * h)
        skirt.cubicTo(0.92f * w, 0.62f * h, 0.66f * w, 0.5f * h, 0.58f * w, 0.4f * h)
        skirt.close()
        fill(poly(0.36f, 0.17f, 0.5f, 0.21f, 0.64f, 0.17f, 0.6f, 0.42f, 0.4f, 0.42f))
        fill(oval(0.24f, 0.15f, 0.15f, 0.13f))
        fill(oval(0.61f, 0.15f, 0.15f, 0.13f))
        fill(skirt)
        for (x in floatArrayOf(0.28f, 0.5f, 0.72f)) { line(curve(0.5f, 0.45f, x, 0.94f, (0.5f + x) / 2, 0.62f), 1f) }
    }
    "mermaid" -> {
        val d = Path()
        d.moveTo(0.38f * w, 0.14f * h)
        d.quadraticTo(0.4f * w, 0.28f * h, 0.42f * w, 0.4f * h)
        d.quadraticTo(0.31f * w, 0.54f * h, 0.4f * w, 0.68f * h)
        d.quadraticTo(0.34f * w, 0.86f * h, 0.18f * w, 0.95f * h)
        d.quadraticTo(0.5f * w, 1.0f * h, 0.82f * w, 0.95f * h)
        d.quadraticTo(0.66f * w, 0.86f * h, 0.6f * w, 0.68f * h)
        d.quadraticTo(0.69f * w, 0.54f * h, 0.58f * w, 0.4f * h)
        d.quadraticTo(0.6f * w, 0.28f * h, 0.62f * w, 0.14f * h)
        d.quadraticTo(0.5f * w, 0.26f * h, 0.38f * w, 0.14f * h)
        fill(d)
        for (x in floatArrayOf(0.36f, 0.64f)) { line(curve(0.5f, 0.7f, x, 0.95f, 0.48f, 0.84f), 1f) }
    }
    "aline" -> {
        fill(poly(0.37f, 0.14f, 0.45f, 0.2f, 0.55f, 0.2f, 0.63f, 0.14f, 0.6f, 0.4f, 0.8f, 0.94f, 0.2f, 0.94f, 0.4f, 0.4f))
        drawPath(poly(0.395f, 0.39f, 0.605f, 0.39f, 0.612f, 0.43f, 0.388f, 0.43f), dark)
        for (x in floatArrayOf(0.38f, 0.5f, 0.62f)) { line(curve(0.5f, 0.45f, x, 0.93f, 0.5f, 0.7f), 1f) }
    }
    "short", "lolita" -> {
        val low = if (shape == "lolita") 0.76f else 0.68f
        fill(poly(0.37f, 0.16f, 0.45f, 0.22f, 0.55f, 0.22f, 0.63f, 0.16f, 0.6f, 0.42f, 0.4f, 0.42f))
        val s = Path()
        s.moveTo(0.4f * w, 0.42f * h)
        s.quadraticTo(0.22f * w, 0.5f * h, 0.16f * w, low * h)
        val n = 6
        for (i in 0 until n) {
            val a = 0.16f + 0.68f * i.toFloat() / n
            val c = 0.16f + 0.68f * (i + 1).toFloat() / n
            s.quadraticTo(((a + c) / 2) * w, (low + 0.07f) * h, c * w, low * h)
        }
        s.quadraticTo(0.78f * w, 0.5f * h, 0.6f * w, 0.42f * h)
        s.close()
        if (shape == "lolita") {
            for (x in floatArrayOf(0.22f, 0.61f)) { fill(oval(x, 0.16f, 0.17f, 0.15f)) }
        }
        fill(s)
        drawPath(poly(0.395f, 0.4f, 0.605f, 0.4f, 0.612f, 0.44f, 0.388f, 0.44f), dark)
    }
    "qipao" -> {
        val d = Path()
        d.moveTo(0.44f * w, 0.12f * h)
        d.lineTo(0.56f * w, 0.12f * h)
        d.lineTo(0.7f * w, 0.2f * h)
        d.lineTo(0.72f * w, 0.28f * h)
        d.lineTo(0.61f * w, 0.27f * h)
        d.quadraticTo(0.62f * w, 0.36f * h, 0.59f * w, 0.44f * h)
        d.quadraticTo(0.72f * w, 0.62f * h, 0.64f * w, 0.93f * h)
        d.lineTo(0.36f * w, 0.93f * h)
        d.quadraticTo(0.28f * w, 0.62f * h, 0.41f * w, 0.44f * h)
        d.quadraticTo(0.38f * w, 0.36f * h, 0.39f * w, 0.27f * h)
        d.lineTo(0.28f * w, 0.28f * h)
        d.lineTo(0.3f * w, 0.2f * h)
        d.close()
        fill(d)
        line(curve(0.5f, 0.13f, 0.62f, 0.28f, 0.52f, 0.26f), 1.5f)
        line(curve(0.6f, 0.93f, 0.65f, 0.66f, 0.62f, 0.8f), 1.5f)
    }
    "kimono", "hanfu" -> {
        val sleeve = if (shape == "kimono") 0.62f else 0.56f
        val low = if (shape == "kimono") 0.54f else 0.47f
        fill(poly(0.38f, 0.16f, 0.1f, 0.24f, 0.06f, sleeve, 0.3f, sleeve, 0.34f, 0.36f))
        fill(poly(0.62f, 0.16f, 0.9f, 0.24f, 0.94f, sleeve, 0.7f, sleeve, 0.66f, 0.36f))
        val hem = if (shape == "kimono") 0.66f else 0.78f
        fill(poly(0.38f, 0.14f, 0.62f, 0.14f, 0.66f, 0.42f, hem, 0.95f, 1 - hem, 0.95f, 0.34f, 0.42f))
        line(poly(0.42f, 0.14f, 0.56f, 0.36f, 0.6f, 0.14f), 1.5f)
        drawPath(poly(0.345f, 0.4f, 0.655f, 0.4f, 0.66f, low, 0.34f, low), dark)
        line(curve(0.5f, 0.5f, 0.46f, 0.94f, 0.52f, 0.72f), 1f)
    }
    "sailor" -> {
        fill(poly(0.36f, 0.16f, 0.64f, 0.16f, 0.8f, 0.26f, 0.76f, 0.42f, 0.66f, 0.38f, 0.64f, 0.52f, 0.36f, 0.52f, 0.34f, 0.38f, 0.24f, 0.42f, 0.2f, 0.26f))
        drawPath(poly(0.36f, 0.16f, 0.64f, 0.16f, 0.68f, 0.26f, 0.5f, 0.38f, 0.32f, 0.26f), dark)
        fill(poly(0.37f, 0.52f, 0.63f, 0.52f, 0.76f, 0.82f, 0.24f, 0.82f))
        for (i in 1 until 6) {
            val t = i.toFloat() / 6
            line(curve(0.37f + 0.26f * t, 0.53f, 0.24f + 0.52f * t, 0.82f, 0.31f + 0.39f * t, 0.67f), 1f)
        }
    }
    "suit", "coat" -> {
        val hem = if (shape == "coat") 0.86f else 0.6f
        fill(poly(0.36f, 0.14f, 0.64f, 0.14f, 0.8f, 0.24f, 0.86f, 0.6f, 0.74f, 0.62f, 0.69f, 0.36f, 0.71f, hem, 0.29f, hem, 0.31f, 0.36f, 0.26f, 0.62f, 0.14f, 0.6f, 0.2f, 0.24f))
        if (shape == "suit") { fill(poly(0.33f, 0.6f, 0.67f, 0.6f, 0.66f, 0.95f, 0.53f, 0.95f, 0.5f, 0.68f, 0.47f, 0.95f, 0.34f, 0.95f)) }
        drawPath(poly(0.42f, 0.14f, 0.5f, 0.36f, 0.58f, 0.14f), Color.White.copy(alpha = 0.85f))
        line(curve(0.5f, 0.36f, 0.5f, hem, 0.5f, 0.5f), 1.5f)
        if (shape == "coat") { drawPath(poly(0.3f, 0.5f, 0.7f, 0.5f, 0.7f, 0.55f, 0.3f, 0.55f), dark) }
    }
    "armor" -> {
        fill(poly(0.5f, 0.36f, 0.78f, 0.94f, 0.22f, 0.94f))
        fill(poly(0.36f, 0.15f, 0.64f, 0.15f, 0.68f, 0.34f, 0.6f, 0.56f, 0.4f, 0.56f, 0.32f, 0.34f))
        for (x in floatArrayOf(0.19f, 0.62f)) { fill(oval(x, 0.14f, 0.19f, 0.15f)) }
        line(curve(0.5f, 0.2f, 0.5f, 0.55f, 0.5f, 0.4f), 1.5f)
        drawPath(poly(0.39f, 0.5f, 0.61f, 0.5f, 0.6f, 0.56f, 0.4f, 0.56f), dark)
    }
    "hoodie" -> {
        fill(poly(0.36f, 0.2f, 0.64f, 0.2f, 0.82f, 0.3f, 0.88f, 0.66f, 0.75f, 0.68f, 0.69f, 0.44f, 0.69f, 0.72f, 0.31f, 0.72f, 0.31f, 0.44f, 0.25f, 0.68f, 0.12f, 0.66f, 0.18f, 0.3f))
        fill(oval(0.35f, 0.1f, 0.3f, 0.17f))
        drawPath(poly(0.38f, 0.52f, 0.62f, 0.52f, 0.66f, 0.66f, 0.34f, 0.66f), dark)
    }
    else -> {
        fill(poly(0.38f, 0.16f, 0.46f, 0.2f, 0.54f, 0.2f, 0.62f, 0.16f, 0.8f, 0.24f, 0.84f, 0.46f, 0.72f, 0.48f, 0.67f, 0.36f, 0.66f, 0.58f, 0.34f, 0.58f, 0.33f, 0.36f, 0.28f, 0.48f, 0.16f, 0.46f, 0.2f, 0.24f))
        line(curve(0.5f, 0.2f, 0.5f, 0.57f, 0.5f, 0.4f), 1.2f)
        fill(poly(0.35f, 0.58f, 0.65f, 0.58f, 0.72f, 0.94f, 0.28f, 0.94f))
    }
    }
}
