package com.taoo.xiutu.editor

import com.taoo.xiutu.ai.AISession
import com.taoo.xiutu.tools.adjust.AdjustSession
import com.taoo.xiutu.tools.beauty.BeautySession
import com.taoo.xiutu.tools.bodytone.BodyToneSession
import com.taoo.xiutu.tools.collage.CollageSession
import com.taoo.xiutu.tools.effect.EffectSession
import com.taoo.xiutu.tools.crop.CropSession
import com.taoo.xiutu.tools.doodle.DoodleSession
import com.taoo.xiutu.tools.filter.FilterSession
import com.taoo.xiutu.tools.frame.FrameSession
import com.taoo.xiutu.tools.layers.LayerSession
import com.taoo.xiutu.tools.makeup.MakeupSession
import com.taoo.xiutu.tools.mosaic.MosaicSession
import com.taoo.xiutu.tools.overlay.OverlaySession
import com.taoo.xiutu.tools.reshape.ReshapeSession
import com.taoo.xiutu.tools.retouch.RetouchSession
import com.taoo.xiutu.tools.shape.LiquifySession
import com.taoo.xiutu.tools.shape.ShapeSession
import com.taoo.xiutu.tools.skin.SkinSession
import com.taoo.xiutu.tools.smartcrop.SmartCropSession

/** 工具 → 会话。 */
object ToolRegistry {
    fun create(t: Tool, model: EditorModel): ToolSession? = when (t) {
        Tool.CROP -> CropSession(model)
        Tool.ADJUST -> AdjustSession(model)
        Tool.FILTER -> FilterSession(model)
        Tool.MOSAIC -> MosaicSession(model)
        Tool.TEXT, Tool.STICKER, Tool.GRAPHIC -> OverlaySession(model, t)
        Tool.AI -> AISession(model)
        Tool.BEAUTY -> BeautySession(model)
        Tool.MAKEUP -> MakeupSession(model)
        Tool.SKIN -> SkinSession(model)
        Tool.RESHAPE -> ReshapeSession(model)
        Tool.SHAPE -> ShapeSession(model)
        Tool.LIQUIFY -> LiquifySession(model)
        Tool.LAYERS -> LayerSession(model)
        Tool.COLLAGE -> CollageSession(model)
        Tool.DOODLE, Tool.MARK -> DoodleSession(model, t)
        Tool.FRAME, Tool.BACKDROP -> FrameSession(model, t)
        Tool.EFFECT -> EffectSession(model)
        Tool.BODY_TONE -> BodyToneSession(model)
        Tool.SMART_CROP -> SmartCropSession(model)
        Tool.RETOUCH -> RetouchSession(model)
    }

    fun available(t: Tool) = true
}
