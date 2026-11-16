package com.clipspark.app.editor

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * Offline export via Media3 Transformer (hardware codecs). Builds a
 * Composition from the clip list: per-clip trim (clipping), speed, and mute.
 * Transitions/text overlays are NOT baked yet (Transformer sequences don't
 * support crossfades) — documented honestly in the verification report.
 */
class ExportController(private val context: Context) {

    private var transformer: Transformer? = null

    /**
     * @param onDone called exactly once with the output file, or null + error.
     */
    fun export(
        clips: List<ClipSegment>,
        output: File,
        onProgress: (Float) -> Unit,
        onDone: (File?, String?) -> Unit,
    ) {
        val items = clips.map { c ->
            val mediaItem = MediaItem.Builder()
                .setUri(Uri.parse(c.uri))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(c.sourceInMs)
                        .setEndPositionMs(c.sourceInMs + c.sourceDurationMs)
                        .build()
                )
                .build()
            EditedMediaItem.Builder(mediaItem)
                .setRemoveAudio(c.muted)
                .setSpeed(constantSpeed(c.speed.toFloat()))
                .build()
        }

        val sequence = EditedMediaItemSequence.withAudioAndVideoFrom(items)
        val composition = Composition.Builder(sequence).build()

        val listener = object : Transformer.Listener {
            override fun onCompleted(composition: Composition, result: ExportResult) {
                onDone(output, null)
            }
            override fun onError(
                composition: Composition,
                result: ExportResult,
                exception: ExportException,
            ) {
                onDone(null, exception.message ?: "Export failed")
            }
        }

        val t = Transformer.Builder(context).addListener(listener).build()
        transformer = t
        t.start(composition, output.path)
    }

    /** Poll ~4×/s from the UI. Returns 0..1, or 0 when unknown/idle. */
    fun pollProgress(): Float {
        val t = transformer ?: return 0f
        val holder = ProgressHolder()
        val state = t.getProgress(holder)
        return if (state == Transformer.PROGRESS_STATE_AVAILABLE) holder.progress / 100f else 0f
    }

    fun cancel() { transformer?.cancel() }

    private fun constantSpeed(speed: Float): SpeedProvider = object : SpeedProvider {
        override fun getSpeed(presentationTimeUs: Long): Float = speed
        override fun getNextSpeedChangeTimeUs(presentationTimeUs: Long): Long = C.TIME_UNSET
    }
}
