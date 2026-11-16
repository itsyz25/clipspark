package com.clipspark.app.editor

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel

// Clip state model — Kotlin mirror of EditorViewModel.swift (Units 5–7).

enum class CSTransition(val label: String) {
    NONE("None"), CROSSFADE("Dissolve"), PUSH_LEFT("Push →"), PUSH_RIGHT("Push ←"), FADE_BLACK("Black dip");

    companion object { val all = entries }
}

data class ClipSegment(
    val id: Long,
    val uri: String,               // content URI of the source video
    var sourceInMs: Long,
    var sourceDurationMs: Long,    // content used from source
    var speed: Double = 1.0,
    var volume: Float = 1f,
    var muted: Boolean = false,
    var transitionIn: CSTransition = CSTransition.NONE,
) {
    var startMs: Long = 0
    var endMs: Long = 0
    val timelineDurationMs: Long get() = (sourceDurationMs / speed).toLong()

    fun durationText(): String {
        val s = (timelineDurationMs / 1000).toInt()
        return "%02d:%02d".format(s / 60, s % 60)
    }
}

data class EditorOverlay(
    val id: Long,
    val text: String? = null,      // null → sticker (material symbol name)
    val colorArgb: Long = 0xFFFFFFFF,
    val fontSize: Float = 20f,
    val x: Float = 0.5f,
    val y: Float = 0.5f,
)

data class Look(
    var brightness: Float = 0f,    // -0.2..0.2
    var contrast: Float = 1f,      // 0.5..1.5
    var saturation: Float = 1f,    // 0..2
)

/**
 * Editing core: snapshot-based undo (clips + overlays, 50 steps), the same
 * one-undo-step-per-gesture rule as iOS. Playback + export run through Media3
 * (ExoPlayer preview; Transformer encode) — 100% on-device.
 */
class EditorViewModel : ViewModel() {
    var clips by mutableStateOf<List<ClipSegment>>(emptyList()); private set
    var overlays by mutableStateOf<List<EditorOverlay>>(emptyList())
    var look = Look()
    var timecodeMs by mutableStateOf(0L); private set
    fun updateTimecode(ms: Long) { timecodeMs = ms }

    /** Rebuild state from a saved draft (DraftStore). */
    fun loadDraft(clips: List<ClipSegment>, overlays: List<EditorOverlay>) {
        this.clips = clips
        this.overlays = overlays
    }
    var selectedClipId by mutableStateOf<Long?>(null)
    var canUndo by mutableStateOf(false); private set
    var canRedo by mutableStateOf(false); private set

    private var undoStack = mutableListOf<List<ClipSegment>>()
    private var redoStack = mutableListOf<List<ClipSegment>>()

    fun load(context: Context, uris: List<String>, speeds: List<Double> = emptyList(), transition: CSTransition = CSTransition.NONE) {
        var id = 0L; var cursor = 0L
        clips = uris.mapIndexed { index, uri ->
            val speed = if (speeds.isNotEmpty()) speeds[index % speeds.size] else 1.0
            // Real duration, read on-device with MediaMetadataRetriever (offline).
            val durationMs = videoDurationMs(context, uri)
            val clip = ClipSegment(id++, uri, 0, durationMs, speed, transitionIn = if (index == 0) CSTransition.NONE else transition)
            clip.startMs = cursor; clip.endMs = cursor + clip.timelineDurationMs
            cursor = clip.endMs
            clip
        }
    }

    private fun videoDurationMs(context: Context, uri: String): Long {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, Uri.parse(uri))
            retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull() ?: 5000L
        } catch (e: Exception) {
            5000L
        } finally {
            try { retriever.release() } catch (e: Exception) { }
        }
    }

    private fun pushUndo() {
        undoStack.add(clips); if (undoStack.size > 50) undoStack.removeFirst()
        redoStack.clear(); syncFlags()
    }

    fun undo() {
        undoStack.removeLastOrNull()?.let { redoStack.add(clips); clips = it; syncFlags() }
    }

    fun redo() {
        redoStack.removeLastOrNull()?.let { undoStack.add(clips); clips = it; syncFlags() }
    }

    private fun syncFlags() { canUndo = undoStack.isNotEmpty(); canRedo = redoStack.isNotEmpty() }

    fun mutate(change: (MutableList<ClipSegment>) -> Unit) {
        pushUndo()
        val copy = clips.toMutableList(); change(copy); clips = copy; relayout()
    }

    fun select(id: Long?) { selectedClipId = id }

    fun splitAt(timecode: Long) {
        val target = clips.firstOrNull { timecode >= it.startMs + 100 && timecode <= it.endMs - 100 } ?: return
        mutate {
            val index = it.indexOfFirst { c -> c.id == target.id }
            val left = target.copy(id = System.nanoTime()).apply {
                sourceDurationMs = timecode - target.startMs
            }
            val right = target.copy(id = System.nanoTime() + 1).apply {
                sourceInMs = target.sourceInMs + (timecode - target.startMs)
                sourceDurationMs = target.sourceDurationMs - left.sourceDurationMs
            }
            it[index] = left; it.add(index + 1, right)
        }
        selectedClipId = null
    }

    fun trim(clipId: Long, newTimelineMs: Long, fromLeading: Boolean) {
        val index = clips.indexOfFirst { it.id == clipId }; if (index < 0) return
        val clip = clips[index]
        val newSourceMs = (newTimelineMs * clip.speed).toLong().coerceAtLeast(200)
        mutate {
            if (fromLeading) {
                val delta = clip.sourceDurationMs - newSourceMs
                it[index].sourceInMs = (clip.sourceInMs + delta).coerceIn(0, clip.sourceDurationMs - 200)
                it[index].sourceDurationMs = newSourceMs
            } else {
                it[index].sourceDurationMs = newSourceMs
            }
        }
    }

    fun setSpeed(clipId: Long, speed: Double) {
        mutate { it.firstOrNull { c -> c.id == clipId }?.speed = speed.coerceIn(0.25, 4.0) }
    }

    fun move(clipId: Long, by: Int) {
        mutate {
            val index = it.indexOfFirst { c -> c.id == clipId }
            val target = index + by
            if (index >= 0 && target in it.indices) {
                val tmp = it[index]; it[index] = it[target]; it[target] = tmp
            }
        }
    }

    fun delete(clipId: Long) {
        mutate { it.removeAll { c -> c.id == clipId } }
        selectedClipId = null
    }

    fun addText(text: String) {
        overlays = overlays + EditorOverlay(System.nanoTime(), text = text)
    }

    fun deleteOverlay(overlayId: Long) {
        overlays = overlays.filterNot { it.id == overlayId }
    }

    fun setTransition(clipId: Long, type: CSTransition) {
        mutate { it.firstOrNull { c -> c.id == clipId }?.transitionIn = type }
    }

    private fun relayout() {
        var cursor = 0L
        clips = clips.map { c ->
            c.startMs = cursor; c.endMs = cursor + c.timelineDurationMs; cursor = c.endMs; c
        }
    }

    fun totalMs(): Long = clips.sumOf { it.timelineDurationMs }

    fun timecodeText(ms: Long = timecodeMs): String {
        val s = (ms / 1000).toInt(); return "%02d:%02d".format(s / 60, s % 60)
    }
}
