package com.taoo.xiutu.ai

import android.graphics.Bitmap
import com.taoo.xiutu.ml.FaceDetector
import com.taoo.xiutu.tools.shape.ShapeBodyDetector

/**
 * 大师风格的"大师构图"：除了色彩影调，再按这位摄影师惯用的取景方式重新构图。
 * 只描述手法，不写名字（名字会带来和画面无关的联想，容易被审核误判）。照搬 iOS MasterCompose.swift。
 */
object MasterCompose {
    /** 大师指令里"构图保持原样"的那句尾巴。 */
    const val KEEP_TAIL = "只调整光线、色彩、反差和影调；画面内容、人物长相、姿势、服装和构图都保持原样，结果仍是一张真实的照片。"

    /** 像真照片的要求：AI 整张重画时最容易磨皮、涂抹、到处加光斑。 */
    const val REAL_TAIL = "画质要求：真实镜头拍出来的样子。皮肤保留毛孔、细纹和自然的颜色不均，头发是一根根真实的发丝，布料有织纹；" +
        "不磨皮、不涂抹，不要绘画感和塑料感，不要发光的边缘、柔光滤镜或到处的光斑，焦外按真实镜头自然虚化。画面里不要画出网格、辅助线或取景框。"

    /** 换成"按大师的构图重新取景"。frame 是选的哪一种取景。找不到这位大师或指令不是标准格式时返回 null。 */
    fun prompt(base: String, title: String, frame: String? = null, hasPerson: Boolean): String? {
        if (!base.contains(KEEP_TAIL)) return null
        val master = MasterCatalog.byTitle[title] ?: return null
        val f = master.frames.firstOrNull { it.title == frame } ?: master.frames.firstOrNull() ?: return null
        val tail = if (hasPerson) {
            "构图按这个取景重新拍：${f.person}。这是同一个人、同一个地方、同一时刻，像同一台相机退后、靠近或换了个角度又按了一次快门。" +
                "人物长相、五官比例、表情、发型、身材、服装和姿势都不变，脸的朝向不变；原照片里没拍到的部分（更宽的环境、身体的其余部分）按原场景合理延续。" +
                "只能用原照片里已经有的东西：不要凭空加窗框、门框、柱子、墙、栏杆、前景遮挡、灯、花瓣或别的人。"
        } else {
            "构图按这个取景重新拍：${f.scene}。必须还是同一个地方、同一时刻，陈设和物件都来自原场景，缺的部分按原场景合理延续。" +
                "原照片里没有人，结果里也不能出现任何人、人影或人体的一部分——上面说到的人像、肤色只是在讲影调，不要因此加人；" +
                "也不要凭空加窗框、门框、柱子、前景遮挡、灯或别的东西。"
        }
        return base.replace(KEEP_TAIL, tail + REAL_TAIL + "画面比例不变，结果是一张真实的照片。")
    }

    /** 照片里有没有人：认出人脸或者人体姿态都算有。 */
    fun hasPerson(image: Bitmap): Boolean =
        runCatching { FaceDetector.detect(image).isNotEmpty() }.getOrDefault(false) ||
            runCatching { ShapeBodyDetector.detect(image).isNotEmpty() }.getOrDefault(false)
}
