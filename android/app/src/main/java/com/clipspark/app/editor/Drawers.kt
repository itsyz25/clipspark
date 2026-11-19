package com.clipspark.app.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.clipspark.app.designsystem.*

/** Tool drawers (mirrors iOS MediaDrawers.swift) — all offline. */

@Composable
fun DrawerShell(title: String, onClose: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().background(CS.SurfaceHigh).padding(bottom = 24.dp)) {
        CSGrabber()
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(title, fontSize = 17.sp, color = CS.TextPrimary)
            Spacer(Modifier.weight(1f))
            Text("✕", color = CS.TextSecondary, modifier = Modifier.clickable { onClose() })
        }
        content()
    }
}

@Composable
fun TextDrawer(model: EditorViewModel, onClose: () -> Unit) {
    var draft by remember { mutableStateOf("") }
    DrawerShell("Text", onClose) {
        Text("Type text, tap Add.", fontSize = 12.sp, color = CS.TextSecondary,
            modifier = Modifier.padding(horizontal = 16.dp))
        BasicTextField(
            value = draft,
            onValueChange = { draft = it },
            textStyle = androidx.compose.ui.text.TextStyle(
                color = CS.TextPrimary, fontSize = 15.sp
            ),
            modifier = Modifier
                .padding(16.dp)
                .fillMaxWidth()
                .background(CS.Surface, RoundedCornerShape(10.dp))
                .padding(12.dp)
        )
        Row(Modifier.padding(horizontal = 16.dp)) {
            CSPrimaryButton("Add", CSIcons.Text) {
                if (draft.isNotBlank()) { model.addText(draft.trim()); draft = "" }
            }
        }
    }
}

@Composable
fun StickerDrawer(model: EditorViewModel, onClose: () -> Unit) {
    DrawerShell("Stickers", onClose) {
        LazyRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(EditorViewModel.stickerCatalog) { (symbol, label) ->
                Column(
                    Modifier
                        .clickable { model.addSticker(symbol) }
                        .background(CS.Surface, RoundedCornerShape(12.dp))
                        .padding(12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(symbol, fontSize = 20.sp)
                    Text(label, fontSize = 10.sp, color = CS.TextSecondary)
                }
            }
        }
        Text("Stickers are baked into the export too — they render on the canvas here and in the saved video.",
            fontSize = 11.sp, color = CS.TextSecondary,
            modifier = Modifier.padding(16.dp))
    }
}

@Composable
fun FilterDrawer(model: EditorViewModel, onClose: () -> Unit) {
    DrawerShell("Filters & Adjust", onClose) {
        Column(Modifier.padding(horizontal = 16.dp)) {
            LabeledSlider("Brightness", model.look.brightness, -0.2f..0.2f) {
                model.updateLookLive { l -> l.copy(brightness = it) }
            }
            LabeledSlider("Contrast", model.look.contrast, 0.5f..1.5f) {
                model.updateLookLive { l -> l.copy(contrast = it) }
            }
            LabeledSlider("Saturation", model.look.saturation, 0f..2f) {
                model.updateLookLive { l -> l.copy(saturation = it) }
            }
            LabeledSlider("Motion blur", model.look.motionBlur, 0f..1f) {
                model.updateLookLive { l -> l.copy(motionBlur = it) }
            }
            if (model.look.motionBlur > 0.005f) {
                LabeledSlider("Blur angle", model.look.motionBlurAngle, 0f..180f) {
                    model.updateLookLive { l -> l.copy(motionBlurAngle = it) }
                }
            }
            Text("GPU effects shared with the exporter: what you see is what gets encoded.",
                fontSize = 11.sp, color = CS.TextSecondary)
        }
    }
}

@Composable
fun TransitionsDrawer(model: EditorViewModel, onClose: () -> Unit) {
    DrawerShell("Transitions", onClose) {
        val selectedId = model.selectedClipId
        if (selectedId == null || model.clips.indexOfFirst { it.id == selectedId } == 0) {
            Text("Select a clip (not the first) to set its incoming transition.",
                fontSize = 12.sp, color = CS.TextSecondary, modifier = Modifier.padding(16.dp))
        } else {
            LazyRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(CSTransition.all) { type ->
                    val current = model.clips.firstOrNull { it.id == selectedId }?.transitionIn
                    CSToolChip(CSIcons.Transitions, type.label, selected = current == type) {
                        model.setTransition(selectedId, type)
                    }
                }
            }
        }
    }
}

@Composable
fun AudioDrawer(model: EditorViewModel, onClose: () -> Unit) {
    DrawerShell("Audio", onClose) {
        val clip = model.clips.firstOrNull { it.id == model.selectedClipId }
        if (clip == null) {
            Text("Select a clip to adjust its sound.", fontSize = 12.sp, color = CS.TextSecondary,
                modifier = Modifier.padding(16.dp))
        } else {
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(CSIcons.Volume, null, tint = CS.Accent,
                    modifier = Modifier.clickable { model.mutate { it.firstOrNull { c -> c.id == clip.id }?.muted = !clip.muted } })
                Text("Clip volume", fontSize = 12.sp, color = CS.TextSecondary)
                Spacer(8.dp)
            }
            Row(Modifier.padding(horizontal = 16.dp)) {
                var volume by remember(clip.id) { mutableStateOf(clip.volume) }
                Slider(value = volume, onValueChange = {
                    volume = it
                    model.mutate { c -> c.firstOrNull { x -> x.id == clip.id }?.volume = it }
                }, valueRange = 0f..2f, modifier = Modifier.weight(1f))
                Text("${(volume * 100).toInt()}%", fontSize = 11.sp, color = CS.Accent)
            }
        }
    }
}

@Composable
fun ClipInspector(model: EditorViewModel) {
    val clip = model.clips.firstOrNull { it.id == model.selectedClipId } ?: return
    DrawerShell("Clip", {}) {
        Row(Modifier.padding(horizontal = 8.dp), horizontalArrangement = Arrangement.SpaceEvenly) {
            InspectorButton(CSIcons.Split, "Split") { model.splitAt(model.timecodeMs) }
            InspectorButton(CSIcons.Duplicate, "Duplicate") {
                model.mutate { it.add(clip.copy(id = System.nanoTime())) }
            }
            InspectorButton(CSIcons.Undo, "Move ←") { model.move(clip.id, -1) }
            InspectorButton(CSIcons.Redo, "Move →") { model.move(clip.id, 1) }
            InspectorButton(CSIcons.Delete, "Delete", CS.Danger) { model.delete(clip.id) }
        }
        var speed by remember(clip.id) { mutableStateOf(clip.speed.toFloat()) }
        Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text("Speed", fontSize = 12.sp, color = CS.TextSecondary)
            Slider(value = speed, onValueChange = { speed = it }, valueRange = 0.25f..4f,
                onValueChangeFinished = { model.setSpeed(clip.id, speed.toDouble()) },
                modifier = Modifier.weight(1f))
            Text("%.2f×".format(speed), fontSize = 11.sp, color = CS.Accent)
        }
    }
}

@Composable
private fun InspectorButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, tint: Color = CS.TextPrimary, onClick: () -> Unit) {
    Column(Modifier.clickable { onClick() }.padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(icon, null, tint = tint)
        Text(label, fontSize = 12.sp, color = CS.TextSecondary)
    }
}

@Composable
private fun LabeledSlider(label: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 12.sp, color = CS.TextSecondary, modifier = Modifier.width(90.dp))
        Slider(value = value, onValueChange = onChange, valueRange = range, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun Spacer(width: androidx.compose.ui.unit.Dp) =
    androidx.compose.foundation.layout.Spacer(Modifier.width(width))


// MARK: - Keyframe drawer (mirrors iOS KeyframeDrawer.swift)

@Composable
fun OverlayDrawer(model: EditorViewModel, onClose: () -> Unit) {
    val overlay = model.selectedOverlay
    DrawerShell("Overlay", onClose) {
        if (overlay == null) {
            Text(
                "Select a text or sticker on the canvas or in the timeline.",
                fontSize = 12.sp, color = CS.TextSecondary,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
            LazyRow(
                Modifier.padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                items(model.overlays.asReversed()) { o ->
                    Text(
                        o.text ?: "Sticker", fontSize = 12.sp,
                        color = if (o.id == model.selectedOverlayId) CS.BG else CS.TextPrimary,
                        modifier = Modifier
                            .clickable { model.selectOverlay(o.id) }
                            .background(
                                if (o.id == model.selectedOverlayId) CS.Accent else CS.Surface,
                                RoundedCornerShape(20.dp)
                            )
                            .padding(horizontal = 12.dp, vertical = 8.dp),
                    )
                }
            }
            return@DrawerShell
        }

        Column(Modifier.padding(vertical = 4.dp)) {
            if (overlay.text != null) {
                var draft by remember(overlay.id) { mutableStateOf(overlay.text ?: "") }
                Row(
                    Modifier.padding(horizontal = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    BasicTextField(
                        value = draft,
                        onValueChange = { draft = it },
                        textStyle = androidx.compose.ui.text.TextStyle(
                            color = CS.TextPrimary, fontSize = 15.sp
                        ),
                        modifier = Modifier
                            .weight(1f)
                            .background(CS.Surface, RoundedCornerShape(10.dp))
                            .padding(12.dp),
                    )
                    Spacer(Modifier.width(8.dp))
                    CSPrimaryButton("Apply") {
                        model.updateOverlay(overlay.copy(text = draft))
                    }
                }
                Spacer(Modifier.height(8.dp))
            }

            // Colour swatches
            val swatches = listOf(
                0xFFFFFFFF, 0xFF000000, 0xFF00E0C6, 0xFFFFD60A,
                0xFFFF453A, 0xFF0A84FF, 0xFFFFD60A, 0xFF32D74B,
            )
            Row(
                Modifier.padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                swatches.forEach { argb ->
                    Box(
                        Modifier
                            .size(24.dp)
                            .background(Color(argb), RoundedCornerShape(12.dp))
                            .clickable { model.updateOverlay(overlay.copy(colorArgb = argb)) }
                    )
                }
            }
            Spacer(Modifier.height(8.dp))

            OverlaySlider(
                "Size", overlay.fontSize, 14f..140f,
                onChange = { v -> model.updateOverlayLive(overlay.copy(fontSize = v)) },
                onFinished = { model.endOverlayDrag() },
            )
            OverlaySlider(
                "Opacity", overlay.opacity, 0.1f..1f,
                onChange = { v -> model.updateOverlayLive(overlay.copy(opacity = v)) },
                onFinished = { model.endOverlayDrag() },
            )
            OverlaySlider(
                "Rotation", overlay.rotation, -180f..180f,
                onChange = { v -> model.updateOverlayLive(overlay.copy(rotation = v)) },
                onFinished = { model.endOverlayDrag() },
            )

            Text(
                "Shown %.1fs – %.1fs".format(
                    overlay.startMs / 1000.0,
                    minOf(overlay.endMs, model.totalMs().coerceAtLeast(1L)) / 1000.0
                ),
                fontSize = 11.sp, color = CS.TextSecondary,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
            )

            Row(
                Modifier.padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                DrawerAction("Start here") { model.overlayStartAtPlayhead(overlay) }
                DrawerAction("End here") { model.overlayEndAtPlayhead(overlay) }
                DrawerAction("Layer +") { model.bringOverlayForward(overlay.id) }
                DrawerAction("Layer -") { model.sendOverlayBackward(overlay.id) }
            }
            Row(
                Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                DrawerAction("Duplicate") { model.duplicateOverlay(overlay) }
                DrawerAction("Delete", danger = true) { model.deleteOverlay(overlay.id) }
            }
        }
    }
}

@Composable
private fun OverlaySlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
    onFinished: () -> Unit,
) {
    Row(
        Modifier.padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, fontSize = 12.sp, color = CS.TextSecondary, modifier = Modifier.width(66.dp))
        Slider(
            value = value,
            onValueChange = onChange,
            onValueChangeFinished = onFinished,
            valueRange = range,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun DrawerAction(label: String, danger: Boolean = false, action: () -> Unit) {
    Text(
        label, fontSize = 12.sp,
        color = if (danger) CS.Danger else CS.TextPrimary,
        modifier = Modifier
            .clickable { action() }
            .background(CS.Surface, RoundedCornerShape(20.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
    )
}

// MARK: - Keyframe drawer (mirrors iOS KeyframeDrawer.swift)

private enum class KeyframeVariationChoice(val label: String, val make: () -> KeyframeVariation) {
    HOLD("Hold", { KeyframeVariation.Hold }),
    LINEAR("Linear", { KeyframeVariation.Linear }),
    EASE_IN("Ease In", { KeyframeVariation.Preset(EasingPreset.EASE_IN) }),
    EASE_OUT("Ease Out", { KeyframeVariation.Preset(EasingPreset.EASE_OUT) }),
    EASE_IN_OUT("Ease In/Out", { KeyframeVariation.Preset(EasingPreset.EASE_IN_OUT) }),
    OVERSHOOT("Overshoot", { KeyframeVariation.Preset(EasingPreset.OVERSHOOT) }),
    BOUNCE("Bounce", { KeyframeVariation.Preset(EasingPreset.BOUNCE) }),
    ELASTIC("Elastic", { KeyframeVariation.Preset(EasingPreset.ELASTIC) }),
    ANTICIPATION("Anticipation", { KeyframeVariation.Preset(EasingPreset.ANTICIPATION) }),
    SMOOTH("Smooth", { KeyframeVariation.Preset(EasingPreset.SMOOTH) }),
    BEZIER("Custom Curve", { KeyframeVariation.Bezier() }),
    SPRING("Spring", { KeyframeVariation.Spring() });
}

/** Property's unkeyed value, from the clip / global look. */
private fun KeyframeProperty.staticBase(clip: ClipSegment): Double = when (this) {
    KeyframeProperty.SCALE -> 1.0
    KeyframeProperty.POS_X, KeyframeProperty.POS_Y -> 0.0
    KeyframeProperty.ROTATION -> 0.0
    KeyframeProperty.OPACITY -> 1.0
    KeyframeProperty.VOLUME -> (if (clip.muted) 0.0 else clip.volume.toDouble())
    KeyframeProperty.BRIGHTNESS, KeyframeProperty.CONTRAST, KeyframeProperty.SATURATION -> default
}

@Composable
fun KeyframeDrawer(model: EditorViewModel, onClose: () -> Unit) {
    val clip = model.clips.firstOrNull { it.id == model.selectedClipId }
    var property by remember { mutableStateOf(KeyframeProperty.SCALE) }
    var selectedKfId by remember { mutableStateOf<Long?>(null) }
    var graphSize by remember { mutableStateOf(IntSize.Zero) }

    DrawerShell("Keyframes", onClose) {
        if (clip == null) {
            Text(
                "Select a clip on the timeline to keyframe it.",
                fontSize = 12.sp, color = CS.TextSecondary,
                modifier = Modifier.padding(16.dp),
            )
            return@DrawerShell
        }

        // Property chips
        LazyRow(
            Modifier.padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            items(KeyframeProperty.entries.toList()) { p ->
                Text(
                    p.label,
                    fontSize = 11.sp,
                    color = if (p == property) CS.BG else CS.TextPrimary,
                    modifier = Modifier
                        .clickable { property = p; selectedKfId = null }
                        .background(if (p == property) CS.Accent else CS.Surface, RoundedCornerShape(20.dp))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                )
            }
        }

        val kfs = model.keyframesOf(clip.id, property)

        // Graph: tap a point to select, tap empty space to add, drag to move.
        Box(
            Modifier
                .padding(16.dp)
                .fillMaxWidth()
                .height(200.dp)
                .background(CS.Surface, RoundedCornerShape(10.dp))
                .onSizeChanged { graphSize = it }
                .pointerInput(property, kfs.size, selectedKfId) {
                    detectTapGestures(
                        onTap = { offset ->
                            val w = size.width.toFloat()
                            val h = size.height.toFloat()
                            if (w <= 0f || h <= 0f) return@detectTapGestures
                            val span = clip.timelineDurationMs.coerceAtLeast(1L)
                            val near = kfs.firstOrNull { kf ->
                                val kx = (kf.timeMs.toFloat() / span.toFloat()) * w
                                val frac = ((kf.value - property.min) / (property.max - property.min)).toFloat()
                                val ky = h * (1 - frac)
                                val dx = kx - offset.x
                                val dy = ky - offset.y
                                dx * dx + dy * dy < 48f * 48f
                            }
                            if (near != null) {
                                selectedKfId = near.id
                            } else {
                                val t = ((offset.x / w) * span.toFloat()).toLong().coerceIn(0L, span)
                                val v = property.max - (offset.y / h).toDouble() * (property.max - property.min)
                                model.addKeyframe(clip.id, property, v, t)
                                selectedKfId = null
                            }
                        },
                    )
                }
                .pointerInput(property, kfs.size, selectedKfId) {
                    detectDragGestures(
                        onDragStart = { if (selectedKfId != null) model.beginKeyframeDrag() },
                        onDrag = { change, _ ->
                            val kfId = selectedKfId ?: return@detectDragGestures
                            val w = size.width.toFloat()
                            val h = size.height.toFloat()
                            if (w <= 0f || h <= 0f) return@detectDragGestures
                            val span = clip.timelineDurationMs.coerceAtLeast(1L)
                            val kf = kfs.firstOrNull { it.id == kfId } ?: return@detectDragGestures
                            val t = ((change.position.x / w) * span.toFloat()).toLong().coerceIn(0L, span)
                            val v = property.max - (change.position.y / h).toDouble() * (property.max - property.min)
                            model.updateKeyframeLive(clip.id, kf.copy(timeMs = t, value = property.clamp(v)))
                        },
                        onDragEnd = { model.endKeyframeDrag() },
                        onDragCancel = { model.endKeyframeDrag() },
                    )
                },
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val w = size.width
                val h = size.height
                val span = clip.timelineDurationMs.coerceAtLeast(1L)
                val staticBase = property.staticBase(clip)

                fun xPos(ms: Long): Float = (ms.toFloat() / span.toFloat()) * w
                fun yPos(v: Double): Float {
                    val frac = ((v - property.min) / (property.max - property.min)).coerceIn(-0.25, 1.25)
                    return h * (1 - frac.toFloat())
                }

                // Curve sampled from the real evaluator
                var prev: Offset? = null
                var x = 0f
                while (x <= w) {
                    val t = (x / w * span.toFloat()).toLong()
                    val v = KeyframeEvaluator.evaluate(clip.keyframes, property, staticBase, t)
                    val p = Offset(x, yPos(v))
                    prev?.let { drawLine(CS.Accent, it, p, strokeWidth = 4f) }
                    prev = p
                    x += 3f
                }
                kfs.forEach { kf ->
                    drawCircle(
                        if (kf.id == selectedKfId) CS.Selection else CS.Accent,
                        radius = 9f,
                        center = Offset(xPos(kf.timeMs), yPos(kf.value)),
                    )
                }
                // playhead
                val px = xPos((model.timecodeMs - clip.startMs).coerceIn(0L, span))
                drawLine(
                    CS.TextSecondary.copy(alpha = 0.6f),
                    Offset(px, 0f),
                    Offset(px, h),
                    strokeWidth = 2f,
                )
            }
        }

        // Add at playhead + clear
        Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(
                "◆ Add here", fontSize = 12.sp, color = CS.BG,
                modifier = Modifier
                    .clickable {
                        val t = (model.timecodeMs - clip.startMs).coerceIn(0L, clip.timelineDurationMs)
                        val v = KeyframeEvaluator.evaluate(
                            clip.keyframes, property, property.staticBase(clip), t,
                        )
                        model.addKeyframe(clip.id, property, v, t)
                    }
                    .background(CS.Accent, RoundedCornerShape(20.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
            if (kfs.isNotEmpty()) {
                Text(
                    "Remove all", fontSize = 12.sp, color = CS.Danger,
                    modifier = Modifier
                        .clickable { model.removeKeyframes(clip.id, property); selectedKfId = null }
                        .background(CS.Surface, RoundedCornerShape(20.dp))
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                )
            }
        }

        // Inspector for the selected keyframe
        val kf = kfs.firstOrNull { it.id == selectedKfId }
        if (kf != null) {
            Column(
                Modifier
                    .padding(16.dp)
                    .fillMaxWidth()
                    .background(CS.Surface, RoundedCornerShape(10.dp))
                    .padding(12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "Keyframe @ ${"%.2f".format(kf.timeMs / 1000.0)}s  ${property.format(kf.value)}",
                        fontSize = 13.sp, color = CS.TextPrimary,
                    )
                    Spacer(Modifier.weight(1f))
                    Text(
                        "Delete", fontSize = 12.sp, color = CS.Danger,
                        modifier = Modifier.clickable { model.removeKeyframe(clip.id, kf.id); selectedKfId = null },
                    )
                }
                Spacer(Modifier.height(8.dp))

                // Value slider (one undo step per gesture)
                var valueDraft by remember(kf.id) { mutableStateOf(kf.value) }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(property.format(valueDraft), fontSize = 11.sp, color = CS.TextSecondary)
                    Spacer(Modifier.width(8.dp))
                    Slider(
                        value = valueDraft.toFloat(),
                        onValueChange = {
                            valueDraft = it.toDouble()
                            model.ensureKeyframeUndo()
                            model.updateKeyframeLive(clip.id, kf.copy(value = valueDraft))
                        },
                        onValueChangeFinished = { model.endKeyframeDrag() },
                        valueRange = property.min.toFloat()..property.max.toFloat(),
                        modifier = Modifier.weight(1f),
                    )
                }

                // Variation chips
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(KeyframeVariationChoice.entries.toList()) { choice ->
                        val selected = choice.label == kf.variation.label
                        Text(
                            choice.label, fontSize = 11.sp,
                            color = if (selected) CS.BG else CS.TextPrimary,
                            modifier = Modifier
                                .clickable { model.updateKeyframe(clip.id, kf.copy(variation = choice.make())) }
                                .background(if (selected) CS.Accent else CS.Surface, RoundedCornerShape(16.dp))
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
                Spacer(Modifier.height(8.dp))

                // Per-variation params + shared custom settings
                when (val variation = kf.variation) {
                    is KeyframeVariation.Bezier -> {
                        kfSlider(model, "Point 1 X", variation.c1x, 0.0, 1.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(c1x = v)))
                        }
                        kfSlider(model, "Point 1 Y", variation.c1y, 0.0, 1.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(c1y = v)))
                        }
                        kfSlider(model, "Point 2 X", variation.c2x, 0.0, 1.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(c2x = v)))
                        }
                        kfSlider(model, "Point 2 Y", variation.c2y, 0.0, 1.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(c2y = v)))
                        }
                    }
                    is KeyframeVariation.Spring -> {
                        kfSlider(model, "Snappiness", variation.stiffness, 1.0, 30.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(stiffness = v)))
                        }
                        kfSlider(model, "Bounce", variation.damping, 0.05, 1.0) { v ->
                            model.updateKeyframeLive(clip.id, kf.copy(variation = variation.copy(damping = v)))
                        }
                    }
                    else -> {}
                }

                kfSlider(model, "Velocity blend", kf.settings.velocityInfluence, 0.0, 1.0) { v ->
                    model.updateKeyframeLive(clip.id, kf.copy(settings = kf.settings.copy(velocityInfluence = v)))
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Clamp to range", fontSize = 11.sp, color = CS.TextSecondary)
                    Spacer(Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = kf.settings.clamped,
                        onCheckedChange = { on ->
                            model.updateKeyframe(clip.id, kf.copy(settings = kf.settings.copy(clamped = on)))
                        },
                    )
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("Reversed", fontSize = 11.sp, color = CS.TextSecondary)
                    Spacer(Modifier.weight(1f))
                    androidx.compose.material3.Switch(
                        checked = kf.settings.reversed,
                        onCheckedChange = { on ->
                            model.updateKeyframe(clip.id, kf.copy(settings = kf.settings.copy(reversed = on)))
                        },
                    )
                }
            }
        } else {
            Text(
                "Tap the graph to add a keyframe. Tap a point to edit its curve and settings.",
                fontSize = 11.sp, color = CS.TextSecondary,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
}

/** Settings slider with live updates. */
@Composable
private fun kfSlider(
    model: EditorViewModel,
    label: String,
    value: Double,
    min: Double,
    max: Double,
    set: (Double) -> Unit,
) {
    var draft by remember(value) { mutableStateOf(value) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, fontSize = 11.sp, color = CS.TextSecondary, modifier = Modifier.width(90.dp))
        Spacer(Modifier.width(8.dp))
        Slider(
            value = draft.toFloat(),
            onValueChange = { draft = it.toDouble(); set(draft) },
            onValueChangeFinished = { model.endKeyframeDrag() },
            valueRange = min.toFloat()..max.toFloat(),
            modifier = Modifier.weight(1f),
        )
    }
}
