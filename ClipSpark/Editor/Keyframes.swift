import Combine
import Foundation

// MARK: - Clip keyframes
//
// A keyframe pins a property's value at a moment inside a clip (seconds,
// clip-relative). The "variation" decides how the value travels from this
// keyframe to the next one:
//   hold        — value stays put until the next keyframe (step)
//   linear      — straight ramp
//   preset      — a named easing from the built-in library
//   bezier      — user-set cubic Bézier timing (two control points)
//   spring      — damped-spring approach (stiffness + damping sliders)
// Shared custom settings tune every variation (velocity blend, clamping,
// horizontal mirror). 100% offline: all curves are math, no assets.

enum CSKeyframeProperty: String, Codable, CaseIterable, Identifiable {
    case scale, posX, posY, rotation, opacity, volume
    case brightness, contrast, saturation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scale: "Scale"
        case .posX: "Position X"
        case .posY: "Position Y"
        case .rotation: "Rotation"
        case .opacity: "Opacity"
        case .volume: "Volume"
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .saturation: "Saturation"
        }
    }

    /// Legal value range — graph Y axis and evaluation clamp.
    var range: ClosedRange<Double> {
        switch self {
        case .scale: 0.1...3.0
        case .posX, .posY: -1.0...1.0
        case .rotation: -180.0...180.0
        case .opacity: 0.0...1.0
        case .volume: 0.0...2.0
        case .brightness: -0.2...0.2
        case .contrast: 0.5...1.5
        case .saturation: 0.0...2.0
        }
    }

    /// Value when the property is unkeyed (from the clip / project look).
    func staticBase(volume: Double, look: EditorViewModel.Look) -> Double {
        switch self {
        case .scale: 1.0
        case .posX, .posY: 0.0
        case .rotation: 0.0
        case .opacity: 1.0
        case .volume: volume
        case .brightness: look.brightness
        case .contrast: look.contrast
        case .saturation: look.saturation
        }
    }

    /// Format used in the inspector value readout.
    func format(_ value: Double) -> String {
        switch self {
        case .rotation: String(format: "%.0f°", value)
        default: String(format: "%.2f", value)
        }
    }
}

enum CSEasingPreset: String, Codable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut, overshoot, bounce, elastic, anticipation, smooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In Out"
        case .overshoot: "Overshoot"
        case .bounce: "Bounce"
        case .elastic: "Elastic"
        case .anticipation: "Anticipation"
        case .smooth: "Smooth"
        }
    }

    /// Monotone curves stay in [0,1]; overshoot/elastic/bounce leave it by design.
    func value(_ tRaw: Double) -> Double {
        let t = max(0, min(1, tRaw))
        switch self {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        case .easeInOut: return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        case .smooth: return t * t * (3 - 2 * t)
        case .overshoot:
            let c = 1.70158
            return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
        case .bounce:
            let n1 = 7.5625, d1 = 2.75
            var x = t
            if x < 1 / d1 { return n1 * x * x }
            if x < 2 / d1 { x -= 1.5 / d1; return n1 * x * x + 0.75 }
            if x < 2.5 / d1 { x -= 2.25 / d1; return n1 * x * x + 0.9375 }
            x -= 2.625 / d1
            return n1 * x * x + 0.984375
        case .elastic:
            if t == 0 || t == 1 { return t }
            let p = 0.3
            return pow(2, -10 * t) * sin((t - p / 4) * 2 * .pi / p) + 1
        case .anticipation:
            if t < 0.25 { return -0.35 * sin(t / 0.25 * .pi) }
            let u = (t - 0.25) / 0.75
            return 1 - pow(1 - u, 2.2)
        }
    }
}

enum CSKeyframeVariation: Codable, Equatable {
    case hold
    case linear
    case preset(CSEasingPreset)
    /// User-drawn cubic Bézier timing, CSS-style control points in 0...1.
    case bezier(c1x: Double, c1y: Double, c2x: Double, c2y: Double)
    /// Physical approach: stiffness 1...30 (snappiness), damping 0.05...1
    /// (0.05 = long wobble, 1 = critically damped, no bounce).
    case spring(stiffness: Double, damping: Double)

    var label: String {
        switch self {
        case .hold: "Hold"
        case .linear: "Linear"
        case .preset(let p): p.label
        case .bezier: "Custom Bézier"
        case .spring: "Spring"
        }
    }
}

/// Shared custom settings attached to every keyframe.
struct CSKeyframeSettings: Codable, Equatable {
    /// 0...1 — blends the curve toward a straight line (velocity influence).
    var velocityInfluence: Double = 0
    /// Clamp non-monotone curves (overshoot/elastic/bounce) into the property range.
    var clamped: Bool = true
    /// Mirror the curve horizontally.
    var reversed: Bool = false
}

struct CSKeyframe: Codable, Equatable, Identifiable {
    var id = UUID()
    var property: CSKeyframeProperty
    var time: Double        // clip-relative seconds
    var value: Double
    var variation: CSKeyframeVariation = .preset(.easeInOut)
    var settings = CSKeyframeSettings()
}

// MARK: - Evaluation

enum CSKeyframeEvaluator {
    /// Evaluate keyframed `property` at clip-relative seconds `t`.
    /// Falls back to the property's static value when unkeyed.
    static func evaluate(
        _ keyframes: [CSKeyframe], _ property: CSKeyframeProperty,
        staticBase: Double, at t: Double
    ) -> Double {
        let kfs = keyframes.filter { $0.property == property }.sorted { $0.time < $1.time }
        guard !kfs.isEmpty else { return staticBase }
        if t <= kfs[0].time { return kfs[0].value }
        if t >= kfs[kfs.count - 1].time { return kfs[kfs.count - 1].value }

        for i in 0..<(kfs.count - 1) {
            let a = kfs[i], b = kfs[i + 1]
            guard t >= a.time && t <= b.time else { continue }
            let span = b.time - a.time
            let raw = span > 0 ? (t - a.time) / span : 1.0
            let progress = progress(from: a, to: b, raw: raw)
            let v = a.value + (b.value - a.value) * progress
            if a.settings.clamped {
                let r = property.range
                return max(r.lowerBound, min(r.upperBound, v))
            }
            return v.isFinite ? v : staticBase
        }
        return staticBase
    }

    /// Normalized progress between keyframes a→b at raw time fraction.
    static func progress(from a: CSKeyframe, to b: CSKeyframe, raw: Double) -> Double {
        let t = a.settings.reversed ? 1 - raw : raw
        var out: Double
        switch a.variation {
        case .hold:
            return 0
        case .linear:
            out = t
        case .preset(let preset):
            out = preset.value(t)
        case .bezier(let c1x, let c1y, let c2x, let c2y):
            out = solveBezier(t, c1x, c1y, c2x, c2y)
        case .spring(let stiffness, let damping):
            out = spring(t, stiffness: stiffness, damping: damping)
        }
        // Velocity influence pulls the curve toward a straight line.
        let vi = max(0, min(1, a.settings.velocityInfluence))
        if vi > 0, out.isFinite { out = out * (1 - vi) + t * vi }
        return out.isFinite ? out : t
    }

    /// Unit damped spring evaluated over a fixed horizon, normalized to end at 1.
    static func spring(_ t: Double, stiffness: Double, damping: Double) -> Double {
        let d = max(0.05, damping)
        let horizon = 6.0
        if d >= 0.995 {
            return 1 - pow(1 - t, max(1.0, stiffness / 4))
        }
        let omega = max(1, stiffness)
        let sigma = omega * d
        let phase = omega * sqrt(1 - d * d)
        func raw(_ u: Double) -> Double {
            1 - exp(-sigma * u * horizon) * cos(phase * u * horizon)
        }
        let end = raw(1)
        return raw(t) / (abs(end) > 0.0001 ? end : 1)
    }

    /// Cubic Bézier timing solved by bisection (CSS timing-function semantics).
    static func solveBezier(_ t: Double, _ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<28 {
            let mid = (lo + hi) / 2
            let x = bezierComponent(mid, c1x, c2x)
            if abs(x - t) < 0.0005 { lo = mid; break }
            if x < t { lo = mid } else { hi = mid }
        }
        let s = (lo + hi) / 2
        return bezierComponent(s, c1y, c2y)
    }

    private static func bezierComponent(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let u = 1 - s
        return 3 * u * u * s * a + 3 * u * s * s * b + s * s * s
    }
}

// MARK: - User easing preset library (custom settings, saved locally)

/// User-authored Bézier presets, persisted in Documents. No cloud.
struct CSUserEasingPreset: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var c1x: Double, c1y: Double, c2x: Double, c2y: Double
}

final class CSEasingPresetLibrary: ObservableObject {
    static let shared = CSEasingPresetLibrary()
    @Published private(set) var presets: [CSUserEasingPreset] = []
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("clipspark-easing-presets.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([CSUserEasingPreset].self, from: data) {
            presets = saved
        }
    }

    func save(name: String, c1x: Double, c1y: Double, c2x: Double, c2y: Double) {
        presets.removeAll { $0.name == name }
        presets.append(CSUserEasingPreset(name: name, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y))
        persist()
    }

    func delete(_ preset: CSUserEasingPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(presets) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
