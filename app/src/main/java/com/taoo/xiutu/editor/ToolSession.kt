package com.taoo.xiutu.editor

import android.graphics.PointF
import android.graphics.RectF
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/**
 * 一个打开着的工具。每个工具一个子类，自己管自己的状态（用 mutableStateOf）、面板和画布交互。
 * EditorModel 负责历史、撤销、预览底图和保存；工具只负责"现在改成什么样"。
 *
 * 生命周期：EditorModel.begin 创建 → start() → 用户操作 → commitOps() 或 cancel → close()。
 */
abstract class ToolSession(val model: EditorModel, val tool: Tool) {
    /** 刚打开时调用（底图已经就绪：model.base）。 */
    open fun start() {}

    /** 确认时要加入历史的步骤；空列表 = 什么都没改。 */
    abstract fun commitOps(): List<EditOp>

    /**
     * 确认时把整串历史换成这一串（图层工具原地修改历史中间的那一步时用）。
     * null = 照常把 commitOps() 追加到历史后面。
     */
    open fun replacementOps(): List<EditOp>? = null

    /** 这次先从历史末尾拿下来的滤镜和调色（AI 修图）：确认时排在新步骤后面，盖回最上面。 */
    open val liftedColor: List<EditOp> get() = emptyList()

    /** 还在处理中（比如 AI 正在生成）：这时点确认不生效。 */
    open val busy: Boolean get() = false

    /** 关闭（确认或取消之后都会调）：停掉后台任务。 */
    open fun close() {}

    /** 历史里的这一步被重新打开接着改（op.reopens(tool) 为 true 的那一步）。 */
    open fun reopen(op: EditOp) {}

    /** 文字 / 贴纸：历史里所有同类步骤合并后交给这里。selecting = 点画面时点中的那一项。 */
    open fun reopenMerged(ops: List<EditOp>, selecting: String?) {}

    /** 重新打开之后什么都没改：确认时原样保留，不记撤销。 */
    open fun unchangedSinceReopen(): Boolean = false

    // 画布交互。坐标是归一化图片坐标（原点左上）；displayScale = 图片长边在屏幕上占多少像素。

    /** true = 单指在画布上是画笔（双指仍然缩放）。 */
    open val drawing: Boolean get() = false
    open fun strokeBegan(p: PointF, displayScale: Float) {}
    open fun strokeMoved(p: PointF) {}
    open fun strokeEnded() {}
    open fun strokeCancelled() {}

    /** 单击画面。 */
    open val wantsTap: Boolean get() = false
    open fun onTap(p: PointF) {}

    /** 画布要放大到的区域（归一化坐标）；null = 整张。 */
    open val focusRect: RectF? get() = null

    /** true = 用自己的画布（Canvas()），不用默认的缩放画布。 */
    open val customCanvas: Boolean get() = false

    @Composable
    open fun Canvas(modifier: Modifier) { Box(modifier) }

    /** 底部面板。 */
    @Composable
    abstract fun Panel()

    /** 底部确认栏中间的标题。 */
    @Composable
    open fun Title() {
        Text(tool.title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** AI 修图工具对外的入口，别的工具（调色、滤镜）跳转到 AI 时用。由 AI 模块实现。 */
interface AiToolApi {
    /** 设好分组和指令；preset 不为空时套用它的附带选项；run = 直接开始生成。 */
    fun setup(group: com.taoo.xiutu.ai.AIPresetGroup, prompt: String, preset: com.taoo.xiutu.ai.AIPreset?, run: Boolean)
}
