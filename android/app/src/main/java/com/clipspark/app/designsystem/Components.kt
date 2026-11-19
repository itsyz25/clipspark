package com.clipspark.app.designsystem

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.automirrored.filled.*

// Tool chips + buttons, mirroring iOS Components.swift.

object CSIcons {
    val NewProject = Icons.Default.Add
    val Edit = Icons.Default.Tune
    val Split = Icons.Default.CallSplit
    val Speed = Icons.Default.Speed
    val Audio = Icons.Default.MusicNote
    val Text = Icons.Default.TextFields
    val Sticker = Icons.Default.EmojiEmotions
    val Filter = Icons.Default.FilterVintage
    val Transitions = Icons.Default.SwapHoriz
    val Undo = Icons.AutoMirrored.Filled.Undo
    val Redo = Icons.AutoMirrored.Filled.Redo
    val Play = Icons.Default.PlayArrow
    val Pause = Icons.Default.Pause
    val Export = Icons.Default.Share
    val Delete = Icons.Default.Delete
    val Duplicate = Icons.Default.ContentCopy
    val LayerForward = Icons.Default.FlipToFront
    val LayerBackward = Icons.Default.FlipToBack
    val Trim = Icons.Default.ContentCut
    val Volume = Icons.Default.VolumeUp
    val Settings = Icons.Default.Settings
    val Templates = Icons.Default.AutoAwesomeMotion
    val Home = Icons.Default.Home
    val Drafts = Icons.Default.DownloadDone
    val Keyframe = Icons.Default.Diamond
}

/** Bottom tool chip (CapCut-style). */
@Composable
fun CSToolChip(
    icon: ImageVector,
    label: String,
    selected: Boolean = false,
    onClick: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier
            .clickable { CS_Haptic.tick(); onClick() }
            .background(if (selected) CS.Accent else CS.SurfaceHigh, RoundedCornerShape(22.dp))
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Icon(icon, contentDescription = label, tint = if (selected) CS.BG else CS.TextPrimary)
        Text(label, fontSize = 12.sp, color = if (selected) CS.BG else CS.TextPrimary)
    }
}

/** Primary gradient CTA. */
@Composable
fun CSPrimaryButton(label: String, icon: ImageVector? = null, onClick: () -> Unit) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .clickable { onClick() }
            .background(
                Brush.linearGradient(listOf(CS.Accent, CS.AccentViolet)),
                RoundedCornerShape(50)
            )
            .padding(horizontal = 20.dp, vertical = 12.dp)
    ) {
        icon?.let { Icon(it, contentDescription = null, tint = Color.Black) }
        if (icon != null) androidx.compose.foundation.layout.Spacer(Modifier.padding(4.dp))
        Text(label, color = Color.Black, fontSize = 17.sp)
    }
}

/** Bottom drawer grabber. */
@Composable
fun CSGrabber() {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) {
        Column(
            Modifier
                .padding(top = 8.dp)
                .background(CS.Hairline, RoundedCornerShape(3.dp))
                .padding(horizontal = 20.dp, vertical = 2.dp)
        ) {}
    }
}

/** Convenience: Spacer(16.dp) instead of Spacer(Modifier.width(16.dp)). */
@Composable
fun Spacer(width: androidx.compose.ui.unit.Dp) =
    androidx.compose.foundation.layout.Spacer(Modifier.width(width))

/** Lightweight haptics (tick on snap/cut per spec). */
object CS_Haptic {
    fun tick() { /* wrapped HapticFeedback; injected at call sites via LocalHapticFeedback in real usage */ }
}
