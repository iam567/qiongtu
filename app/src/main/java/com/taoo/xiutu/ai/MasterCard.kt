package com.taoo.xiutu.ai

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.ui.Chip
import com.taoo.xiutu.ui.CornerBadge
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.press
import com.taoo.xiutu.ui.sym

/** 点了一位大师：先看风格，选取景，点"开始生成"才发给 AI。 */
@Composable
fun MasterCard(
    master: MasterInfo,
    thumb: Bitmap?,
    /** 按大师的取景重新构图；false = 原构图。 */
    compose: Boolean,
    frame: String?,
    onFrame: (String) -> Unit,
    onOriginal: () -> Unit,
    onBack: () -> Unit,
    onStart: () -> Unit,
) {
    Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Top) {
            if (thumb != null) {
                val image = remember(thumb) { thumb.asImageBitmap() }
                Image(
                    image, null, contentScale = ContentScale.Crop,
                    modifier = Modifier.size(68.dp, 84.dp).clip(RoundedCornerShape(10.dp)),
                )
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(master.title, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = Color.White)
                Text(master.note, fontSize = 12.sp, color = Theme.accent)
                StyleLine("色彩", master.color)
                StyleLine("光线", master.light)
                StyleLine("构图", master.compose)
            }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (f in master.frames) {
                Chip(f.title, selected = compose && frame == f.title, symbol = "viewfinder") { onFrame(f.title) }
            }
            Chip("原构图", selected = !compose, symbol = "rectangle", onClick = onOriginal)
        }
        val picked = master.frames.firstOrNull { it.title == frame }
        if (compose && picked != null) Text(picked.person, fontSize = 12.sp, lineHeight = 17.sp, color = Theme.dim)
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(
                Modifier.width(104.dp).height(42.dp).clip(CircleShape).background(Theme.chip).press(onClick = onBack),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(sym("chevron.left"), null, tint = Color.White, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(6.dp))
                Text("换一位", fontSize = 14.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
            }
            AIMainButton("开始生成", Modifier.weight(1f), onClick = onStart)
        }
    }
}

@Composable
private fun StyleLine(name: String, text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.Top) {
        Text(name, fontSize = 12.sp, lineHeight = 17.sp, color = Theme.dim)
        Text(text, fontSize = 12.sp, lineHeight = 17.sp, color = Color.White)
    }
}

/** 橙色的主按钮，带 AI 角标。 */
@Composable
fun AIMainButton(title: String, modifier: Modifier = Modifier, symbol: String? = null, enabled: Boolean = true, onClick: () -> Unit) {
    Box(modifier) {
        Row(
            Modifier.fillMaxWidth().height(42.dp).clip(CircleShape)
                .background(if (enabled) Theme.accent else Theme.accent.copy(alpha = 0.35f)).press(enabled, onClick),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
        ) {
            if (symbol != null) {
                Icon(sym(symbol), null, tint = Color.Black, modifier = Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
            }
            Text(title, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = Color.Black, maxLines = 1)
        }
        CornerBadge("AI", Modifier.align(Alignment.TopEnd).offset(x = (-6).dp, y = (-5).dp))
    }
}
