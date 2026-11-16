package com.clipspark.app.templates

import com.clipspark.app.editor.CSTransition

/** Bundled offline templates — Kotlin mirror of ClipTemplate.swift. */

data class ClipTemplate(
    val name: String,
    val tagline: String,
    val uses: String,
    val speed: Double,
    val alternatingSpeed: Boolean,
    val transitionIn: CSTransition,
    val titleOverlay: String?,
) {
    fun speedAt(index: Int): Double =
        if (alternatingSpeed && index % 2 == 1) (speed / 2).coerceAtLeast(0.25) else speed

    companion object {
        val catalog = listOf(
            ClipTemplate("Beat drop", "Fast cuts, punchy rhythm", "2.1M",
                1.5, true, CSTransition.PUSH_LEFT, null),
            ClipTemplate("Vlog intro", "Soft open with a title", "890K",
                1.0, false, CSTransition.CROSSFADE, "My Story"),
            ClipTemplate("Product show", "Clean showcase dips", "610K",
                1.0, false, CSTransition.FADE_BLACK, "New Arrival"),
            ClipTemplate("Retro film", "Mono look, slow push", "480K",
                0.8, false, CSTransition.CROSSFADE, "memories"),
        )
    }
}
