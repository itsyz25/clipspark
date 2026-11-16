package com.clipspark.app.editor

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
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
                if (draft.isNotBlank()) { model.addText(draft); draft = "" }
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
        Text("Stickers render in export in a later update; they preview on the clip block list today.",
            fontSize = 11.sp, color = CS.TextSecondary,
            modifier = Modifier.padding(16.dp))
    }
}

@Composable
fun FilterDrawer(model: EditorViewModel, onClose: () -> Unit) {
    DrawerShell("Filters & Adjust", onClose) {
        Column(Modifier.padding(horizontal = 16.dp).verticalScroll(rememberScrollState())) {
            LabeledSlider("Brightness", model.look.brightness, -0.2f..0.2f) { model.look.brightness = it }
            LabeledSlider("Contrast", model.look.contrast, 0.5f..1.5f) { model.look.contrast = it }
            LabeledSlider("Saturation", model.look.saturation, 0f..2f) { model.look.saturation = it }
            Text("Applied live on-device via Media3 GL effects.", fontSize = 11.sp, color = CS.TextSecondary)
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

private fun Spacer(width: androidx.compose.ui.unit.Dp) =
    androidx.compose.foundation.layout.Spacer(Modifier.width(width))
