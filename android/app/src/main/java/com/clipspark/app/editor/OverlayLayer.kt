package com.clipspark.app.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateRotation
import androidx.compose.foundation.gestures.calculatePan
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipspark.app.designsystem.CS
import kotlin.math.abs
import kotlin.math.max

/**
 * Canvas overlay layer: renders every overlay visible at the playhead, in
 * list order (z-order), and owns its own move / pinch-resize / rotate gestures.
 *
 * Type is authored against a 400 px-tall reference frame (`fontSize`), then
 * scaled by the live canvas height — the export uses the identical ratio.
 */
@Composable
fun OverlayLayer(model: EditorViewModel, modifier: Modifier = Modifier) {
    BoxWithConstraints(modifier) {
        val w = constraints.maxWidth.toFloat()
        val h = constraints.maxHeight.toFloat()
        if (w <= 0f || h <= 0f) return@BoxWithConstraints
        val typeScale = h / 400f
        model.visibleOverlaysAt(model.timecodeMs).forEach { overlay ->
            OverlayItemView(model, overlay, w, h, typeScale)
        }
    }
}

@Composable
private fun OverlayItemView(
    model: EditorViewModel,
    overlay: EditorOverlay,
    canvasW: Float,
    canvasH: Float,
    typeScale: Float,
) {
    val selected = overlay.id == model.selectedOverlayId

    Box(
        Modifier
            .graphicsLayer {
                translationX = overlay.x * canvasW - size.width / 2f
                translationY = overlay.y * canvasH - size.height / 2f
                scaleX = overlay.scale
                scaleY = overlay.scale
                rotationZ = overlay.rotation
                alpha = overlay.opacity.coerceIn(0f, 1f)
            }
            .drawBehind {
                if (selected) {
                    drawRoundRect(
                        color = CS.Selection,
                        cornerRadius = CornerRadius(8f),
                        style = Stroke(
                            width = 2.5f,
                            pathEffect = PathEffect.dashPathEffect(floatArrayOf(12f, 8f)),
                        ),
                    )
                }
            }
            .pointerInput(overlay.id) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // Claim the gesture so the canvas tap-to-play handler below
                    // doesn't also fire and clear the selection.
                    down.consume()
                    var changed = false
                    var moved = 0f
                    while (true) {
                        val event = awaitPointerEvent()
                        val pressed = event.changes.filter { it.pressed }
                        if (pressed.isEmpty()) break
                        val pan = event.calculatePan()
                        val zoom = event.calculateZoom()
                        val rotation = event.calculateRotation()
                        moved += abs(pan.x) + abs(pan.y) + abs(rotation)

                        val delta = pan.x != 0f || pan.y != 0f || zoom != 1f || rotation != 0f
                        if (delta) {
                            changed = true
                            // updateOverlayLive() opens the undo batch on the
                            // first real change; a simple tap never does.
                            model.selectOverlay(overlay.id)
                            val live = model.overlays.firstOrNull { it.id == overlay.id }
                            if (live != null) {
                                model.updateOverlayLive(
                                    live.copy(
                                        x = (live.x + pan.x / canvasW).coerceIn(0.02f, 0.98f),
                                        y = (live.y + pan.y / canvasH).coerceIn(0.02f, 0.98f),
                                        scale = (live.scale * zoom).coerceIn(0.15f, 5f),
                                        rotation = live.rotation + rotation,
                                    )
                                )
                            }
                        }
                        event.changes.forEach { it.consume() }
                    }
                    if (changed) model.endOverlayDrag()
                    if (moved < 10f) model.selectOverlay(overlay.id)
                }
            }
    ) {
        val contentModifier = Modifier.padding(8.dp)
        when {
            overlay.text != null -> Text(
                text = overlay.text,
                color = Color(overlay.colorArgb),
                fontSize = (max(8f, overlay.fontSize * typeScale)).sp,
                fontWeight = FontWeight.Bold,
                modifier = contentModifier,
            )
            overlay.sticker != null -> Text(
                text = overlay.sticker,
                fontSize = (max(10f, overlay.fontSize * typeScale)).sp,
                modifier = contentModifier,
            )
        }

        if (selected) {
            Box(
                Modifier
                    .align(Alignment.TopStart)
                    .padding(2.dp)
                    .size(18.dp)
                    .background(CS.Danger, CircleShape)
                    .clickable { model.deleteOverlay(overlay.id) },
                contentAlignment = Alignment.Center,
            ) {
                Text("✕", color = Color.White, fontSize = 9.sp)
            }
        }
    }
}
