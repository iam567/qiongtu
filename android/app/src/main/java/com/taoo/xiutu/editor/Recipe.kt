package com.taoo.xiutu.editor

import android.graphics.Bitmap
import com.taoo.xiutu.ai.AIEdit
import com.taoo.xiutu.ai.AIPresetGroup
import com.taoo.xiutu.ai.AIReframe
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.tools.adjust.AdjustKey
import com.taoo.xiutu.tools.adjust.AdjustOp
import com.taoo.xiutu.tools.adjust.AdjustParams
import com.taoo.xiutu.tools.beauty.BeautyParams
import com.taoo.xiutu.tools.bodytone.BodyToneOp
import com.taoo.xiutu.tools.collage.CollageOp
import com.taoo.xiutu.tools.crop.CropOp
import com.taoo.xiutu.tools.crop.CropParams
import com.taoo.xiutu.tools.crop.CropRect
import com.taoo.xiutu.tools.doodle.DoodleOp
import com.taoo.xiutu.tools.effect.EffectOp
import com.taoo.xiutu.tools.effect.EffectParams
import com.taoo.xiutu.tools.filter.FilmLook
import com.taoo.xiutu.tools.filter.InstantOp
import com.taoo.xiutu.tools.filter.InstantParams
import com.taoo.xiutu.tools.filter.LookOp
import com.taoo.xiutu.tools.frame.BackdropOp
import com.taoo.xiutu.tools.frame.BackdropParams
import com.taoo.xiutu.tools.frame.FrameOp
import com.taoo.xiutu.tools.frame.FrameParams
import com.taoo.xiutu.tools.layers.LayerStack
import com.taoo.xiutu.tools.makeup.MakeupParams
import com.taoo.xiutu.tools.mosaic.MosaicOp
import com.taoo.xiutu.tools.overlay.OverlayOp
import com.taoo.xiutu.tools.reshape.ReshapeParams
import com.taoo.xiutu.tools.retouch.RetouchOp
import com.taoo.xiutu.tools.shape.LiquifyOp
import com.taoo.xiutu.tools.shape.ShapeOp
import com.taoo.xiutu.tools.skin.SkinOp
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.roundToInt
import kotlin.math.sqrt

/** AI 修图一步是怎么发起的：套到新照片上时按这个再跑一遍（结果会和原来不一样，费用也会再算一次）。 */
@Serializable
data class AIRecipe(
    /** AIPresetGroup 的名字。 */
    val group: String,
    /** 用户看到的那条指令（不含"再生成一次"加的变化要求）。 */
    val prompt: String,
    val presetTitle: String = "",
    val masterCompose: Boolean = false,
    val faceCrop: Boolean = false,
    val hairCrop: Boolean = false,
    /** AIReframe 的名字。 */
    val reframe: String = AIReframe.ORIGINAL.name,
    val strength: Float = 1f,
    val toneOnly: Boolean = false,
    val soften: Float = 0f,
    /** 贴回原图的脸。 */
    val keepFace: Boolean? = null,
    /** 只在变了的地方用 AI 的像素。 */
    val changedOnly: Boolean? = null,
)

/** 能套到新照片上的一步。 */
@Serializable
sealed interface RecipeAction {
    @Serializable @SerialName("adjust")
    data class Adjust(val params: AdjustParams) : RecipeAction

    @Serializable @SerialName("look")
    data class Look(val id: String, val intensity: Float) : RecipeAction

    /** aspect = 裁出来的宽高比（像素），area = 裁出来的部分占原图面积的比例。 */
    @Serializable @SerialName("crop")
    data class Crop(val params: CropParams, val aspect: Float, val area: Float) : RecipeAction

    @Serializable @SerialName("frame")
    data class Frame(val params: FrameParams) : RecipeAction

    @Serializable @SerialName("backdrop")
    data class Backdrop(val params: BackdropParams) : RecipeAction

    @Serializable @SerialName("instant")
    data class Instant(val params: InstantParams) : RecipeAction

    @Serializable @SerialName("effect")
    data class Effect(val params: EffectParams) : RecipeAction

    @Serializable @SerialName("ai")
    data class AI(val recipe: AIRecipe) : RecipeAction
}

/** 处理过程里的一步：名字、一句细节；action 为空 = 这一步和原图的位置绑在一起（涂抹、文字、涂鸦……），套用时跳过。 */
@Serializable
data class RecipeStep(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val detail: String = "",
    val symbol: String,
    val action: RecipeAction? = null,
)

/** 一张图从原图到成品的全部步骤。 */
@Serializable
data class EditRecipe(val steps: List<RecipeStep>) {
    val copyable: Int get() = steps.count { it.action != null }

    fun encode(): String = json.encodeToString(this)

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        fun decode(text: String): EditRecipe? = runCatching { json.decodeFromString<EditRecipe>(text) }.getOrNull()

        /** 从编辑历史整理出步骤（在后台线程调用）。input 是原图，算裁剪比例用；出错时返回 null。 */
        fun from(ops: List<EditOp>, input: Bitmap): EditRecipe? = runCatching {
            // 裁剪只要知道当时画面的宽高比：用一张小图把会改画布大小的步骤跑一遍就够了。
            var img: Bitmap? = if (ops.any { it is CropOp }) Img.downscale(input, 800) else null
            val steps = ArrayList<RecipeStep>()
            for (op in ops) {
                val size = img?.let { it.width to it.height } ?: (input.width to input.height)
                steps += step(op, size)
                val cur = img
                if (cur != null && op.changesCanvas) img = runCatching { op.apply(cur) }.getOrNull()
            }
            EditRecipe(steps)
        }.getOrNull()

        private fun percent(v: Float) = "${(v * 100).roundToInt()}"

        private fun skipped(title: String, symbol: String) = RecipeStep(title = title, symbol = symbol)

        private fun step(op: EditOp, inputSize: Pair<Int, Int>): RecipeStep = when (op) {
            is AdjustOp -> {
                val p = op.params
                val parts = ArrayList<String>()
                for (key in AdjustKey.entries) {
                    if (p[key] == 0f) continue
                    val v = (p[key] * 100).roundToInt()
                    parts += "${key.title} ${if (v > 0) "+" else ""}$v"
                }
                if (p.hslChanged) parts += "HSL"
                if (!p.curves.isIdentity) parts += "曲线"
                if (!p.split.isIdentity) parts += "色调分离"
                if (p.localChanged) parts += "局部调色"
                RecipeStep(title = "调色", detail = parts.joinToString("、"), symbol = "slider.horizontal.3", action = RecipeAction.Adjust(p))
            }
            is LookOp -> {
                val name = FilmLook.byID[op.id]?.name ?: "滤镜"
                RecipeStep(title = "滤镜", detail = "$name ${percent(op.intensity)}", symbol = "camera.filters",
                    action = RecipeAction.Look(op.id, op.intensity))
            }
            is CropOp -> {
                val p = op.params
                var (w, h) = inputSize
                if (((p.quarterTurns % 4) + 4) % 2 == 1) { val t = w; w = h; h = t }
                val cw = p.rect.w * w
                val ch = p.rect.h * h
                val aspect = if (ch > 0) cw / ch else 1f
                val parts = ArrayList<String>()
                if (p.quarterTurns != 0) parts += "旋转 ${p.quarterTurns * 90}°"
                if (p.flip) parts += "翻转"
                if (abs(p.straighten) > 0.05f) parts += "拉直 %.1f°".format(p.straighten)
                if (p.rect != CropRect()) parts += "裁成 %.2f:1".format(aspect)
                RecipeStep(title = "裁剪", detail = parts.joinToString("、"), symbol = "crop",
                    action = RecipeAction.Crop(p, aspect, p.rect.w * p.rect.h))
            }
            is FrameOp -> RecipeStep(title = "边框", symbol = Tool.FRAME.symbol, action = RecipeAction.Frame(op.params))
            is BackdropOp -> RecipeStep(title = "背景", detail = op.params.ratio.title, symbol = Tool.BACKDROP.symbol,
                action = RecipeAction.Backdrop(op.params))
            is InstantOp -> RecipeStep(title = "拍立得", detail = op.params.stock.title, symbol = "photo",
                action = RecipeAction.Instant(op.params))
            is EffectOp -> {
                val name = op.params.kind?.title ?: "特效"
                RecipeStep(title = "特效", detail = "$name ${percent(op.params.strength)}", symbol = Tool.EFFECT.symbol,
                    action = RecipeAction.Effect(op.params))
            }
            is AIEdit -> {
                val r = op.recipe
                val group = r?.let { x -> AIPresetGroup.entries.firstOrNull { it.name == x.group } }
                if (r == null || group == null) {
                    RecipeStep(title = "AI", detail = "涂抹或融合的结果", symbol = "sparkles")
                } else {
                    var detail = r.presetTitle.ifEmpty { r.prompt.take(18) }
                    if (group == AIPresetGroup.MASTER && r.masterCompose) detail += " · 大师构图"
                    RecipeStep(title = "AI ${group.title}", detail = detail, symbol = "sparkles", action = RecipeAction.AI(r))
                }
            }
            is MosaicOp -> skipped("马赛克", "checkerboard.rectangle")
            is OverlayOp -> skipped("文字 / 贴纸 / 形状", "textformat")
            is DoodleOp -> skipped("涂鸦", "scribble.variable")
            is LiquifyOp -> skipped("推拉", "hand.draw")
            is BeautyParams -> skipped("美颜", "face.smiling")
            is MakeupParams -> skipped("美妆", "paintbrush.pointed")
            is SkinOp -> skipped("皮肤", "drop")
            is ReshapeParams -> skipped("面部重塑", "face.dashed")
            is ShapeOp -> skipped("美体", "figure.stand")
            is RetouchOp -> skipped("手动消除", "bandage")
            is BodyToneOp -> skipped("身体提亮", "sun.max")
            is LayerStack -> skipped("图层", "square.3.layers.3d")
            is CollageOp -> skipped("拼图", "square.grid.2x2")
            else -> skipped("其他", "photo")
        }
    }
}

/** 套到另一张图上：旋转、翻转、拉直照搬；裁剪框保持同样的比例、同样的中心位置、差不多同样占多大，放不下就缩小。 */
fun CropParams.adapted(aspect: Float, area: Float, width: Int, height: Int): CropParams {
    if (aspect <= 0f || area <= 0f || width <= 0 || height <= 0 || rect == CropRect()) return this
    var sw = width.toFloat()
    var sh = height.toFloat()
    if (((quarterTurns % 4) + 4) % 2 == 1) { val t = sw; sw = sh; sh = t }
    // 归一化宽 w、高 h：w * W / (h * H) = aspect，w * h = area。
    var h = sqrt(area * sw / (aspect * sh))
    var w = h * aspect * sh / sw
    val k = max(max(w, h), 1f)
    w /= k
    h /= k
    val cx = rect.x + rect.w / 2
    val cy = rect.y + rect.h / 2
    val x = (cx - w / 2).coerceIn(0f, 1f - w)
    val y = (cy - h / 2).coerceIn(0f, 1f - h)
    return copy(rect = CropRect(x, y, w, h))
}
