package com.clipspark.app.editor

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
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
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.PlayerView
import com.clipspark.app.designsystem.*
import kotlinx.coroutines.delay
import java.io.File

/** Editor screen: Media3 canvas → state strip → timeline → tool dock → drawers. */

data class ExportUi(
    val running: Boolean = true,
    val progress: Float = 0f,
    val donePath: String? = null,
    val error: String? = null,
)

@Composable
fun EditorScreen(
    model: EditorViewModel,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val playback = remember { PlaybackController(context) }
    val exporter = remember { ExportController(context) }
    var exportState by remember { mutableStateOf<ExportUi?>(null) }
    var isPlayingState by remember { mutableStateOf(false) }
    var drawer by remember { mutableStateOf<EditorDrawer?>(null) }

    DisposableEffect(Unit) { onDispose { playback.release() } }

    // Rebuild the preview playlist whenever the clip list changes.
    LaunchedEffect(model.clips) {
        if (model.clips.isNotEmpty()) playback.setClips(model.clips)
    }
    // Poll playhead position (~12 Hz).
    LaunchedEffect(playback) {
        while (true) {
            model.updateTimecode(playback.currentTimecodeMs())
            isPlayingState = playback.isPlaying
            delay(80)
        }
    }
    // Poll export progress while running.
    LaunchedEffect(exportState?.running) {
        while (exportState?.running == true) {
            exportState = exportState?.copy(progress = exporter.pollProgress())
            delay(250)
        }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(CS.BG)
    ) {
        // 1. Preview canvas (Media3 PlayerView, no controls — custom UI)
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .background(Color.Black)
                .clickable { if (playback.isPlaying) playback.pause() else playback.play() }
        ) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        player = playback.player
                    }
                },
                modifier = Modifier.fillMaxSize()
            )
            if (!isPlayingState) {
                Icon(
                    CSIcons.Play, "Play",
                    tint = Color.White.copy(alpha = 0.9f),
                    modifier = Modifier
                        .align(Alignment.Center)
                        .size(48.dp)
                )
            }
        }

        // 2. State strip
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("‹", color = CS.TextPrimary, fontSize = 22.sp,
                modifier = Modifier.clickable { onBack() })
            Spacer(Modifier.width(12.dp))
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
            Icon(CSIcons.Export, "Export", tint = CS.Accent,
                modifier = Modifier.clickable {
                    if (exportState == null) startExport(context, model, exporter) { exportState = it }
                })
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
            CSToolChip(CSIcons.Edit, "Edit") {
                model.selectedClipId ?: model.clips.firstOrNull()?.id?.let(model::select)
                drawer = EditorDrawer.INSPECTOR
            }
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
            EditorDrawer.STICKER -> StickerDrawer(model) { drawer = null }
            null -> {}
        }
    }

    // Export overlay
    exportState?.let { ui ->
        Box(
            Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.6f))
                .clickable(enabled = false) {}
        ) {
            Column(
                Modifier
                    .align(Alignment.Center)
                    .background(CS.Surface, RoundedCornerShape(16.dp))
                    .padding(24.dp)
                    .width(280.dp)
            ) {
                when {
                    ui.running -> {
                        Text("Exporting… ${(ui.progress * 100).toInt()}%",
                            color = CS.TextPrimary, fontSize = 15.sp)
                        Spacer(Modifier.height(12.dp))
                        LinearProgressIndicator(
                            progress = { ui.progress },
                            modifier = Modifier.fillMaxWidth(),
                            color = CS.Accent,
                        )
                        Spacer(Modifier.height(12.dp))
                        Text("Cancel", color = CS.TextSecondary, fontSize = 13.sp,
                            modifier = Modifier.clickable {
                                exporter.cancel()
                                exportState = null
                            })
                    }
                    ui.donePath != null -> {
                        Text("Saved ✅", color = CS.Success, fontSize = 17.sp)
                        Spacer(Modifier.height(8.dp))
                        Text("In Movies/ClipSpark on your phone. You can open it with any player.",
                            color = CS.TextSecondary, fontSize = 12.sp)
                        Spacer(Modifier.height(12.dp))
                        Text("Close", color = CS.Accent, fontSize = 14.sp,
                            modifier = Modifier.clickable { exportState = null })
                    }
                    else -> {
                        Text("Export failed", color = CS.Danger, fontSize = 17.sp)
                        Spacer(Modifier.height(8.dp))
                        Text(ui.error ?: "Unknown error", color = CS.TextSecondary, fontSize = 12.sp)
                        Spacer(Modifier.height(12.dp))
                        Text("Close", color = CS.Accent, fontSize = 14.sp,
                            modifier = Modifier.clickable { exportState = null })
                    }
                }
            }
        }
    }
}

private fun startExport(
    context: Context,
    model: EditorViewModel,
    exporter: ExportController,
    setState: (ExportUi?) -> Unit,
) {
    val dir = context.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: context.filesDir
    val out = File(dir, "ClipSpark-${System.currentTimeMillis()}.mp4")
    setState(ExportUi())
    exporter.export(
        model.clips, out,
        onProgress = {},
        onDone = { file, err ->
            if (file != null) {
                saveToGallery(context, file)
                setState(ExportUi(running = false, donePath = file.path))
            } else {
                setState(ExportUi(running = false, error = err))
            }
        }
    )
}

/** Registers the finished MP4 with MediaStore so it shows in Gallery apps. */
private fun saveToGallery(context: Context, file: File) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
    try {
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "Movies/ClipSpark")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values) ?: return
        resolver.openOutputStream(uri)?.use { os ->
            file.inputStream().use { it.copyTo(os) }
        }
        values.clear()
        values.put(MediaStore.Video.Media.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    } catch (e: Exception) {
        // Non-fatal: the file still exists in the app's Movies directory.
    }
}
