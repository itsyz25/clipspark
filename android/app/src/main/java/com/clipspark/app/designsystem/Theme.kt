package com.clipspark.app.designsystem

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// ClipSpark design tokens — mirrors iOS Tokens.swift 1:1.

object CS {
    val BG = Color(0xFF0B0B0F)
    val Surface = Color(0xFF16161D)
    val SurfaceHigh = Color(0xFF1E1E27)
    val Hairline = Color(0xFF2A2A33)
    val TextPrimary = Color(0xFFFFFFFF)
    val TextSecondary = Color(0xFF9B9BA5)

    val Accent = Color(0xFF00E0C6)
    val AccentViolet = Color(0xFF7C5CFF)
    val Selection = Color(0xFFFFD60A)
    val Danger = Color(0xFFFF453A)
    val Success = Color(0xFF32D74B)

    val SeedPalette = listOf(Accent, AccentViolet, Selection)
}

private val DarkScheme = darkColorScheme(
    background = CS.BG,
    surface = CS.Surface,
    primary = CS.Accent,
    onPrimary = Color.Black,
    secondary = CS.AccentViolet,
    error = CS.Danger,
)

@Composable
fun ClipSparkTheme(content: @Composable () -> Unit) {
    // Dark-first per design spec
    MaterialTheme(colorScheme = DarkScheme, content = content)
}
