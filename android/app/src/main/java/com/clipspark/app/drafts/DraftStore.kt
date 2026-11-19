package com.clipspark.app.drafts

import android.content.Context
import com.clipspark.app.editor.ClipSegment
import com.clipspark.app.editor.CSTransition
import com.clipspark.app.editor.EditorOverlay
import com.clipspark.app.editor.EditorViewModel
import com.clipspark.app.editor.Keyframe
import com.clipspark.app.editor.Look
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Draft persistence — projects saved as JSON in the app's private storage.
 * 100% offline, no external storage permission. Uses the platform org.json
 * (no extra plugin needed). Mirrors the iOS DraftStore semantics.
 */
object DraftStore {

    private fun dir(context: Context): File =
        File(context.filesDir, "drafts").apply { mkdirs() }

    fun save(context: Context, model: EditorViewModel, name: String): Boolean {
        if (model.clips.isEmpty()) return false
        val json = JSONObject()
        json.put("name", name)
        json.put("savedAt", System.currentTimeMillis())
        val clips = JSONArray()
        for (c in model.clips) {
            val kfs = JSONArray()
            for (kf in c.keyframes) kfs.put(kf.toJson().put("id", kf.id))
            clips.put(
                JSONObject()
                    .put("uri", c.uri)
                    .put("in", c.sourceInMs)
                    .put("dur", c.sourceDurationMs)
                    .put("speed", c.speed)
                    .put("volume", c.volume.toDouble())
                    .put("muted", c.muted)
                    .put("transition", c.transitionIn.name)
                    .put("kfs", kfs)
            )
        }
        json.put("clips", clips)
        val overlays = JSONArray()
        for (o in model.overlays) {
            val obj = JSONObject()
                .put("x", o.x.toDouble())
                .put("y", o.y.toDouble())
                .put("size", o.fontSize.toDouble())
                .put("scale", o.scale.toDouble())
                .put("rotation", o.rotation.toDouble())
                .put("opacity", o.opacity.toDouble())
                .put("start", o.startMs)
                .put("dur", o.durationMs ?: -1L)
                .put("color", o.colorArgb)
            o.text?.let { obj.put("text", it) }
            o.sticker?.let { obj.put("sticker", it) }
            overlays.put(obj)
        }
        json.put("overlays", overlays)
        json.put(
            "look",
            JSONObject()
                .put("brightness", model.look.brightness.toDouble())
                .put("contrast", model.look.contrast.toDouble())
                .put("saturation", model.look.saturation.toDouble())
                .put("motionBlur", model.look.motionBlur.toDouble())
                .put("motionBlurAngle", model.look.motionBlurAngle.toDouble())
        )
        return try {
            File(dir(context), "$name.json").writeText(json.toString())
            true
        } catch (e: Exception) {
            false
        }
    }

    fun list(context: Context): List<String> =
        dir(context).listFiles()
            ?.filter { it.extension == "json" }
            ?.map { it.nameWithoutExtension }
            ?.sorted()
            ?: emptyList()

    fun delete(context: Context, name: String): Boolean =
        File(dir(context), "$name.json").delete()

    /** Rebuilds an editor from a saved draft, or null if unreadable. */
    fun restore(context: Context, name: String): EditorViewModel? {
        val file = File(dir(context), "$name.json")
        return try {
            val json = JSONObject(file.readText())
            val clipsArray = json.getJSONArray("clips")
            val overlaysArray = json.getJSONArray("overlays")

            val clips = mutableListOf<ClipSegment>()
            var cursor = 0L
            var id = 0L
            for (i in 0 until clipsArray.length()) {
                val o = clipsArray.getJSONObject(i)
                val clip = ClipSegment(
                    id = id++,
                    uri = o.getString("uri"),
                    sourceInMs = o.getLong("in"),
                    sourceDurationMs = o.getLong("dur"),
                    speed = o.getDouble("speed"),
                    volume = o.getDouble("volume").toFloat(),
                    muted = o.getBoolean("muted"),
                    transitionIn = CSTransition.valueOf(o.getString("transition")),
                )
                clip.startMs = cursor
                clip.endMs = cursor + clip.timelineDurationMs
                // Keyframes are optional: drafts saved before keyframes still load.
                val kfsArray = if (o.has("kfs")) o.getJSONArray("kfs") else null
                if (kfsArray != null) {
                    val restored = mutableListOf<Keyframe>()
                    for (k in 0 until kfsArray.length()) {
                        restored.add(Keyframe.fromJson(kfsArray.getJSONObject(k)))
                    }
                    clip.keyframes = restored
                }
                cursor = clip.endMs
                clips.add(clip)
            }
            val overlays = mutableListOf<EditorOverlay>()
            for (i in 0 until overlaysArray.length()) {
                val o = overlaysArray.getJSONObject(i)
                // Fields added with multi-overlay support are optional so
                // drafts saved by older versions still decode.
                val legacy = !o.has("scale")
                val rawSize = o.getDouble("size").toFloat()
                val durationMs = if (o.has("dur") && o.getLong("dur") >= 0) o.getLong("dur") else null
                overlays.add(
                    EditorOverlay(
                        id = id++,
                        text = if (o.has("text")) o.getString("text") else null,
                        sticker = if (o.has("sticker")) o.getString("sticker") else null,
                        colorArgb = if (o.has("color")) o.getLong("color") else 0xFFFFFFFF,
                        fontSize = if (legacy) rawSize * 1.7f else rawSize,
                        x = o.getDouble("x").toFloat(),
                        y = o.getDouble("y").toFloat(),
                        scale = if (o.has("scale")) o.getDouble("scale").toFloat() else 1f,
                        rotation = if (o.has("rotation")) o.getDouble("rotation").toFloat() else 0f,
                        opacity = if (o.has("opacity")) o.getDouble("opacity").toFloat() else 1f,
                        startMs = if (o.has("start")) o.getLong("start") else 0L,
                        durationMs = durationMs,
                    )
                )
            }
            val restoredLook = if (json.has("look")) {
                val l = json.getJSONObject("look")
                Look(
                    brightness = l.optDouble("brightness", 0.0).toFloat(),
                    contrast = l.optDouble("contrast", 1.0).toFloat(),
                    saturation = l.optDouble("saturation", 1.0).toFloat(),
                    motionBlur = l.optDouble("motionBlur", 0.0).toFloat(),
                    motionBlurAngle = l.optDouble("motionBlurAngle", 0.0).toFloat(),
                )
            } else null
            EditorViewModel().also { it.loadDraft(clips, overlays, restoredLook) }
        } catch (e: Exception) {
            null
        }
    }
}
