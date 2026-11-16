package com.clipspark.app.drafts

import android.content.Context
import com.clipspark.app.editor.ClipSegment
import com.clipspark.app.editor.CSTransition
import com.clipspark.app.editor.EditorOverlay
import com.clipspark.app.editor.EditorViewModel
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
            clips.put(
                JSONObject()
                    .put("uri", c.uri)
                    .put("in", c.sourceInMs)
                    .put("dur", c.sourceDurationMs)
                    .put("speed", c.speed)
                    .put("volume", c.volume.toDouble())
                    .put("muted", c.muted)
                    .put("transition", c.transitionIn.name)
            )
        }
        json.put("clips", clips)
        val overlays = JSONArray()
        for (o in model.overlays) {
            o.text?.let { t ->
                overlays.put(
                    JSONObject()
                        .put("text", t)
                        .put("x", o.x.toDouble())
                        .put("y", o.y.toDouble())
                        .put("size", o.fontSize.toDouble())
                )
            }
            o.sticker?.let { s ->
                overlays.put(
                    JSONObject()
                        .put("sticker", s)
                        .put("x", o.x.toDouble())
                        .put("y", o.y.toDouble())
                        .put("size", o.fontSize.toDouble())
                )
            }
        }
        json.put("overlays", overlays)
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
                cursor = clip.endMs
                clips.add(clip)
            }
            val overlays = mutableListOf<EditorOverlay>()
            for (i in 0 until overlaysArray.length()) {
                val o = overlaysArray.getJSONObject(i)
                overlays.add(
                    if (o.has("sticker")) {
                        EditorOverlay(
                            id = id++,
                            sticker = o.getString("sticker"),
                            x = o.getDouble("x").toFloat(),
                            y = o.getDouble("y").toFloat(),
                            fontSize = o.getDouble("size").toFloat(),
                        )
                    } else {
                        EditorOverlay(
                            id = id++,
                            text = o.getString("text"),
                            x = o.getDouble("x").toFloat(),
                            y = o.getDouble("y").toFloat(),
                            fontSize = o.getDouble("size").toFloat(),
                        )
                    }
                )
            }
            EditorViewModel().also { it.loadDraft(clips, overlays) }
        } catch (e: Exception) {
            null
        }
    }
}
