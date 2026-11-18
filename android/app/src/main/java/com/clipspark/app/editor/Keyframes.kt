package com.clipspark.app.editor

import org.json.JSONObject

/**
 * Clip keyframes — Kotlin mirror of ClipSpark/Editor/Keyframes.swift.
 * A keyframe pins a property's value at a moment inside a clip (ms,
 * clip-relative). The "variation" decides how the value travels to the next
 * keyframe: hold / linear / easing presets / custom Bézier / spring, plus
 * shared custom settings (velocity blend, clamp, reversed).
 * 100% offline: every curve is math, no assets.
 */

enum class KeyframeProperty(val label: String, val min: Double, val max: Double, val default: Double) {
    SCALE("Scale", 0.1, 3.0, 1.0),
    POS_X("Position X", -1.0, 1.0, 0.0),
    POS_Y("Position Y", -1.0, 1.0, 0.0),
    ROTATION("Rotation", -180.0, 180.0, 0.0),
    OPACITY("Opacity", 0.0, 1.0, 1.0),
    VOLUME("Volume", 0.0, 2.0, 1.0),
    BRIGHTNESS("Brightness", -0.2, 0.2, 0.0),
    CONTRAST("Contrast", 0.5, 1.5, 1.0),
    SATURATION("Saturation", 0.0, 2.0, 1.0);

    fun clamp(v: Double): Double = v.coerceIn(min, max)
    fun format(v: Double): String =
        if (this == ROTATION) "%.0f°".format(v) else "%.2f".format(v)
}

enum class EasingPreset(val label: String) {
    LINEAR("Linear"), EASE_IN("Ease In"), EASE_OUT("Ease Out"), EASE_IN_OUT("Ease In Out"),
    OVERSHOOT("Overshoot"), BOUNCE("Bounce"), ELASTIC("Elastic"),
    ANTICIPATION("Anticipation"), SMOOTH("Smooth");

    /** Monotone curves stay in [0,1]; overshoot/elastic/bounce leave it by design. */
    fun value(tRaw: Double): Double {
        val t = tRaw.coerceIn(0.0, 1.0)
        return when (this) {
            LINEAR -> t
            EASE_IN -> t * t
            EASE_OUT -> 1 - (1 - t) * (1 - t)
            EASE_IN_OUT -> if (t < 0.5) 2 * t * t else 1 - Math.pow(-2 * t + 2, 2.0) / 2
            SMOOTH -> t * t * (3 - 2 * t)
            OVERSHOOT -> {
                val c = 1.70158
                1 + (c + 1) * Math.pow(t - 1, 3.0) + c * Math.pow(t - 1, 2.0)
            }
            BOUNCE -> {
                val n1 = 7.5625; val d1 = 2.75
                var x = t
                when {
                    x < 1 / d1 -> n1 * x * x
                    x < 2 / d1 -> { x -= 1.5 / d1; n1 * x * x + 0.75 }
                    x < 2.5 / d1 -> { x -= 2.25 / d1; n1 * x * x + 0.9375 }
                    else -> { x -= 2.625 / d1; n1 * x * x + 0.984375 }
                }
            }
            ELASTIC -> {
                if (t == 0.0 || t == 1.0) t
                else {
                    val p = 0.3
                    Math.pow(2.0, -10 * t) * Math.sin((t - p / 4) * 2 * Math.PI / p) + 1
                }
            }
            ANTICIPATION -> {
                if (t < 0.25) -0.35 * Math.sin(t / 0.25 * Math.PI)
                else {
                    val u = (t - 0.25) / 0.75
                    1 - Math.pow(1 - u, 2.2)
                }
            }
        }
    }
}

sealed class KeyframeVariation(val label: String) {
    object Hold : KeyframeVariation("Hold")
    object Linear : KeyframeVariation("Linear")
    data class Preset(val preset: EasingPreset) : KeyframeVariation(preset.label)
    data class Bezier(
        val c1x: Double = 0.3, val c1y: Double = 0.3,
        val c2x: Double = 0.7, val c2y: Double = 0.7,
    ) : KeyframeVariation("Custom Bézier")
    data class Spring(
        val stiffness: Double = 8.0,   // 1..30 snappiness
        val damping: Double = 0.55,    // 0.05..1 (1 = no bounce)
    ) : KeyframeVariation("Spring")

    fun toJson(): JSONObject = when (this) {
        Hold -> JSONObject().put("type", "hold")
        Linear -> JSONObject().put("type", "linear")
        is Preset -> JSONObject().put("type", "preset").put("preset", preset.name)
        is Bezier -> JSONObject().put("type", "bezier")
            .put("c1x", c1x).put("c1y", c1y).put("c2x", c2x).put("c2y", c2y)
        is Spring -> JSONObject().put("type", "spring")
            .put("stiffness", stiffness).put("damping", damping)
    }

    companion object {
        fun fromJson(o: JSONObject): KeyframeVariation = when (o.optString("type")) {
            "hold" -> Hold
            "preset" -> Preset(
                EasingPreset.entries.firstOrNull { it.name == o.optString("preset") } ?: EasingPreset.EASE_IN_OUT
            )
            "bezier" -> Bezier(
                o.optDouble("c1x", 0.3), o.optDouble("c1y", 0.3),
                o.optDouble("c2x", 0.7), o.optDouble("c2y", 0.7),
            )
            "spring" -> Spring(o.optDouble("stiffness", 8.0), o.optDouble("damping", 0.55))
            else -> Linear
        }
    }
}

data class KeyframeSettings(
    val velocityInfluence: Double = 0.0,  // 0..1, blends the curve toward a straight line
    val clamped: Boolean = true,          // clamp non-monotone curves into the property range
    val reversed: Boolean = false,        // mirror the curve horizontally
) {
    fun toJson(): JSONObject = JSONObject()
        .put("vi", velocityInfluence).put("cl", clamped).put("rv", reversed)

    companion object {
        fun fromJson(o: JSONObject) = KeyframeSettings(
            o.optDouble("vi", 0.0), o.optBoolean("cl", true), o.optBoolean("rv", false)
        )
    }
}

data class Keyframe(
    val id: Long,
    val property: KeyframeProperty,
    val timeMs: Long,          // clip-relative timeline ms
    val value: Double,
    val variation: KeyframeVariation = KeyframeVariation.Preset(EasingPreset.EASE_IN_OUT),
    val settings: KeyframeSettings = KeyframeSettings(),
) {
    fun toJson(): JSONObject = JSONObject()
        .put("p", property.name).put("t", timeMs).put("v", value)
        .put("var", variation.toJson()).put("set", settings.toJson())

    companion object {
        fun fromJson(o: JSONObject) = Keyframe(
            id = o.optLong("id", System.nanoTime()),
            property = KeyframeProperty.entries.firstOrNull { it.name == o.optString("p") } ?: KeyframeProperty.SCALE,
            timeMs = o.optLong("t", 0),
            value = o.optDouble("v", 1.0),
            variation = KeyframeVariation.fromJson(o.optJSONObject("var") ?: JSONObject()),
            settings = KeyframeSettings.fromJson(o.optJSONObject("set") ?: JSONObject()),
        )
    }
}

/** Evaluation — same math semantics as CSKeyframeEvaluator (Swift side). */
object KeyframeEvaluator {

    fun evaluate(
        keyframes: List<Keyframe>, property: KeyframeProperty,
        staticBase: Double, atMs: Long,
    ): Double {
        val kfs = keyframes.filter { it.property == property }.sortedBy { it.timeMs }
        if (kfs.isEmpty()) return staticBase
        if (atMs <= kfs.first().timeMs) return kfs.first().value
        if (atMs >= kfs.last().timeMs) return kfs.last().value

        for (i in 0 until kfs.size - 1) {
            val a = kfs[i]; val b = kfs[i + 1]
            if (atMs >= a.timeMs && atMs <= b.timeMs) {
                val span = (b.timeMs - a.timeMs).toDouble()
                val raw = if (span > 0) (atMs - a.timeMs) / span else 1.0
                val progress = progressFrom(a, b, raw)
                val v = a.value + (b.value - a.value) * progress
                return if (a.settings.clamped) property.clamp(v) else if (v.isFinite()) v else staticBase
            }
        }
        return staticBase
    }

    fun progressFrom(a: Keyframe, b: Keyframe, raw: Double): Double {
        val t = if (a.settings.reversed) 1 - raw else raw
        val out = when (val variation = a.variation) {
            is KeyframeVariation.Hold -> 0.0
            is KeyframeVariation.Linear -> t
            is KeyframeVariation.Preset -> variation.preset.value(t)
            is KeyframeVariation.Bezier -> solveBezier(t, variation)
            is KeyframeVariation.Spring -> spring(t, variation.stiffness, variation.damping)
        }
        val vi = a.settings.velocityInfluence.coerceIn(0.0, 1.0)
        var result = out
        if (vi > 0 && result.isFinite()) result = result * (1 - vi) + t * vi
        return if (result.isFinite()) result else t
    }

    /** Unit damped spring over a fixed horizon, normalized to end at 1. */
    fun spring(t: Double, stiffness: Double, damping: Double): Double {
        val d = damping.coerceAtLeast(0.05)
        val horizon = 6.0
        if (d >= 0.995) return 1 - Math.pow(1 - t, maxOf(1.0, stiffness / 4))
        val omega = maxOf(1.0, stiffness)
        val sigma = omega * d
        val phase = omega * kotlin.math.sqrt(1 - d * d)
        fun raw(u: Double) = 1 - Math.exp(-sigma * u * horizon) * Math.cos(phase * u * horizon)
        val end = raw(1.0)
        return raw(t) / (if (kotlin.math.abs(end) > 0.0001) end else 1.0)
    }

    /** Cubic Bézier timing solved by bisection (CSS timing-function semantics). */
    fun solveBezier(t: Double, bezier: KeyframeVariation.Bezier): Double {
        var lo = 0.0
        var hi = 1.0
        for (i in 0 until 28) {
            val mid = (lo + hi) / 2
            val x = component(mid, bezier.c1x, bezier.c2x)
            if (kotlin.math.abs(x - t) < 0.0005) {
                lo = mid
                hi = mid
                break
            }
            if (x < t) lo = mid else hi = mid
        }
        val s = (lo + hi) / 2
        return component(s, bezier.c1y, bezier.c2y)
    }

    private fun component(s: Double, a: Double, b: Double): Double {
        val u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
}
