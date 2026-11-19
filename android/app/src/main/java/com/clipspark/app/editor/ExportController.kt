package com.clipspark.app.editor

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Typeface
import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.Effect
import androidx.media3.common.MediaItem
import androidx.media3.common.OverlaySettings
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.SpeedProvider
import androidx.media3.common.util.Size
import androidx.media3.effect.BitmapOverlay
import androidx.media3.effect.OverlayEffect
import androidx.media3.effect.StaticOverlaySettings
import androidx.media3.effect.TextureOverlay
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.EditedMediaItemSequence
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File
import kotlin.math.ceil

/**
 * Offline export via Media3 Transformer (hardware codecs). Builds a
 * Composition from the clip list: per-clip trim (clipping), speed, and mute,
 * then bakes the project look, the adjustable motion blur and every visible
 * text/sticker overlay into the encoded frames — same GL effects the preview
 * uses, all on-device.
 *
 * Honest limits: transitions are still not blended by Transformer sequences,
 * and per-clip keyframe transforms are previewed but not baked here.
 */
class ExportController(private val context: Context) {

    private var transformer: Transformer? = null

    /** Reference frame height the overlay geometry is authored against. */
    private val referenceHeight = 1080f

    /**
     * @param onDone called exactly once with the output file, or null + error.
     */
    fun export(
        model: EditorViewModel,
        output: File,
        onProgress: (Float) -> Unit,
        onDone: (File?, String?) -> Unit,
    ) {
        val clips = model.clips
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
        val videoEffects = mutableListOf<Effect>()
        videoEffects.addAll(buildLookEffects(model.look))
        // Overlays go last so they stay sharp on top of the graded footage.
        val timedOverlays: List<TextureOverlay> = model.overlays.map { overlay ->
            TimedBitmapOverlay(
                bitmap = overlayBitmap(overlay),
                startUs = overlay.startMs * 1000L,
                endUs = overlay.durationMs?.let { (overlay.startMs + it) * 1000L } ?: Long.MAX_VALUE / 2,
                anchorX = overlay.x * 2f - 1f,
                anchorY = 1f - overlay.y * 2f, // NDC is y-up, preview is y-down
                scale = overlay.scale,
                rotationDegrees = -overlay.rotation, // Media3 rotation is counter-clockwise
                opacity = overlay.opacity.coerceIn(0f, 1f),
            )
        }
        if (timedOverlays.isNotEmpty()) {
            videoEffects.add(OverlayEffect(timedOverlays))
        }

        val composition = Composition.Builder(sequence)
            .setEffects(Effects(emptyList<AudioProcessor>(), videoEffects))
            .build()

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

    /**
     * Rasterise a text/sticker overlay at a 1080-tall reference frame. The
     * overlay settings later divide that geometry by the real frame height, so
     * the export resolution can differ without changing the layout.
     */
    private fun overlayBitmap(overlay: EditorOverlay): Bitmap {
        val label = overlay.text ?: overlay.sticker ?: ""
        val textSizePx = referenceHeight / 400f * overlay.fontSize
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            textSize = textSizePx
            color = overlay.colorArgb.toInt()
            typeface = if (overlay.text != null) {
                Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            } else {
                Typeface.DEFAULT
            }
        }
        val metrics = paint.fontMetrics
        val width = ceil(paint.measureText(label)).toInt().coerceAtLeast(1) + 16
        val height = ceil(metrics.descent - metrics.ascent).toInt().coerceAtLeast(1) + 8
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawText(label, 8f, 4f - metrics.ascent, paint)
        return bitmap
    }
}

/**
 * A [BitmapOverlay] whose settings (anchor, scale, rotation, alpha and
 * visibility) are evaluated per frame. The alpha gate is how overlays get
 * their own time window inside a single composition-wide effect.
 */
private class TimedBitmapOverlay(
    private val bitmap: Bitmap,
    private val startUs: Long,
    private val endUs: Long,
    private val anchorX: Float,
    private val anchorY: Float,
    private val scale: Float,
    private val rotationDegrees: Float,
    private val opacity: Float,
) : BitmapOverlay() {

    @Volatile
    private var videoHeight = 1080

    override fun getBitmap(presentationTimeUs: Long): Bitmap = bitmap

    override fun configure(videoSize: Size) {
        videoHeight = videoSize.height.coerceAtLeast(1)
    }

    override fun getOverlaySettings(presentationTimeUs: Long): OverlaySettings {
        val visible = presentationTimeUs in startUs..endUs
        // Bitmap was rasterised for 1080 px; shrink/grow to the real frame.
        val resize = scale * (videoHeight / 1080f)
        return StaticOverlaySettings.Builder()
            .setBackgroundFrameAnchor(anchorX, anchorY)
            .setScale(resize, resize)
            .setRotationDegrees(rotationDegrees)
            .setAlphaScale(if (visible) opacity else 0f)
            .build()
    }
}
