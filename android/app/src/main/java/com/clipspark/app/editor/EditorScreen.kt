package com.clipspark.app.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipspark.app.designsystem.*

/** Editor screen: canvas (Media3 PlayerView) → state strip → timeline → tool dock. */

@Composable
fun EditorScreen(
    model: EditorViewModel,
    onBack: () -> Unit,
    onExport: () -> Unit,
) {
    var drawer by remember { mutableStateOf<EditorDrawer?>(null) }

    Column(
        Modifier
            .fillMaxSize()
            .background(CS.BG)
    ) {
        // 1. Preview canvas — PlayerView host is attached by the Activity
        //    (AndroidView); skeleton reserves the space here.
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .background(Color.Black)
                .clickable { /* toggle play */ }
        )

        // 2. State strip
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(CSIcons.Undo, null, tint = if (model.canUndo) CS.TextPrimary else CS.TextSecondary,
                modifier = Modifier.clickable { model.undo() })
            Spacer(8.dp)
            Icon(CSIcons.Redo, null, tint = if (model.canRedo) CS.TextPrimary else CS.TextSecondary,
                modifier = Modifier.clickable { model.redo() })
            Spacer(16.dp)
            Icon(CSIcons.Split, "Split at playhead", tint = CS.TextPrimary,
                modifier = Modifier.clickable { model.splitAt(model.timecodeMs) })
            Spacer(Modifier.weight(1f))
            Text("${model.timecodeText()} / ${model.timecodeText(model.totalMs())}",
                color = CS.Accent, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Icon(CSIcons.Export, "Export", tint = CS.Accent, modifier = Modifier.clickable { onExport() })
        }

        // 3. Timeline — center-fixed playhead over a scrolling film strip
        TimelineRow(model)

        // 4. Tool dock
        Row(
            Modifier
                .fillMaxWidth()
                .background(CS.Surface)
                .padding(vertical = 8.dp)
                .horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            Spacer(8.dp)
            CSToolChip(CSIcons.Edit, "Edit") { model.selectedClipId ?: model.clips.firstOrNull()?.id?.let(model::select); drawer = EditorDrawer.INSPECTOR }
            CSToolChip(CSIcons.Text, "Text") { drawer = EditorDrawer.TEXT }
            CSToolChip(CSIcons.Sticker, "Sticker") { drawer = EditorDrawer.STICKER }
            CSToolChip(CSIcons.Filter, "Filters") { drawer = EditorDrawer.FILTER }
            CSToolChip(CSIcons.Transitions, "Transitions") { drawer = EditorDrawer.TRANSITIONS }
            CSToolChip(CSIcons.Audio, "Audio") { drawer = EditorDrawer.AUDIO }
            Spacer(8.dp)
        }

        // 5. Drawer layer
        when (drawer) {
            EditorDrawer.INSPECTOR -> ClipInspector(model)
            EditorDrawer.TEXT -> TextDrawer(model) { drawer = null }
            EditorDrawer.FILTER -> FilterDrawer(model) { drawer = null }
            EditorDrawer.TRANSITIONS -> TransitionsDrawer(model) { drawer = null }
            EditorDrawer.AUDIO -> AudioDrawer(model) { drawer = null }
            EditorDrawer.STICKER -> {}
            null -> {}
        }
    }
}

enum class EditorDrawer { INSPECTOR, TEXT, STICKER, FILTER, TRANSITIONS, AUDIO }

@Composable
fun TimelineRow(model: EditorViewModel) {
    BoxWithConstraints(Modifier.fillMaxWidth().background(CS.Surface)) {
        LazyRow(
            Modifier.padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            item { Spacer(Modifier.width(maxWidth / 2)) }
            itemsIndexed(model.clips, key = { _, c -> c.id }) { index, clip ->
                ClipBlock(clip, isSelected = clip.id == model.selectedClipId,
                    showJunction = index > 0 && clip.transitionIn != CSTransition.NONE,
                    onClick = { model.select(if (clip.id == model.selectedClipId) null else clip.id) })
            }
            item { Spacer(Modifier.width(maxWidth / 2)) }
        }
        // Fixed center playhead
        Box(
            Modifier
                .align(Alignment.Center)
                .width(2.dp)
                .fillMaxHeight()
                .background(CS.Accent)
        )
    }
}

@Composable
private fun ClipBlock(
    clip: ClipSegment,
    isSelected: Boolean,
    showJunction: Boolean,
    onClick: () -> Unit,
) {
    val width = (clip.timelineDurationMs / 40f).dp.coerceAtLeast(24.dp)
    Box(
        Modifier
            .width(width)
            .height(56.dp)
            .background(CS.SeedPalette[(clip.id % 3).toInt()].copy(alpha = 0.4f), RoundedCornerShape(7.dp))
            .border(
                2.dp,
                if (isSelected) CS.Selection else CS.Hairline,
                RoundedCornerShape(7.dp)
            )
            .clickable { onClick() }
    ) {
        Text(clip.durationText(), fontSize = 11.sp, color = Color.White,
            modifier = Modifier.align(Alignment.BottomEnd).padding(4.dp))
        if (showJunction) {
            Icon(
                CSIcons.Transitions, clip.transitionIn.label,
                tint = Color.Black,
                modifier = Modifier
                    .align(Alignment.TopStart)
                    .padding(2.dp)
                    .background(CS.Accent, CircleShape)
                    .padding(2.dp)
            )
        }
    }
}
