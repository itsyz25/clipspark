package com.clipspark.app.editor

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
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

/** Editor screen: canvas + overlays → transport → timeline → contextual tools → drawer. */

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

private enum class ContextState { NONE, VIDEO, AUDIO, TEXT, OVERLAY }

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

    DisposableEffect(Unit) {
        onDispose {
            playback.release()
            exporter.cancel()
        }
    }

    fun seekTo(ms: Long) {
        val clamped = ms.coerceIn(0L, model.totalMs().coerceAtLeast(0L))
        playback.seekToTimelineMs(clamped)
        model.updateTimecode(clamped)
    }

    // Rebuild the preview playlist only when the timeline STRUCTURE changes
    // (trim/speed/order/mute/transition). Keyframe and volume edits must not
    // rebuild it, or every drag tick would restart playback.
    val structureKey = model.clips.joinToString("|") {
        "${it.id},${it.uri},${it.sourceInMs},${it.sourceDurationMs}," +
            "${it.speed},${it.muted},${it.transitionIn.name}"
    }
    LaunchedEffect(structureKey) {
        if (model.clips.isNotEmpty()) {
            playback.setClips(model.clips)
            playback.seekToTimelineMs(model.timecodeMs)
        }
    }
    // Preview look + motion blur: the exact same GL effect list the exporter uses.
    LaunchedEffect(model.look) {
        playback.setVideoEffects(buildLookEffects(model.look))
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

    val contextState: ContextState = when {
        drawer == EditorDrawer.AUDIO -> ContextState.AUDIO
        model.selectedOverlay?.text != null -> ContextState.TEXT
        model.selectedOverlay != null -> ContextState.OVERLAY
        model.selectedClipId != null -> ContextState.VIDEO
        else -> ContextState.NONE
    }

    Box(Modifier.fillMaxSize().background(CS.BG)) {
        Column(Modifier.fillMaxSize()) {
            // ── Top bar: back / undo / redo / split / save / timecode / export ──
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("‹", color = CS.TextPrimary, fontSize = 24.sp,
                    modifier = Modifier.clickable { onBack() })
                Spacer(Modifier.width(10.dp))
                Icon(CSIcons.Undo, "Undo",
                    tint = if (model.canUndo) CS.TextPrimary else CS.TextSecondary,
                    modifier = Modifier.clickable { model.undo() })
                Spacer(Modifier.width(10.dp))
                Icon(CSIcons.Redo, "Redo",
                    tint = if (model.canRedo) CS.TextPrimary else CS.TextSecondary,
                    modifier = Modifier.clickable { model.redo() })
                Spacer(Modifier.width(10.dp))
                Icon(CSIcons.Split, "Split at playhead", tint = CS.TextPrimary,
                    modifier = Modifier.clickable { model.splitAt(model.timecodeMs) })
                Spacer(Modifier.width(10.dp))
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
                    Spacer(Modifier.width(6.dp))
                    Text("Saved ✓", color = CS.Success, fontSize = 11.sp)
                }
                Spacer(Modifier.weight(1f))
                Icon(CSIcons.Export, "Export", tint = CS.Accent,
                    modifier = Modifier.clickable {
                        if (exportState == null) startExport(context, model, exporter) { exportState = it }
                    })
            }

            // ── Preview canvas (weight fills the space the timeline leaves) ──
            Box(
                Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .background(Color.Black),
                contentAlignment = Alignment.Center,
            ) {
                BoxWithConstraints(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    val fitsWidth = maxWidth / maxHeight > 16f / 9f
                    val canvasModifier = if (fitsWidth) {
                        Modifier.fillMaxHeight().aspectRatio(16f / 9f)
                    } else {
                        Modifier.fillMaxWidth().aspectRatio(16f / 9f)
                    }
                    Box(
                        canvasModifier
                            .clipToBounds()
                            .background(Color.Black)
                            .clickable {
                                if (model.selectedClipId != null || model.selectedOverlayId != null) {
                                    model.deselectAll()
                                    drawer = null
                                } else if (playback.isPlaying) {
                                    playback.pause()
                                } else {
                                    playback.play()
                                }
                            }
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
                                        setShutterBackgroundColor(android.graphics.Color.BLACK)
                                        player = playback.player
                                    }
                                },
                                modifier = Modifier.fillMaxSize()
                            )
                        }

                        // Text / sticker stack (independent transforms + timing).
                        OverlayLayer(model, Modifier.fillMaxSize())

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
                }
            }

            // ── Contextual tool bar (only what applies to the selection) ──
            Row(
                Modifier
                    .fillMaxWidth()
                    .height(64.dp)
                    .background(CS.Surface)
                    .horizontalScroll(rememberScrollState())
                    .padding(horizontal = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (contextState) {
                    ContextState.NONE -> {
                        CSToolChip(CSIcons.Split, "Split") { model.splitAt(model.timecodeMs) }
                        CSToolChip(CSIcons.Text, "Text") { drawer = EditorDrawer.TEXT }
                        CSToolChip(CSIcons.Sticker, "Stickers") { drawer = EditorDrawer.STICKER }
                        CSToolChip(CSIcons.Audio, "Audio") { drawer = EditorDrawer.AUDIO }
                        CSToolChip(CSIcons.Filter, "Filters") { drawer = EditorDrawer.FILTER }
                        CSToolChip(CSIcons.Transitions, "Transitions") { drawer = EditorDrawer.TRANSITIONS }
                    }
                    ContextState.VIDEO -> {
                        CSToolChip(CSIcons.Split, "Split") { model.splitAt(model.timecodeMs) }
                        CSToolChip(CSIcons.Volume, "Volume") { drawer = EditorDrawer.AUDIO }
                        CSToolChip(CSIcons.Speed, "Speed") { drawer = EditorDrawer.INSPECTOR }
                        CSToolChip(CSIcons.Keyframe, "Keyframes") { drawer = EditorDrawer.KEYFRAMES }
                        CSToolChip(CSIcons.Filter, "Effects") { drawer = EditorDrawer.FILTER }
                        CSToolChip(CSIcons.Transitions, "Transitions") { drawer = EditorDrawer.TRANSITIONS }
                        CSToolChip(CSIcons.Duplicate, "Duplicate") {
                            model.selectedClipId?.let { id ->
                                model.mutate { list ->
                                    val index = list.indexOfFirst { it.id == id }
                                    if (index >= 0) {
                                        list.add(index + 1, list[index].copy(id = System.nanoTime()))
                                    }
                                }
                            }
                        }
                        CSToolChip(CSIcons.Delete, "Delete") {
                            model.selectedClipId?.let { model.delete(it) }
                        }
                    }
                    ContextState.AUDIO -> {
                        CSToolChip(CSIcons.Volume, "Volume") { drawer = EditorDrawer.AUDIO }
                        CSToolChip(CSIcons.Split, "Split") { model.splitAt(model.timecodeMs) }
                        CSToolChip(CSIcons.Delete, "Delete") {
                            model.selectedClipId?.let { model.delete(it) }
                        }
                    }
                    ContextState.TEXT -> {
                        CSToolChip(CSIcons.Text, "Edit") { drawer = EditorDrawer.OVERLAY }
                        CSToolChip(CSIcons.LayerForward, "Layer +") {
                            model.selectedOverlayId?.let { model.bringOverlayForward(it) }
                        }
                        CSToolChip(CSIcons.LayerBackward, "Layer -") {
                            model.selectedOverlayId?.let { model.sendOverlayBackward(it) }
                        }
                        CSToolChip(CSIcons.Trim, "Start here") {
                            model.selectedOverlay?.let { model.overlayStartAtPlayhead(it) }
                        }
                        CSToolChip(CSIcons.Trim, "End here") {
                            model.selectedOverlay?.let { model.overlayEndAtPlayhead(it) }
                        }
                        CSToolChip(CSIcons.Duplicate, "Duplicate") {
                            model.selectedOverlay?.let { model.duplicateOverlay(it) }
                        }
                        CSToolChip(CSIcons.Delete, "Delete") {
                            model.selectedOverlayId?.let { model.deleteOverlay(it) }
                        }
                    }
                    ContextState.OVERLAY -> {
                        CSToolChip(CSIcons.LayerForward, "Layer +") {
                            model.selectedOverlayId?.let { model.bringOverlayForward(it) }
                        }
                        CSToolChip(CSIcons.LayerBackward, "Layer -") {
                            model.selectedOverlayId?.let { model.sendOverlayBackward(it) }
                        }
                        CSToolChip(CSIcons.Trim, "Start here") {
                            model.selectedOverlay?.let { model.overlayStartAtPlayhead(it) }
                        }
                        CSToolChip(CSIcons.Trim, "End here") {
                            model.selectedOverlay?.let { model.overlayEndAtPlayhead(it) }
                        }
                        CSToolChip(CSIcons.Duplicate, "Duplicate") {
                            model.selectedOverlay?.let { model.duplicateOverlay(it) }
                        }
                        CSToolChip(CSIcons.Delete, "Delete") {
                            model.selectedOverlayId?.let { model.deleteOverlay(it) }
                        }
                    }
                }
            }

            // ── Timeline (fixed height, grows with overlay lanes) ──
            TimelineView(
                model = model,
                onSeek = { ms -> seekTo(ms) },
                modifier = Modifier.padding(horizontal = 8.dp),
            )
            Spacer(Modifier.height(6.dp))
        }

        // ── Drawer: anchored to the bottom, never pushes the timeline away ──
        val activeDrawer = drawer
        if (activeDrawer != null) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(Color.Black.copy(alpha = 0.35f))
                    .clickable { drawer = null }
            )
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .heightIn(max = 440.dp)
                    .verticalScroll(rememberScrollState())
                    .background(CS.SurfaceHigh)
            ) {
                when (activeDrawer) {
                    EditorDrawer.INSPECTOR -> ClipInspector(model)
                    EditorDrawer.TEXT -> TextDrawer(model) { drawer = null }
                    EditorDrawer.FILTER -> FilterDrawer(model) { drawer = null }
                    EditorDrawer.TRANSITIONS -> TransitionsDrawer(model) { drawer = null }
                    EditorDrawer.KEYFRAMES -> KeyframeDrawer(model) { drawer = null }
                    EditorDrawer.AUDIO -> AudioDrawer(model) { drawer = null }
                    EditorDrawer.STICKER -> StickerDrawer(model) { drawer = null }
                    EditorDrawer.OVERLAY -> OverlayDrawer(model) { drawer = null }
                }
            }
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
    val main = android.os.Handler(android.os.Looper.getMainLooper())
    setState(ExportUi())
    exporter.export(
        model, out,
        onProgress = {},
        onDone = { file, err ->
            // Transformer reports from its own thread; hop back to the UI one.
            main.post {
                if (file != null) {
                    saveToGallery(context, file)
                    setState(ExportUi(running = false, donePath = file.path))
                } else {
                    setState(ExportUi(running = false, error = err))
                }
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
