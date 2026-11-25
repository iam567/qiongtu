package com.taoo.xiutu.ai

import com.taoo.xiutu.ai.outfit.OutfitCatalog
import com.taoo.xiutu.ai.outfit.OutfitMask
import com.taoo.xiutu.ai.outfit.OutfitSkirt
import com.taoo.xiutu.ai.outfit.Wardrobe
import com.taoo.xiutu.ai.outfit.WardrobeItem
import com.taoo.xiutu.editor.EditOp
import com.taoo.xiutu.ml.Mask8
import com.taoo.xiutu.ml.PersonSegmenter
import com.taoo.xiutu.tools.adjust.AdjustKey
import com.taoo.xiutu.tools.adjust.AdjustOp
import com.taoo.xiutu.tools.adjust.AdjustParams
import com.taoo.xiutu.tools.adjust.LocalAdjust
import com.taoo.xiutu.tools.beauty.BeautyParams
import com.taoo.xiutu.tools.bodytone.BodyToneParams
import com.taoo.xiutu.tools.color.V3
import com.taoo.xiutu.tools.crop.CropOp
import com.taoo.xiutu.tools.crop.CropParams
import com.taoo.xiutu.tools.filter.LookOp
import com.taoo.xiutu.tools.shape.ShapeAI
import com.taoo.xiutu.tools.shape.ShapeItem
import com.taoo.xiutu.tools.shape.V2
import com.taoo.xiutu.tools.smartcrop.SmartCrop
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
        val list = AIPresetGroup.MASTER.presets
        assertEquals(22, list.size)
        for (m in list) {
            assertTrue(m.title, MasterCompose.prompt(m.prompt, m.title, hasPerson = true) != null)
            assertTrue(m.title, MasterCompose.prompt(m.prompt, m.title, hasPerson = false) != null)
            assertTrue(m.title, "黑白" !in m.prompt.replace("不要变成黑白", ""))
        }
        assertEquals(9, list.count { "画面保持彩色，不要变成黑白" in it.prompt })
    }

    @Test fun outfits() {
        OutfitCatalog.load(File("src/main/assets/outfits.json").readText())
        assertEquals(51, OutfitCatalog.all.size)
        assertTrue(OutfitCatalog.groups(true).isNotEmpty() && OutfitCatalog.groups(false).size >= 4)
        for (o in OutfitCatalog.all) for (c in o.colors) assertNotNull("${o.title} $c", OutfitCatalog.rgb(c))
        val gown = OutfitCatalog.all.first { it.skirt }
        val p = OutfitCatalog.prompt(gown, "粉色", OutfitSkirt.OVERFLOW)
        assertTrue(gown.prompt in p && "颜色是粉色。裙摆做得极大" in p && p.endsWith(OutfitCatalog.KEEP))
        assertTrue(AIIntent.replacesContent(OutfitCatalog.PATCH_PROMPT))
        assertTrue(AIIntent.changesClothes("给她换一件红色礼服") && !AIIntent.changesClothes("把天空换成晚霞") && !AIIntent.changesClothes("裙子颜色深一点"))
    }

    /** 换衣服裁多大：人占一小块时裁人和两边余量；人占满时不裁。 */
    @Test fun outfitCrop() {
        fun mask(x0: Int, y0: Int, x1: Int, y1: Int) =
            Mask8(ByteArray(128 * 128) { if (it % 128 in x0..x1 && it / 128 in y0..y1) -1 else 0 }, 128, 128)
        val b = OutfitMask.cropBox(mask(58, 40, 70, 110), 3000f, 2000f)!!
        assertTrue(b[0] < 58 / 128f - 0.04f && b[2] > 71 / 128f + 0.04f && b[1] < 40 / 128f && b[3] > 111 / 128f)
        assertTrue((b[3] - b[1]) * 2000 <= (b[2] - b[0]) * 3000 * 2.2f + 1)
        assertNull(OutfitMask.cropBox(mask(20, 5, 110, 127), 2000f, 3000f))
        assertNull(OutfitMask.cropBox(Mask8(ByteArray(128 * 128), 128, 128), 2000f, 3000f))
    }

    /** 零星误认成人的小块去掉，差不多大的两个人都留下。 */
    @Test fun mainPerson() {
        val w = 192
        val px = ByteArray(w * w)
        fun box(x0: Int, y0: Int, s: Int) { for (y in y0 until y0 + s) for (x in x0 until x0 + s) px[y * w + x] = -1 }
        box(20, 20, 60); box(120, 20, 40); box(20, 150, 12)
        val m = PersonSegmenter.main(Mask8(px, w, w))
        assertEquals(255, m[50 * w + 50])
        assertEquals(255, m[40 * w + 140])
        assertEquals(0, m[155 * w + 25])
    }

    @Test fun stillFace() {
        val o = listOf(V2(0.4f, 0.4f), V2(0.6f, 0.4f), V2(0.5f, 0.6f))
        assertTrue(FaceKeep(1.01, 0.01, 0.002, -0.004, o, 0.2f).isStill)
        assertTrue(!FaceKeep(1.0, 0.0, 0.05, 0.0, o, 0.2f).isStill)
        assertTrue(!FaceKeep(1.1, 0.0, -0.04, -0.04, o, 0.2f).isStill)
    }

    @Test fun faceTiles() {
        assertEquals(listOf(0f, 0.3f, 0.5f), com.taoo.xiutu.ml.FaceFinder.starts(0.5f))
        assertEquals(0.82f, com.taoo.xiutu.ml.FaceFinder.starts(0.18f).last(), 1e-5f)
        val boxes = SmartCrop.boxes("<think>{看}</think>{\"faces\":[{\"box\":[420,180,560,360]},{\"box\":[1,1,2,2]},{\"box_2d\":[0.1,0.2,0.3,0.4]}]}", "faces")
        assertEquals(2, boxes.size)
        assertEquals(0.42f, boxes[0].x, 1e-5f)
        assertEquals(0.2f, boxes[1].x, 1e-5f)
        assertTrue(SmartCrop.boxes("{\"faces\":[]}", "faces").isEmpty())
    }

    /** 只动一个部位的加上限制；体态类的不说"姿势不变"。 */
    @Test fun shapePrompts() {
        val chest = ShapeAI.preset(ShapeItem.AI_CHEST)!!
        assertEquals(BodyPart.CHEST, chest.part)
        assertTrue("手、头发、腰腹和背景都不动" in chest.prompt && "不磨皮、不涂抹，也不增加斑点" in chest.prompt)
        val waist = ShapeAI.preset(ShapeItem.AI_WAIST)!!
        assertTrue("手、头发和背景都不动" in waist.prompt && "腰腹和背景都不动" !in waist.prompt)
        val arm = ShapeAI.preset(ShapeItem.AI_ARM)!!
        assertTrue(arm.part == null && "只改上面说的部位" !in arm.prompt)
        assertTrue("其余姿势不变" in ShapeAI.preset(ShapeItem.AI_STRAIGHT_BACK)!!.prompt)
    }

    /** 修完的脸像不像原来：整体变亮、对比变了照样算像；换了样子不像。 */
    @Test fun faceLikeness() {
        val r = Random(5)
        val a = DoubleArray(576) { 120 + 50 * sin(it % 24 * 0.5) * cos(it / 24 * 0.4) }
        assertTrue(FaceCheck.correlation(a, DoubleArray(576) { a[it] * 1.1 + 12 + r.nextDouble() * 4 }) > 0.95)
        assertTrue(FaceCheck.correlation(a, DoubleArray(576) { 120 + 50 * cos(it % 24 * 0.5 + 1.2) }) < 0.6)
        assertEquals(1.0, FaceCheck.correlation(DoubleArray(576) { 9.0 }, a), 0.0)
        val reply = "<think>嗯</think>```json\n{\"faces\":[{\"box\":[300,200,700,800]}],\"desc\":\"head tilted left\"}\n```"
        assertEquals("head tilted left", SmartCrop.text(reply, "faces", "desc"))
        assertEquals("", SmartCrop.text("看不清", "faces", "desc"))
        assertTrue(FaceCheck.DESCRIBE_PROMPT.lines().none { it.startsWith(" ") })
    }

    /** 匹配脸色拉满时，身体的平均色正好变成脸色（偏暗、偏亮的通道都对）。 */
    @Test fun bodyMatchesFace() {
        for ((face, body) in listOf(V3(0.88f, 0.71f, 0.61f) to V3(0.70f, 0.56f, 0.49f), V3(0.6f, 0.5f, 0.45f) to V3(0.7f, 0.48f, 0.5f), V3(0.95f, 0.9f, 0.85f) to V3(0.45f, 0.33f, 0.28f))) {
            val g = BodyToneParams(faceMean = face, bodyMean = body).gain()
            val c = body.array()
            val t = face.array()
            for (i in 0..2) {
                // 和着色器同一个式子
                val out = c[i] * g[i] / (1 + c[i] * maxOf(g[i] - 1, 0f))
                assertEquals(t[i], out, if (g[i] >= 5f) 0.2f else 0.002f)
            }
        }
    }

    @Test fun wardrobe() {
        val item = WardrobeItem("a", "衣服 1", 0, desc = "红色长裙", count = 2)
        val p = Wardrobe.prompt(item, OutfitSkirt.TRAIN)
        assertTrue(p.startsWith("把第一张图里主要人物的衣服换成参考图里的那一身。") && "这身衣服的样子：红色长裙。必须" in p)
        assertTrue(OutfitSkirt.TRAIN.prompt + OutfitCatalog.CLEAN + OutfitCatalog.KEEP in p)
        assertTrue("这身衣服的样子" !in Wardrobe.prompt(item.copy(desc = ""), OutfitSkirt.NORMAL))
        val b = Wardrobe.bounds(Mask8(ByteArray(160 * 160) { if (it % 160 in 40..79 && it / 160 in 16..143) -1 else 0 }, 160, 160))!!
        assertEquals(0.25f, b[0], 1e-5f); assertEquals(0.1f, b[1], 1e-5f); assertEquals(0.5f, b[2], 1e-5f); assertEquals(0.9f, b[3], 1e-5f)
    }

    @Test fun hair() {
        assertEquals(50, AIPresetGroup.HAIR_STYLE.presets.size)
        assertEquals(50, AIPresetGroup.HAIR_STYLE.presets.map { it.title }.toSet().size)
        assertTrue(AIPresetGroup.HAIR_STYLE.presets.all { it.hairCrop })
        // 脸在中间偏上：往下到膝盖上面、两边留出飘开的头发
        val b = OutfitMask.hairBox(0.46f, 0.2f, 0.54f, 0.28f, 3000f, 2000f)!!
        assertEquals(0.2f - 0.12f * 1.6f, b[1], 1e-4f)
        assertEquals(1f, b[3], 1e-4f)
        assertTrue(b[0] < 0.3f && b[2] > 0.7f)
        // 脸很大：几乎整张，不裁
        assertNull(OutfitMask.hairBox(0.3f, 0.2f, 0.7f, 0.6f, 2000f, 3000f))
        // 额头不贴：范围明显变小，不到眉毛上面
        val jaw = listOf(V2(0.3f, 0.5f), V2(0.35f, 0.65f), V2(0.5f, 0.75f), V2(0.65f, 0.65f), V2(0.7f, 0.5f))
        val eyes = listOf(V2(0.42f, 0.5f), V2(0.58f, 0.5f))
        val brows = listOf(V2(0.4f, 0.45f), V2(0.6f, 0.45f))
        val lips = listOf(V2(0.45f, 0.66f), V2(0.55f, 0.66f))
        val full = FaceKeep.outline(jaw, eyes, brows, lips)!!
        val low = FaceKeep.outline(jaw, eyes, brows, lips, forehead = false)!!
        assertTrue(low.minOf { it.y } > full.minOf { it.y } + 0.03f)
        assertTrue(low.maxOf { it.x } < full.maxOf { it.x } - 0.01f)
        assertTrue("不能留下轮廓、残影" in AIIntent.HAND_PROMPT)
    }
}
