package com.taoo.xiutu.ai

import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.tools.adjust.AdjustKey
import com.taoo.xiutu.tools.adjust.AdjustOp
import com.taoo.xiutu.tools.adjust.AdjustParams
import com.taoo.xiutu.tools.adjust.LocalAdjust
import com.taoo.xiutu.tools.beauty.BeautyParams
import com.taoo.xiutu.tools.crop.CropOp
import com.taoo.xiutu.tools.crop.CropParams
import com.taoo.xiutu.tools.filter.LookOp
import com.taoo.xiutu.tools.shape.ShapeAI
import com.taoo.xiutu.tools.shape.ShapeItem
import com.taoo.xiutu.tools.shape.V2
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

class AIKeepTest {
    private fun points() = Random(7).let { r -> List(30) { V2(0.4f + r.nextFloat() * 0.2f, 0.3f + r.nextFloat() * 0.25f) } }

    private fun moved(p: List<V2>, k: Double, angle: Double, tx: Double, ty: Double) = p.map {
        val a = k * cos(angle)
        val b = k * sin(angle)
        V2((a * it.x - b * it.y + tx).toFloat(), (b * it.x + a * it.y + ty).toFloat())
    }

    @Test fun similarity() {
        val p = points()
        val f = FaceKeep.similarity(p, moved(p, 1.3, 0.2, -0.05, 0.1), 0.2f)!!
        assertEquals(1.3 * cos(0.2), f.a, 1e-4)
        assertEquals(1.3 * sin(0.2), f.b, 1e-4)
        assertEquals(-0.05, f.tx, 1e-4)
        assertEquals(0.1, f.ty, 1e-4)
        assertTrue(f.error < 1e-4)
    }

    /** 五官差太多（换了表情、转了头）、点太少、左右镜像都不贴。 */
    @Test fun similarityRejects() {
        val p = points()
        val r = Random(3)
        val noisy = p.map { V2(it.x + (r.nextFloat() - 0.5f) * 0.05f, it.y + (r.nextFloat() - 0.5f) * 0.05f) }
        assertNull(FaceKeep.similarity(p, noisy, 0.2f))
        assertNotNull(FaceKeep.similarity(p, noisy, 1f))
        assertNull(FaceKeep.similarity(p.take(8), p.take(8), 0.2f))
        assertNull(FaceKeep.similarity(p, p.map { V2(1 - it.x, it.y) }, 0.2f))
    }

    @Test fun hull() {
        val square = listOf(V2(0f, 0f), V2(1f, 0f), V2(1f, 1f), V2(0f, 1f), V2(0.5f, 0.5f), V2(0.2f, 0.7f))
        assertEquals(4, FaceKeep.convexHull(square).size)
    }

    private val look = LookOp("leica", 1f)
    private val adjust = AdjustOp(AdjustParams().with(AdjustKey.BRIGHTNESS, 0.3f))
    private val local = AdjustOp(AdjustParams(locals = listOf(LocalAdjust(cx = 0.5f, cy = 0.5f, brightness = 0.4f))))
    private val beauty = BeautyParams()
    private val crop = CropOp(CropParams(quarterTurns = 1))

    @Test fun splitColor() {
        // 末尾的滤镜、整张调色拿下来，越过美颜，遇到裁剪就停
        val ops: List<EditOp> = listOf(look, crop, adjust, beauty, look)
        val (base, color) = EditOp.splitColor(ops)
        assertEquals(listOf(look, crop, beauty), base)
        assertEquals(listOf(adjust, look), color)
        assertSame(adjust, color[0])
        // 局部调色和位置绑在一起，不拿，也挡住前面的
        assertEquals(listOf(look, local) to listOf<EditOp>(adjust), EditOp.splitColor(listOf(look, local, adjust)))
        assertEquals(emptyList<EditOp>() to emptyList<EditOp>(), EditOp.splitColor(emptyList()))
    }

    /** 一张随机图整体挪一点：能找回来；挪太多或没挪就不动。 */
    @Test fun shift() {
        fun make(side: Int, dx: Float, dy: Float): ChangeKeep.Pair8 {
            fun tex(x: Float, y: Float) = 120f + 60f * sin(x * 23f + sin(y * 9f)) * cos(y * 31f) + 30f * sin((x + y) * 57f)
            val w = side
            val h = side * 3 / 4
            val a = FloatArray(w * h) { tex((it % w) / w.toFloat(), (it / w) / w.toFloat()) }
            // b 整体偏了 (-dx, -dy)，再变亮一点
            val b = FloatArray(w * h) { tex((it % w) / w.toFloat() + dx, (it / w) / w.toFloat() + dy * h / w) * 0.95f + 12f }
            return ChangeKeep.Pair8(a, b, w, h)
        }
        for ((dx, dy) in listOf(0.011f to -0.008f, -0.015f to 0.004f, 0.003f to 0.017f)) {
            val (x, y) = ChangeKeep.shift(make(256, dx, dy), make(768, dx, dy))
            assertTrue("$dx → $x", abs(x - dx) < 0.0012f)
            assertTrue("$dy → $y", abs(y - dy) < 0.0012f)
        }
        assertEquals(0f to 0f, ChangeKeep.shift(make(256, 0f, 0f), make(768, 0f, 0f)))
        val flat = ChangeKeep.Pair8(FloatArray(256 * 192) { 90f }, FloatArray(256 * 192) { 100f }, 256, 192)
        assertEquals(0f to 0f, ChangeKeep.shift(flat, flat))
    }

    @Test fun mono() {
        assertTrue(MonoCheck.isMono(IntArray(2304) { val v = it % 256; (v shl 16) or (v shl 8) or (v + 3).coerceAtMost(255) }))
        assertTrue(!MonoCheck.isMono(IntArray(2304) { if (it < 100) 0xC08040 else 0x808080 }))
    }

    @Test fun masters() {
        MasterCatalog.load(File("src/main/assets/masters.json").readText())
        assertEquals(47, MasterCatalog.all.size)
        assertEquals(47, MasterCatalog.byTitle.size)
        assertTrue(MasterCatalog.groups.size in 5..12)
        val m = MasterCatalog.all.first()
        assertTrue(m.prompt.contains(MasterCompose.KEEP_TAIL))
        val person = MasterCompose.prompt(m.prompt, m.title, m.frames[1].title, hasPerson = true)!!
        assertTrue(m.frames[1].person in person && MasterCompose.REAL_TAIL in person && MasterCompose.KEEP_TAIL !in person)
        val scene = MasterCompose.prompt(m.prompt, m.title, null, hasPerson = false)!!
        assertTrue(m.frames[0].scene in scene && "结果里也不能出现任何人" in scene)
        assertNull(MasterCompose.prompt("随便写的", m.title, null, hasPerson = true))
        assertNull(MasterCompose.prompt(m.prompt, "没有这个人", null, hasPerson = true))
    }

    /** 只动一个部位的加上限制；体态类的不说"姿势不变"。 */
    @Test fun shapePrompts() {
        val chest = ShapeAI.preset(ShapeItem.AI_CHEST)!!
        assertEquals(BodyPart.CHEST, chest.part)
        assertTrue("手、头发、腰腹和背景都不动" in chest.prompt && "不磨皮、不涂抹" in chest.prompt)
        val waist = ShapeAI.preset(ShapeItem.AI_WAIST)!!
        assertTrue("手、头发和背景都不动" in waist.prompt && "腰腹和背景都不动" !in waist.prompt)
        val arm = ShapeAI.preset(ShapeItem.AI_ARM)!!
        assertTrue(arm.part == null && "只改上面说的部位" !in arm.prompt)
        assertTrue("其余姿势不变" in ShapeAI.preset(ShapeItem.AI_STRAIGHT_BACK)!!.prompt)
    }
}
