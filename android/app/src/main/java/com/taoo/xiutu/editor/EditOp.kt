package com.taoo.xiutu.editor

import android.graphics.Bitmap
import android.graphics.PointF

/** 编辑器里的各个工具。 */
enum class Tool(val title: String, val symbol: String) {
    CROP("裁剪", "crop.rotate"),
    FILTER("滤镜", "camera.filters"),
    ADJUST("调色", "slider.horizontal.3"),
    MOSAIC("马赛克", "checkerboard.rectangle"),
    TEXT("文字", "t.square"),
    STICKER("贴纸", "face.smiling"),
    AI("AI 修图", "sparkles"),
    BEAUTY("美颜", "face.smiling"),
    LIQUIFY("美体", "hand.draw"),
    DOODLE("涂鸦", "scribble.variable"),
    MARK("标记", "arrow.up.right"),
    FRAME("边框", "photo.artframe"),
    BACKDROP("背景", "photo.on.rectangle"),
    COLLAGE("拼图", "rectangle.split.2x2"),
    LAYERS("图层", "square.3.layers.3d"),
    RESHAPE("面部重塑", "face.dashed"),
    MAKEUP("美妆", "paintbrush.pointed"),
    SKIN("皮肤", "sparkle"),
    SHAPE("塑形", "figure.arms.open"),
    EFFECT("特效", "sparkles.rectangle.stack"),
    GRAPHIC("形状", "square.on.circle"),
    BODY_TONE("身体提亮", "sun.max"),
    SMART_CROP("智能构图", "viewfinder"),
    RETOUCH("手动消除", "bandage"),
}

/**
 * 一步已确认的编辑。参数都和分辨率无关，预览图和原图走同一套操作。
 * apply 在后台线程调用，不能改动输入图，返回新图（没变化时可以返回原图）。
 */
interface EditOp {
    fun apply(src: Bitmap): Bitmap

    /** 结果里把输入的画面整张画死了（AI 整张重画）：它前面那些步骤再改也透不出来。 */
    val bakesInput: Boolean get() = false

    /** 会改变画布大小、或者把整个画面挪了位置的步骤。 */
    val changesCanvas: Boolean get() = false

    /** 再次进入这个工具时，这一步是不是该被重新打开接着改。 */
    fun reopens(tool: Tool): Boolean = false

    /**
     * 文字 / 贴纸这类：再进工具时把历史里所有同类步骤合并成一步拿出来改。
     * 返回 true 的步骤由 ToolSession.reopenMerged 接手。
     */
    fun mergesOnReopen(tool: Tool): Boolean = false

    /**
     * 没开工具时点了画面：点中了这一步画上去的东西就返回要打开的工具。
     * point 是归一化坐标（原点左上），ratio = 图高 / 图宽。
     */
    fun hitTest(point: PointF, ratio: Float): Tool? = null

    /** 浮在照片上面的装饰（文字、贴纸、形状、图层）：AI 只处理下面的照片，它们一直留在最上面。 */
    val floats: Boolean get() = false

    /** 滤镜、整张调色：AI 改内容时先拿下来，出结果后再盖回最上面。 */
    val colors: Boolean get() = false

    /** 美颜、美妆、美体这些：和滤镜换先后差别很小，找滤镜时可以越过它们。 */
    val skipsColor: Boolean get() = false

    companion object {
        /**
         * AI 改内容时，把历史末尾的滤镜和整张调色先拿下来：AI 只看没调色的照片，出来以后再盖回最上面，
         * 不然颜色会被 AI 重新算一遍，滤镜就没了。
         * first = 发给 AI 的步骤，second = 拿下来的滤镜和调色。
         */
        fun splitColor(ops: List<EditOp>): Pair<List<EditOp>, List<EditOp>> {
            val base = ArrayList<EditOp>()
            val color = ArrayList<EditOp>()
            var open = true
            for (op in ops.asReversed()) {
                when {
                    !open -> base.add(0, op)
                    op.colors -> color.add(0, op)
                    op.skipsColor -> base.add(0, op)
                    else -> { open = false; base.add(0, op) }
                }
            }
            return base to color
        }

        fun applyAll(ops: List<EditOp>, src: Bitmap): Bitmap = ops.fold(src) { img, op -> op.apply(img) }

        /**
         * 把历史末尾那些浮在照片上的装饰挑出来（它们后面没有改画布的步骤，挪到最后不会变位置）。
         * first = 照片本身的步骤，second = 可以一直浮在最上面的装饰。
         */
        fun splitFloating(ops: List<EditOp>): Pair<List<EditOp>, List<EditOp>> {
            val photo = ArrayList<EditOp>()
            val floating = ArrayList<EditOp>()
            var movable = true
            for (op in ops.asReversed()) {
                if (movable && op.floats) {
                    floating.add(0, op)
                } else {
                    if (op.changesCanvas) movable = false
                    photo.add(0, op)
                }
            }
            return photo to floating
        }
    }
}
