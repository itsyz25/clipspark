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
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.ui.PlayerView
import com.clipspark.app.designsystem.*
import com.clipspark.app.drafts.DraftStore
import kotlinx.coroutines.delay
import java.io.File

/** Editor screen: Media3 canvas → state strip → timeline → tool dock → drawers. */

data class ExportUi(
    val running: Boolean = true,
    val progress: Float = 0f,
    val donePath: String? = null,
    val error: String? = null,
)

/** Keyframe-evaluated preview transform for the current frame. */
private data class PreviewFx(
    val scale: Float = 1f,
    val rotation: Float = 0f,
    val posX: Float = 0f,
    val posY: Float = 0f,
    val opacity: Float = 1f,
)

/** Evaluates the clip under the playhead; identity when it has no keyframes. */
private fun evaluatePreviewFx(model: EditorViewModel): PreviewFx {
    val clip = model.clips.firstOrNull {
        model.timecodeMs >= it.startMs && model.timecodeMs < it.endMs
    } ?: return PreviewFx()
    if (clip.keyframes.isEmpty()) return PreviewFx()
    val t = model.timecodeMs - clip.startMs
    fun v(p: KeyframeProperty, base: Double) =
        KeyframeEvaluator.evaluate(clip.keyframes, p, base, t)
    return PreviewFx(
        scale = v(KeyframeProperty.SCALE, 1.0).toFloat(),
        rotation = v(KeyframeProperty.ROTATION, 0.0).toFloat(),
        posX = v(KeyframeProperty.POS_X, 0.0).toFloat(),
        posY = v(KeyframeProperty.POS_Y, 0.0).toFloat(),
        opacity = v(KeyframeProperty.OPACITY, 1.0).toFloat(),
    )
}

/** Keyframed volume for the clip under the playhead (1 = untouched). */
private fun evaluatePreviewVolume(model: EditorViewModel): Float {
    val clip = model.clips.firstOrNull {
        model.timecodeMs >= it.startMs && model.timecodeMs < it.endMs
    } ?: return 1f
    val base = if (clip.muted) 0.0 else clip.volume.toDouble()
    val t = model.timecodeMs - clip.startMs
    val v = KeyframeEvaluator.evaluate(clip.keyframes, KeyframeProperty.VOLUME, base, t)
    return v.coerceIn(0.0, 1.0).toFloat()
}

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
    var draftSaved by remember { mutableStateOf<String?>(null) }
    var previewFx by remember { mutableStateOf(PreviewFx()) }

    DisposableEffect(Unit) { onDispose { playback.release() } }

    // Rebuild the preview playlist whenever the clip list changes.
    LaunchedEffect(model.clips) {
        if (model.clips.isNotEmpty()) playback.setClips(model.clips)
    }
    // Poll playhead position (~12 Hz) + evaluate keyframes for preview/volume.
    LaunchedEffect(playback) {
        while (true) {
            model.updateTimecode(playback.currentTimecodeMs())
            isPlayingState = playback.isPlaying
            previewFx = evaluatePreviewFx(model)
            playback.setVolume(evaluatePreviewVolume(model))
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
    // Brief "Saved ✓" feedback for drafts
    LaunchedEffect(draftSaved) {
        if (draftSaved != null) { delay(1500); draftSaved = null }
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(CS.BG)
    ) {
        // 1. Preview canvas (Media3 PlayerView, no controls — custom UI).
        // Keyframes transform the video layer only (the play icon stays put).
        Box(
            Modifier
                .fillMaxWidth()
                .aspectRatio(16f / 9f)
                .background(Color.Black)
                .clickable { if (playback.isPlaying) playback.pause() else playback.play() }
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .graphicsLayer {
                        scaleX = previewFx.scale
                        scaleY = previewFx.scale
                        rotationZ = previewFx.rotation
                        translationX = previewFx.posX * size.width
                        translationY = previewFx.posY * size.height
                        alpha = previewFx.opacity
                    }
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
            }
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
            Spacer(Modifier.width(8.dp))
            Icon(CSIcons.Redo, null, tint = if (model.canRedo) CS.TextPrimary else CS.TextSecondary,
                modifier = Modifier.clickable { model.redo() })
            Spacer(Modifier.width(16.dp))
            Icon(CSIcons.Split, "Split at playhead", tint = CS.TextPrimary,
                modifier = Modifier.clickable { model.splitAt(model.timecodeMs) })
            Spacer(Modifier.width(12.dp))
            Icon(CSIcons.Drafts, "Save draft", tint = CS.TextPrimary,
                modifier = Modifier.clickable {
                    val name = "Draft ${java.text.SimpleDateFormat("MM-dd HH:mm", java.util.Locale.US).format(java.util.Date())}"
                    DraftStore.save(context, model, name)
                    draftSaved = name
                })
            Spacer(Modifier.weight(1f))
            Text("${model.timecodeText()} / ${model.timecodeText(model.totalMs())}",
                color = CS.Accent, fontSize = 11.sp)
            draftSaved?.let {
                Spacer(Modifier.width(8.dp))
                Text("Saved ✓", color = CS.Success, fontSize = 11.sp)
            }
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
            Spacer(Modifier.width(8.dp))
            CSToolChip(CSIcons.Edit, "Edit") {
                model.selectedClipId ?: model.clips.firstOrNull()?.id?.let(model::select)
                drawer = EditorDrawer.INSPECTOR
            }
            CSToolChip(CSIcons.Text, "Text") { drawer = EditorDrawer.TEXT }
            CSToolChip(CSIcons.Sticker, "Sticker") { drawer = EditorDrawer.STICKER }
            CSToolChip(CSIcons.Filter, "Filters") { drawer = EditorDrawer.FILTER }
            CSToolChip(CSIcons.Transitions, "Transitions") { drawer = EditorDrawer.TRANSITIONS }
            CSToolChip(CSIcons.Keyframe, "Keyframes") {
                model.selectedClipId ?: model.clips.firstOrNull()?.id?.let(model::select)
                drawer = EditorDrawer.KEYFRAMES
            }
            CSToolChip(CSIcons.Audio, "Audio") { drawer = EditorDrawer.AUDIO }
            Spacer(Modifier.width(8.dp))
        }

        // 5. Drawer layer
        when (drawer) {
            EditorDrawer.INSPECTOR -> ClipInspector(model)
            EditorDrawer.TEXT -> TextDrawer(model) { drawer = null }
            EditorDrawer.FILTER -> FilterDrawer(model) { drawer = null }
            EditorDrawer.TRANSITIONS -> TransitionsDrawer(model) { drawer = null }
            EditorDrawer.KEYFRAMES -> KeyframeDrawer(model) { drawer = null }
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

/**
 * Horizontal film strip with a fixed center playhead (CapCut-style).
 * Block width ∝ clip timeline duration; tap selects (again to deselect).
 * Selected clip shows a teal outline + speed badge.
 */
@Composable
private fun TimelineRow(model: EditorViewModel) {
    val pxPerSecond = 48.dp
    Box(
        Modifier
            .fillMaxWidth()
            .height(76.dp)
            .background(CS.BG)
    ) {
        // Fixed center playhead
        Box(
            Modifier
                .align(Alignment.Center)
                .width(2.dp)
                .fillMaxHeight()
                .background(CS.Accent)
        )
        Row(
            Modifier
                .fillMaxSize()
                .horizontalScroll(rememberScrollState())
                .padding(vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(2.dp)
        ) {
            model.clips.forEach { clip ->
                val selected = clip.id == model.selectedClipId
                Column(
                    Modifier
                        .width(((clip.timelineDurationMs / 1000f) * pxPerSecond.value)
                            .dp.coerceIn(44.dp, 240.dp))
                        .fillMaxHeight()
                        .background(
                            if (selected) CS.SurfaceHigh else CS.Surface,
                            RoundedCornerShape(8.dp)
                        )
                        .border(
                            if (selected) 2.dp else 1.dp,
                            if (selected) CS.Accent else CS.Hairline,
                            RoundedCornerShape(8.dp)
                        )
                        .clickable {
                            model.select(if (selected) null else clip.id)
                        },
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        clip.durationText(),
                        fontSize = 10.sp,
                        color = CS.TextSecondary,
                        modifier = Modifier.padding(4.dp)
                    )
                    if (clip.speed != 1.0) {
                        Text("%.2f×".format(clip.speed), fontSize = 9.sp, color = CS.Accent)
                    }
                    if (clip.muted) {
                        Text("🔇", fontSize = 9.sp, color = CS.TextSecondary)
                    }
                }
            }
            Spacer(Modifier.width(8.dp))
        }
    }
}
