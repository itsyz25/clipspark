package com.clipspark.app.editor

import android.content.Context
import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.neverEqualPolicy
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel

// Clip + overlay state model — Kotlin mirror of EditorViewModel.swift.

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
    var keyframes: List<Keyframe> = emptyList(),  // clip-relative timeline ms
) {
    var startMs: Long = 0
    var endMs: Long = 0
    val timelineDurationMs: Long get() = (sourceDurationMs / speed).toLong()

    fun durationText(): String {
        val s = (timelineDurationMs / 1000).toInt()
        return "%02d:%02d".format(s / 60, s % 60)
    }
}

/**
 * Text/sticker overlay. Overlays are a stack: list order is z-order (later =
 * frontmost) and each one owns its own timeline window, so several can overlap
 * freely and be edited independently.
 */
data class EditorOverlay(
    val id: Long,
    val text: String? = null,      // text overlay content
    val sticker: String? = null,   // emoji glyph for sticker overlays
    val colorArgb: Long = 0xFFFFFFFF,
    /** Authored against a 400 px-tall reference frame (preview + export match). */
    val fontSize: Float = 34f,
    val x: Float = 0.5f,
    val y: Float = 0.5f,
    val scale: Float = 1f,
    val rotation: Float = 0f,      // degrees, clockwise
    val opacity: Float = 1f,
    val startMs: Long = 0L,
    val durationMs: Long? = null,  // null → until the end of the project
) {
    val endMs: Long get() = durationMs?.let { startMs + it } ?: Long.MAX_VALUE

    fun isVisibleAt(t: Long): Boolean = t >= startMs && t <= endMs
}

data class Look(
    var brightness: Float = 0f,    // -0.2..0.2
    var contrast: Float = 1f,      // 0.5..1.5
    var saturation: Float = 1f,    // 0..2
    var motionBlur: Float = 0f,    // 0..1 (0 = off)
    var motionBlurAngle: Float = 0f, // degrees 0..180
)

/** Which bottom drawer is open in the editor screen. */
enum class EditorDrawer { INSPECTOR, TEXT, STICKER, FILTER, TRANSITIONS, AUDIO, KEYFRAMES, OVERLAY }

/**
 * Editing core: snapshot-based undo (clips + overlays + look, 50 steps), the
 * same one-undo-step-per-gesture rule as iOS. Playback + export run through
 * Media3 (ExoPlayer preview; Transformer encode) — 100% on-device.
 */
class EditorViewModel : ViewModel() {
    // neverEqual: several edits mutate a clip in place (trim/speed), so the
    // list would compare equal to its pre-edit self. Always notify instead.
    var clips by mutableStateOf<List<ClipSegment>>(emptyList(), neverEqualPolicy()); private set
    var overlays by mutableStateOf<List<EditorOverlay>>(emptyList(), neverEqualPolicy()); private set
    var look by mutableStateOf(Look())
    var timecodeMs by mutableStateOf(0L); private set
    fun updateTimecode(ms: Long) { timecodeMs = ms }

    /** Rebuild state from a saved draft (DraftStore). */
    fun loadDraft(clips: List<ClipSegment>, overlays: List<EditorOverlay>, restoredLook: Look? = null) {
        this.clips = clips
        this.overlays = overlays
        if (restoredLook != null) look = restoredLook
        relayout()
    }

    var selectedClipId by mutableStateOf<Long?>(null)
    var selectedOverlayId by mutableStateOf<Long?>(null)
    var canUndo by mutableStateOf(false); private set
    var canRedo by mutableStateOf(false); private set

    private data class Snapshot(
        val clips: List<ClipSegment>,
        val overlays: List<EditorOverlay>,
        val look: Look,
    )

    private var undoStack = mutableListOf<Snapshot>()
    private var redoStack = mutableListOf<Snapshot>()

    private fun snapshot() = Snapshot(
        clips = clips.map { it.copy(keyframes = it.keyframes.toList()) },
        overlays = overlays.toList(),
        look = look.copy(),
    )

    private fun apply(s: Snapshot) {
        clips = s.clips
        overlays = s.overlays
        look = s.look
        relayout()
        syncFlags()
    }

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
        undoStack.add(snapshot()); if (undoStack.size > 50) undoStack.removeFirst()
        redoStack.clear(); syncFlags()
    }

    fun undo() {
        undoStack.removeLastOrNull()?.let {
            redoStack.add(snapshot())
            apply(it)
            selectedOverlayId = null
        }
    }

    fun redo() {
        redoStack.removeLastOrNull()?.let {
            undoStack.add(snapshot())
            apply(it)
            selectedOverlayId = null
        }
    }

    private fun syncFlags() { canUndo = undoStack.isNotEmpty(); canRedo = redoStack.isNotEmpty() }

    fun mutate(change: (MutableList<ClipSegment>) -> Unit) {
        pushUndo()
        val copy = clips.toMutableList(); change(copy); clips = copy; relayout()
    }

    fun select(id: Long?) {
        selectedClipId = id
        if (id != null) selectedOverlayId = null
    }

    fun splitAt(timecode: Long) {
        val target = clips.firstOrNull { timecode >= it.startMs + 100 && timecode <= it.endMs - 100 } ?: return
        val splitLocalMs = timecode - target.startMs
        val splitSourceMs = (splitLocalMs * target.speed).toLong()
        val leftKfs = target.keyframes.filter { it.timeMs <= splitLocalMs }
        val rightKfs = target.keyframes.filter { it.timeMs > splitLocalMs }
            .map { it.copy(timeMs = it.timeMs - splitLocalMs) }
        mutate {
            val index = it.indexOfFirst { c -> c.id == target.id }
            val left = target.copy(id = System.nanoTime()).apply {
                sourceDurationMs = splitSourceMs
                keyframes = leftKfs
            }
            val right = target.copy(id = System.nanoTime() + 1).apply {
                sourceInMs = target.sourceInMs + splitSourceMs
                sourceDurationMs = target.sourceDurationMs - splitSourceMs
                keyframes = rightKfs
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

    // Keyframe edits — objects are copied (never mutated in place) so the
    // snapshot undo stack keeps real pre-edit states.

    fun keyframesOf(clipId: Long, property: KeyframeProperty): List<Keyframe> =
        clips.firstOrNull { it.id == clipId }?.keyframes
            ?.filter { it.property == property }?.sortedBy { it.timeMs } ?: emptyList()

    fun addKeyframe(clipId: Long, property: KeyframeProperty, value: Double, atTimelineMs: Long) {
        mutate {
            val index = it.indexOfFirst { c -> c.id == clipId }
            if (index >= 0) {
                val c = it[index]
                val kf = Keyframe(
                    id = System.nanoTime(), property = property,
                    timeMs = atTimelineMs.coerceIn(0, c.timelineDurationMs),
                    value = property.clamp(value),
                )
                it[index] = c.copy(keyframes = c.keyframes + kf)
            }
        }
    }

    fun updateKeyframe(clipId: Long, kf: Keyframe) {
        mutate {
            val index = it.indexOfFirst { c -> c.id == clipId }
            if (index >= 0) {
                val c = it[index]
                it[index] = c.copy(keyframes = c.keyframes.map { if (it.id == kf.id) kf else it })
            }
        }
    }

    fun removeKeyframe(clipId: Long, kfId: Long) {
        mutate {
            val index = it.indexOfFirst { c -> c.id == clipId }
            if (index >= 0) {
                val c = it[index]
                it[index] = c.copy(keyframes = c.keyframes.filterNot { k -> k.id == kfId })
            }
        }
    }

    fun removeKeyframes(clipId: Long, property: KeyframeProperty) {
        mutate {
            val index = it.indexOfFirst { c -> c.id == clipId }
            if (index >= 0) {
                val c = it[index]
                it[index] = c.copy(keyframes = c.keyframes.filterNot { k -> k.property == property })
            }
        }
    }

    // Live drag support: snapshot once at gesture start (mirrors iOS).
    private var pendingKeyframeUndo: Snapshot? = null

    /** Starts an undo batch if one isn't already open (slider first tick). */
    fun ensureKeyframeUndo() { if (pendingKeyframeUndo == null) pendingKeyframeUndo = snapshot() }

    fun beginKeyframeDrag() { pendingKeyframeUndo = snapshot() }

    fun endKeyframeDrag() {
        pendingKeyframeUndo?.let {
            undoStack.add(it); if (undoStack.size > 50) undoStack.removeFirst()
            redoStack.clear(); syncFlags()
        }
        pendingKeyframeUndo = null
    }

    /** Live keyframe move during a drag — no undo, no relayout. */
    fun updateKeyframeLive(clipId: Long, kf: Keyframe) {
        // Open an undo batch on the first live tick if the caller (drag) did
        // not already open one; the batch is committed by endKeyframeDrag().
        if (pendingKeyframeUndo == null) pendingKeyframeUndo = snapshot()
        val index = clips.indexOfFirst { it.id == clipId }
        if (index < 0) return
        val c = clips[index]
        val updated = c.copy(keyframes = c.keyframes.map { if (it.id == kf.id) kf else it })
        val copy = clips.toMutableList(); copy[index] = updated
        clips = copy
    }

    // MARK: - Look (filters / adjust / motion blur)

    fun setLook(newLook: Look) { look = newLook }

    fun updateLookLive(transform: (Look) -> Look) { look = transform(look) }

    // MARK: - Overlays (multiple, stacked, independently timed)

    private var pendingOverlayUndo: Snapshot? = null

    /** Snapshot before an overlay gesture; committed once on release. */
    fun beginOverlayDrag() { pendingOverlayUndo = snapshot() }

    fun endOverlayDrag() {
        pendingOverlayUndo?.let {
            undoStack.add(it); if (undoStack.size > 50) undoStack.removeFirst()
            redoStack.clear(); syncFlags()
        }
        pendingOverlayUndo = null
    }

    /** Live gesture update (drag/pinch/rotate) — no history write per tick. */
    fun updateOverlayLive(overlay: EditorOverlay) {
        if (pendingOverlayUndo == null) pendingOverlayUndo = snapshot()
        overlays = overlays.map { if (it.id == overlay.id) overlay else it }
    }

    /** Committed overlay edit: one undo step (drawers, colour, layer order). */
    fun updateOverlay(overlay: EditorOverlay) {
        pushUndo()
        overlays = overlays.map { if (it.id == overlay.id) overlay else it }
    }

    val selectedOverlay: EditorOverlay?
        get() = selectedOverlayId?.let { id -> overlays.firstOrNull { it.id == id } }

    fun selectOverlay(id: Long?) {
        selectedOverlayId = id
        if (id != null) selectedClipId = null
    }

    fun deselectAll() {
        selectedClipId = null
        selectedOverlayId = null
    }

    fun visibleOverlaysAt(t: Long): List<EditorOverlay> =
        overlays.filter { it.isVisibleAt(t) }

    private fun defaultOverlayWindow(): Pair<Long, Long?> {
        val total = totalMs().coerceAtLeast(1L)
        val start = timecodeMs.coerceIn(0L, (total - 500L).coerceAtLeast(0L))
        val remaining = total - start
        return start to if (remaining > 500L) minOf(3000L, remaining) else null
    }

    fun addText(text: String, colorArgb: Long? = null) {
        val (start, duration) = defaultOverlayWindow()
        val overlay = EditorOverlay(
            id = System.nanoTime(),
            text = text,
            colorArgb = colorArgb ?: 0xFFFFFFFF,
            startMs = start,
            durationMs = duration,
        )
        pushUndo()
        overlays = overlays + overlay
        selectOverlay(overlay.id)
    }

    fun addSticker(symbol: String) {
        val (start, duration) = defaultOverlayWindow()
        val overlay = EditorOverlay(
            id = System.nanoTime(),
            sticker = symbol,
            fontSize = 60f,
            startMs = start,
            durationMs = duration,
        )
        pushUndo()
        overlays = overlays + overlay
        selectOverlay(overlay.id)
    }

    fun duplicateOverlay(overlay: EditorOverlay) {
        val copy = overlay.copy(
            id = System.nanoTime(),
            x = (overlay.x + 0.04f).coerceAtMost(1f),
            y = (overlay.y + 0.04f).coerceAtMost(1f),
        )
        pushUndo()
        overlays = overlays + copy
        selectOverlay(copy.id)
    }

    fun deleteOverlay(overlayId: Long) {
        pushUndo()
        overlays = overlays.filterNot { it.id == overlayId }
        if (selectedOverlayId == overlayId) selectedOverlayId = null
    }

    // Z-order == list order: later entries draw on top.
    fun bringOverlayForward(overlayId: Long) = moveOverlay(overlayId, 1)
    fun sendOverlayBackward(overlayId: Long) = moveOverlay(overlayId, -1)

    private fun moveOverlay(overlayId: Long, delta: Int) {
        val index = overlays.indexOfFirst { it.id == overlayId }
        if (index < 0) return
        val target = index + delta
        if (target !in overlays.indices) return
        pushUndo()
        val copy = overlays.toMutableList()
        val tmp = copy[index]; copy[index] = copy[target]; copy[target] = tmp
        overlays = copy
    }

    fun trimOverlayStart(overlay: EditorOverlay, atMs: Long) {
        val end = overlay.endMs
        val newStart = atMs.coerceIn(0L, (end - 100L).coerceAtLeast(0L))
        updateOverlayLive(
            overlay.copy(
                startMs = newStart,
                durationMs = overlay.durationMs?.let { (end - newStart).coerceAtLeast(100L) },
            )
        )
    }

    fun trimOverlayEnd(overlay: EditorOverlay, atMs: Long) {
        updateOverlayLive(
            overlay.copy(durationMs = (atMs - overlay.startMs).coerceAtLeast(100L))
        )
    }

    fun overlayStartAtPlayhead(overlay: EditorOverlay) {
        val end = overlay.endMs
        updateOverlay(overlay.copy(startMs = timecodeMs.coerceIn(0L, (end - 100L).coerceAtLeast(0L))))
    }

    fun overlayEndAtPlayhead(overlay: EditorOverlay) {
        updateOverlay(overlay.copy(durationMs = (timecodeMs - overlay.startMs).coerceAtLeast(100L)))
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

    /** Sticker set — emoji glyphs bundled with the OS, no network assets. */
    companion object {
        val stickerCatalog: List<Pair<String, String>> = listOf(
            "😀" to "Happy", "😎" to "Cool", "❤️" to "Heart", "⭐" to "Star",
            "⚡" to "Bolt", "🔥" to "Fire", "👍" to "Nice", "✅" to "Check",
            "😴" to "Zzz", "🎵" to "Note", "✨" to "Sparkle", "👑" to "Crown",
        )
    }
}
