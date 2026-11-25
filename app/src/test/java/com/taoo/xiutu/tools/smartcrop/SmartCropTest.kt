package com.taoo.xiutu.tools.smartcrop

import com.taoo.xiutu.tools.crop.CropRect
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SmartCropTest {
    @Test fun plainJson() {
        val list = SmartCrop.parse("""{"crops":[{"title":"光与柱","how":"引导线","why":"好","box":[120,180,560,820]}]}""", 0.08f)
        assertEquals(1, list.size)
        assertEquals("光与柱", list[0].title)
        assertEquals(0.12f, list[0].rect.x, 1e-5f)
        assertEquals(0.64f, list[0].rect.h, 1e-5f)
    }

    /** 夹着思考过程和代码块；重复的、太小的、几乎整张的不要。 */
    @Test fun wrapped() {
        val text = "<think>先看看 {画面}</think>\n```json\n" + """{"crops":[
            {"title":"方形","how":"对称","why":"左右平衡","box":[200,200,800,800]},
            {"title":"重复的框","box":[205,205,800,800]},
            {"title":"太小","box":[0,0,20,20]},
            {"title":"整张","box":[0,0,1000,1000]},
            {"title":"一个名字特别特别长的取景","box":["40","60",520,470]},
            {"title":"","box":[560,900,300,40]}]}""" + "\n```\n好了"
        val list = SmartCrop.parse(text, 0.08f)
        assertEquals(listOf("方形", "一个名字特别特别", "取景 3"), list.map { it.title })
        // 左右、上下写反了也能读
        assertEquals(0.3f, list[2].rect.x, 1e-5f)
        assertEquals(0.86f, list[2].rect.h, 1e-4f)
    }

    @Test fun otherShapes() {
        // 0~1 的小数
        assertEquals(0.25f, SmartCrop.parse("""[{"title":"a","box":[0.25,0.1,0.75,0.9]}]""", 0.08f)[0].rect.x, 1e-5f)
        // Gemini 的 box_2d：上、左、下、右
        val g = SmartCrop.parse("""{"list":[{"title":"a","box_2d":[100,200,600,900]}]}""", 0.08f)[0].rect
        assertEquals(0.2f, g.x, 1e-5f)
        assertEquals(0.1f, g.y, 1e-5f)
        assertEquals(0.7f, g.w, 1e-4f)
        assertTrue(SmartCrop.parse("看不清这张照片", 0.08f).isEmpty())
        assertTrue(SmartCrop.parse("{\"crops\":[]}", 0.08f).isEmpty())
    }

    @Test fun fitRatio() {
        val r = SmartCrop.fit(CropRect(0.1f, 0.2f, 0.4f, 0.4f), 1.5f, 3000f, 4000f)
        assertEquals(1.5f, r.w * 3000 / (r.h * 4000), 1e-3f)
        assertEquals(0.16f, r.w * r.h, 1e-3f)
        // 放不下时整体缩小，并且不出照片
        val wide = SmartCrop.fit(CropRect(0.7f, 0.0f, 0.3f, 1f), 16f / 9, 3000f, 4000f)
        assertTrue(wide.x >= 0 && wide.maxX <= 1.0001f && wide.y >= 0 && wide.maxY <= 1.0001f)
        assertEquals(16f / 9, wide.w * 3000 / (wide.h * 4000), 1e-3f)
        assertEquals(CropRect(0.1f, 0.2f, 0.4f, 0.4f), SmartCrop.fit(CropRect(0.1f, 0.2f, 0.4f, 0.4f), null, 3000f, 4000f))
    }

    @Test fun prompt() {
        val p = SmartCrop.prompt(6000, 4000, 0.2f, again = true)
        assertTrue(p.startsWith("你是资深图片编辑"))
        assertTrue("不小于 200（" in p)
        assertTrue("不一定是最大的。\n这是第二次找" in p)
        assertEquals(10, p.lines().size)
        assertTrue(p.lines().none { it.startsWith(" ") })
    }
}
