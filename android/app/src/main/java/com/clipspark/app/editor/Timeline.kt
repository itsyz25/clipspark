package com.clipspark.app.editor

import android.graphics.Paint
import android.graphics.Typeface
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipspark.app.designsystem.CS
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max

/**
 * Multi-track timeline (mirrors iOS TimelineView):
 *
 *  • drag the playhead flag → move the playhead itself
 *  • drag the film strip   → scrub the project under the playhead
 *  • drag an overlay block → slide that overlay in time
 *  • drag an overlay edge  → trim that overlay
 *  • pinch                 → zoom around the playhead
 *  • tap                   → select a clip / overlay, or park the playhead
 *
 * The math is anchored on model time (ms) and a pixel-per-second zoom factor,
 * so scrolling, zooming and selection never fight each other.
 */
@Composable
fun TimelineView(
    model: EditorViewModel,
    onSeek: (Long) -> Unit,
    modifier: Modifier = Modifier,
) {
    val density = LocalDensity.current
    var pps by remember { mutableStateOf(48f) }            // px per second
    var scrollMs by remember { mutableStateOf(0.0) }        // time at the left edge
    var playheadX by remember { mutableStateOf(0f) }        // px inside the view
    var widthPx by remember { mutableStateOf(0f) }
    var dragging by remember { mutableStateOf(false) }

    val rulerH = with(density) { 18.dp.toPx() }
    val videoTop = with(density) { 21.dp.toPx() }
    val videoH = with(density) { 46.dp.toPx() }
    val lanesTop = videoTop + videoH + with(density) { 6.dp.toPx() }
    val laneH = with(density) { 20.dp.toPx() }
    val laneGap = with(density) { 3.dp.toPx() }
    val labelPx = with(density) { 9.sp.toPx() }

    val laneCount = model.overlays.size.coerceIn(1, 3)
    val heightDp = (21 + 46 + 6 + laneCount * 23 + 8).dp

    fun totalMs(): Long = model.totalMs().coerceAtLeast(1L)

    fun maxScrollMs(): Double {
        val visibleMs = if (pps > 0f) widthPx / pps * 1000.0 else 0.0
        return (totalMs() - visibleMs).coerceAtLeast(0.0)
    }

    fun clampScroll(v: Double): Double = v.coerceIn(0.0, maxScrollMs())

    fun xFor(ms: Long): Float = ((ms - scrollMs) / 1000.0 * pps).toFloat()

    /** Keep `time` under the playhead, clamping at both ends of the project. */
    fun follow(time: Long) {
        if (widthPx <= 1f) return
        val anchor = if (playheadX <= 0f) widthPx / 2f else playheadX
        var scroll = time / 1000.0 * pps - anchor
        scroll = scroll.coerceIn(0.0, maxScrollMs())
        scrollMs = scroll
        val x = (time / 1000.0 * pps - scroll).toFloat()
        playheadX = x.coerceIn(8f, max(8f, widthPx - 8f))
    }

    fun laneTop(index: Int): Float = lanesTop + index * (laneH + laneGap)

    fun hitTest(p: Offset, w: Float): TimelineMode {
        if (abs(p.x - playheadX) <= 18f) return TimelineMode.Playhead
        val lanes = model.overlays.take(3)
        for ((index, overlay) in lanes.withIndex()) {
            val top = laneTop(index)
            if (p.y < top || p.y > top + laneH) continue
            val x0 = xFor(overlay.startMs)
            val x1 = xFor(minOf(overlay.endMs, totalMs()))
            if (p.x < x0 - 8f || p.x > x1 + 8f) continue
            return when {
                abs(p.x - x0) <= 16f -> TimelineMode.Overlay(overlay.id, OVERLAY_START)
                abs(p.x - x1) <= 16f -> TimelineMode.Overlay(overlay.id, OVERLAY_END)
                else -> TimelineMode.Overlay(overlay.id, OVERLAY_BODY)
            }
        }
        return TimelineMode.Scrub
    }

    fun handleTap(p: Offset, w: Float) {
        val tappedMs = (scrollMs + p.x / pps * 1000.0).toLong().coerceIn(0L, totalMs())
        // Overlay lane tap → select that overlay.
        for ((index, overlay) in model.overlays.take(3).withIndex()) {
            val top = laneTop(index)
            if (p.y < top || p.y > top + laneH) continue
            val x0 = xFor(overlay.startMs)
            val x1 = xFor(minOf(overlay.endMs, totalMs()))
            if (p.x in (x0 - 8f)..(x1 + 8f)) {
                model.selectOverlay(overlay.id)
                onSeek(tappedMs.coerceIn(overlay.startMs, minOf(overlay.endMs, totalMs())))
                return
            }
        }
        onSeek(tappedMs)
        if (p.y > rulerH + 2f && p.y < videoTop + videoH) {
            val clip = model.clips.firstOrNull { tappedMs >= it.startMs && tappedMs < it.endMs }
            if (clip != null) model.select(clip.id) else model.deselectAll()
        } else {
            model.deselectAll()
        }
    }

    LaunchedEffect(widthPx) {
        if (widthPx > 1f && playheadX <= 0f) {
            playheadX = widthPx / 2f
            follow(model.timecodeMs)
        }
    }
    // Playback / external seeks: keep the playhead pinned over the current time.
    LaunchedEffect(model.timecodeMs, dragging, widthPx, pps) {
        if (!dragging) follow(model.timecodeMs)
    }

    Canvas(
        modifier
            .fillMaxWidth()
            .height(heightDp)
            .background(CS.BG)
            .onSizeChanged { widthPx = it.width.toFloat() }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val w = widthPx
                    if (w <= 1f) return@awaitEachGesture

                    val mode = hitTest(down.position, w)
                    val startOverlay = if (mode is TimelineMode.Overlay) {
                        model.overlays.firstOrNull { it.id == mode.id }
                    } else null
                    val startOverlayEnd = startOverlay?.let {
                        it.durationMs?.let { d -> it.startMs + d } ?: model.totalMs()
                    } ?: 0L
                    // No snapshot here: updateOverlayLive() opens the undo
                    // batch on the first real change, so a tap isn't a no-op
                    // undo step.

                    dragging = true
                    var dxTotal = 0f
                    var moved = 0f

                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        val pan = event.calculatePan()
                        val zoom = event.calculateZoom()
                        dxTotal += pan.x
                        moved += abs(pan.x) + abs(pan.y)

                        if (pressed.size >= 2) {
                            // Pinch zoom, anchored on the playhead.
                            val anchorX = if (playheadX <= 0f) w / 2f else playheadX
                            val anchorMs = scrollMs + anchorX / pps * 1000.0
                            val nextPps = (pps * zoom).coerceIn(12f, 220f)
                            if (nextPps != pps) {
                                pps = nextPps
                                scrollMs = clampScroll(anchorMs - anchorX / pps * 1000.0)
                            }
                            // Two-finger pan scrolls too.
                            scrollMs = clampScroll(scrollMs - pan.x / pps * 1000.0)
                            event.changes.forEach { it.consume() }
                            continue
                        }

                        when (mode) {
                            TimelineMode.Playhead -> {
                                playheadX = (playheadX + pan.x).coerceIn(8f, max(8f, w - 8f))
                                onSeek((scrollMs + playheadX / pps * 1000.0).toLong().coerceIn(0L, totalMs()))
                            }
                            TimelineMode.Scrub -> {
                                scrollMs = clampScroll(scrollMs - pan.x / pps * 1000.0)
                                val t = (scrollMs + playheadX / pps * 1000.0).toLong()
                                onSeek(t.coerceIn(0L, totalMs()))
                            }
                            is TimelineMode.Overlay -> {
                                val deltaMs = (dxTotal / pps * 1000.0).toLong()
                                if (startOverlay != null && deltaMs != 0L) {
                                    when (mode.kind) {
                                        OVERLAY_BODY -> {
                                            val length = (startOverlayEnd - startOverlay.startMs).coerceAtLeast(100L)
                                            val maxStart = (model.totalMs() - length).coerceAtLeast(0L)
                                            model.updateOverlayLive(
                                                startOverlay.copy(
                                                    startMs = (startOverlay.startMs + deltaMs).coerceIn(0L, maxStart)
                                                )
                                            )
                                        }
                                        OVERLAY_START -> model.trimOverlayStart(startOverlay, startOverlay.startMs + deltaMs)
                                        OVERLAY_END -> model.trimOverlayEnd(startOverlay, startOverlayEnd + deltaMs)
                                    }
                                }
                            }
                        }
                        event.changes.forEach { it.consume() }
                    }

                    if (mode is TimelineMode.Overlay) model.endOverlayDrag()
                    if (moved < 10f) handleTap(down.position, w) else follow(model.timecodeMs)
                    dragging = false
                }
            }
    ) {
        val w = size.width
        val h = size.height
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = android.graphics.Color.parseColor("#9B9BA5")
            textSize = labelPx
            typeface = Typeface.MONOSPACE
        }

        // ── Ruler ──────────────────────────────────────────────────────────
        drawRect(color = CS.BG, topLeft = Offset.Zero, size = Size(w, h))
        val steps = listOf(0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0)
        val step = steps.firstOrNull { it * pps >= 44.0 } ?: 60.0
        var tick = floor(scrollMs / 1000.0 / step) * step
        val endSec = scrollMs / 1000.0 + w / pps
        while (tick <= endSec) {
            val px = ((tick * 1000.0 - scrollMs) / 1000.0 * pps).toFloat()
            if (px >= -20f && px <= w + 20f) {
                drawLine(CS.Hairline, Offset(px, rulerH - 6f), Offset(px, rulerH), strokeWidth = 1f)
                val total = tick.toInt()
                val label = "%d:%02d".format(total / 60, total % 60)
                drawContext.canvas.nativeCanvas.drawText(label, px + 3f, rulerH - 4f, paint)
            }
            tick += step
        }

        // ── Video row ──────────────────────────────────────────────────────
        drawRoundRect(
            color = CS.Surface,
            topLeft = Offset(0f, videoTop),
            size = Size(w, videoH),
            cornerRadius = CornerRadius(6.dp.toPx()),
        )
        val blockCorner = CornerRadius(5.dp.toPx())
        model.clips.forEachIndexed { index, clip ->
            val x0 = xFor(clip.startMs)
            val x1 = xFor(clip.endMs)
            if (x1 > -20f && x0 < w + 20f) {
                val bw = max(6f, x1 - x0 - 2f)
                val selected = clip.id == model.selectedClipId
                val seed = CS.SeedPalette[index % CS.SeedPalette.size]
                drawRoundRect(
                    color = seed.copy(alpha = if (selected) 0.55f else 0.32f),
                    topLeft = Offset(x0 + 1f, videoTop + 2f),
                    size = Size(bw, videoH - 4f),
                    cornerRadius = blockCorner,
                )
                drawRoundRect(
                    color = if (selected) CS.Selection else CS.Hairline,
                    topLeft = Offset(x0 + 1f, videoTop + 2f),
                    size = Size(bw, videoH - 4f),
                    cornerRadius = blockCorner,
                    style = Stroke(width = if (selected) 2.5f else 1f),
                )
                if (bw > 40f) {
                    paint.color = android.graphics.Color.WHITE
                    drawContext.canvas.nativeCanvas.drawText(
                        clip.durationText(), x0 + 5f, videoTop + videoH - 6f, paint
                    )
                }
                if (index > 0 && clip.transitionIn != CSTransition.NONE) {
                    drawCircle(
                        color = CS.Accent,
                        radius = 5f,
                        center = Offset(x0 + 1f, videoTop + 8f),
                    )
                }
                if (selected) {
                    drawRoundRect(
                        color = CS.Selection,
                        topLeft = Offset(x0 + 1f, videoTop + 3f),
                        size = Size(8f, videoH - 6f),
                        cornerRadius = CornerRadius(3f),
                    )
                    drawRoundRect(
                        color = CS.Selection,
                        topLeft = Offset(x0 + bw - 7f, videoTop + 3f),
                        size = Size(8f, videoH - 6f),
                        cornerRadius = CornerRadius(3f),
                    )
                }
            }
        }

        // ── Overlay lanes ──────────────────────────────────────────────────
        model.overlays.take(3).forEachIndexed { index, overlay ->
            val top = laneTop(index)
            drawRoundRect(
                color = CS.Surface.copy(alpha = 0.6f),
                topLeft = Offset(0f, top),
                size = Size(w, laneH),
                cornerRadius = CornerRadius(4.dp.toPx()),
            )
            val x0 = xFor(overlay.startMs)
            val x1 = xFor(minOf(overlay.endMs, totalMs()))
            if (x1 > -20f && x0 < w + 20f) {
                val bw = max(10f, x1 - x0)
                val selected = overlay.id == model.selectedOverlayId
                val tint = if (overlay.text != null) CS.Accent else CS.AccentViolet
                drawRoundRect(
                    color = tint.copy(alpha = if (selected) 0.9f else 0.55f),
                    topLeft = Offset(x0, top + 1f),
                    size = Size(bw, laneH - 2f),
                    cornerRadius = CornerRadius(4.dp.toPx()),
                )
                if (selected) {
                    drawRoundRect(
                        color = CS.Selection,
                        topLeft = Offset(x0, top + 1f),
                        size = Size(bw, laneH - 2f),
                        cornerRadius = CornerRadius(4.dp.toPx()),
                        style = Stroke(width = 2f),
                    )
                    drawRoundRect(
                        color = CS.Selection,
                        topLeft = Offset(x0, top + 2f),
                        size = Size(7f, laneH - 4f),
                        cornerRadius = CornerRadius(3f),
                    )
                    drawRoundRect(
                        color = CS.Selection,
                        topLeft = Offset(x0 + bw - 7f, top + 2f),
                        size = Size(7f, laneH - 4f),
                        cornerRadius = CornerRadius(3f),
                    )
                }
                if (bw > 30f) {
                    paint.color = if (selected) android.graphics.Color.BLACK else android.graphics.Color.WHITE
                    val name = overlay.text ?: "Sticker"
                    drawContext.canvas.nativeCanvas.drawText(name, x0 + 5f, top + laneH - 5f, paint)
                }
            }
        }

        // ── Playhead ───────────────────────────────────────────────────────
        val px = playheadX.coerceIn(0f, w)
        drawLine(CS.Accent, Offset(px, 0f), Offset(px, h), strokeWidth = 2.5f)
        val flag = Path().apply {
            moveTo(px - 9f, 0f)
            lineTo(px + 9f, 0f)
            lineTo(px + 9f, 7f)
            lineTo(px + 2f, 13f)
            lineTo(px - 2f, 13f)
            lineTo(px - 9f, 7f)
            close()
        }
        drawPath(flag, CS.Accent)
    }
}

private sealed class TimelineMode {
    object Playhead : TimelineMode()
    object Scrub : TimelineMode()
    data class Overlay(val id: Long, val kind: Int) : TimelineMode()
}

private const val OVERLAY_BODY = 0
private const val OVERLAY_START = 1
private const val OVERLAY_END = 2
