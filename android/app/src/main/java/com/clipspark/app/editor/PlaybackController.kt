package com.clipspark.app.editor

import android.content.Context
import android.net.Uri
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer

/**
 * Preview playback (100% on-device). Builds an ExoPlayer playlist from the
 * clip list with per-clip trim windows (ClippingConfiguration). The UI keeps
 * a fixed center playhead; this class maps unified-timeline timecode ⇄
 * playlist item + in-item position, and applies per-clip speed on transitions.
 */
class PlaybackController(context: Context) {

    val player: ExoPlayer = ExoPlayer.Builder(context).build()
    private var clips: List<ClipSegment> = emptyList()
    private var offsets: List<Long> = emptyList()

    init {
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
                // Per-clip speed: swap playback parameters at clip boundaries.
                val clip = clips.getOrNull(player.currentMediaItemIndex) ?: return
                player.playbackParameters = PlaybackParameters(clip.speed.toFloat(), 1f)
            }
        })
    }

    fun setClips(newClips: List<ClipSegment>) {
        clips = newClips
        var acc = 0L
        offsets = newClips.map { val o = acc; acc += it.timelineDurationMs; o }
        val items = newClips.map { c ->
            MediaItem.Builder()
                .setUri(Uri.parse(c.uri))
                .setClippingConfiguration(
                    MediaItem.ClippingConfiguration.Builder()
                        .setStartPositionMs(c.sourceInMs)
                        .setEndPositionMs(c.sourceInMs + c.sourceDurationMs)
                        .build()
                )
                .build()
        }
        player.setMediaItems(items)
        player.prepare()
        player.playbackParameters =
            PlaybackParameters(newClips.firstOrNull()?.speed?.toFloat() ?: 1f, 1f)
        player.playWhenReady = false
    }

    fun play() { player.play() }
    fun pause() { player.pause() }
    val isPlaying: Boolean get() = player.isPlaying

    /** Timeline timecode → playlist seek. */
    fun seekToTimelineMs(t: Long) {
        if (clips.isEmpty()) return
        var idx = clips.indices.lastOrNull { offsets[it] <= t } ?: 0
        if (idx >= clips.size) idx = clips.size - 1
        val local = (t - offsets[idx]).coerceIn(0L, clips[idx].timelineDurationMs)
        player.seekTo(idx, local)
    }

    /** Playlist position → unified timeline timecode. */
    fun currentTimecodeMs(): Long {
        val idx = player.currentMediaItemIndex
        if (idx < 0 || idx >= offsets.size) return 0L
        return offsets[idx] + player.currentPosition
    }

    fun release() { player.release() }
}
