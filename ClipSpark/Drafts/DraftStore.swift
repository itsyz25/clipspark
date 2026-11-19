import Foundation
import Photos
import SwiftUI
import UIKit

// MARK: - Saved draft models (Codable, stored as local JSON — offline)

struct SavedKeyframe: Codable, Equatable {
    var property: String
    var time: Double
    var value: Double
    var variation: SavedKeyframeVariation
    var velocityInfluence: Double
    var clamped: Bool
    var reversed: Bool
}

/// Codable form of the variation enum (Swift synthesizes the enum's Codable,
/// but this flat form keeps drafts readable and forward-compatible).
struct SavedKeyframeVariation: Codable, Equatable {
    var type: String            // hold | linear | preset | bezier | spring
    var preset: String?
    var c1x: Double?, c1y: Double?, c2x: Double?, c2y: Double?
    var stiffness: Double?, damping: Double?
}

struct SavedClip: Codable, Equatable {
    var assetIndex: Int
    var sourceIn: Double
    var sourceDuration: Double
    var speed: Double
    var volume: Double
    var isMuted: Bool
    var transitionIn: String
    var keyframes: [SavedKeyframe]?   // optional: drafts saved before keyframes
}

struct SavedOverlay: Codable, Equatable {
    enum Kind: String, Codable { case text, sticker }
    var kind: Kind
    var value: String
    var colorHex: UInt32
    var fontSize: CGFloat
    var x: CGFloat
    var y: CGFloat
    var isBold: Bool
    // Optional so drafts written before multi-overlay support still decode.
    var scale: CGFloat?
    var rotation: Double?
    var opacity: Double?
    var start: Double?
    var duration: Double?
}

struct SavedLook: Codable, Equatable {
    var filter: String
    var brightness: Double
    var contrast: Double
    var saturation: Double
    var motionBlur: Double?
    var motionBlurAngle: Double?
}

struct SavedDraft: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var assetLocalIDs: [String]
    var clips: [SavedClip]
    var overlays: [SavedOverlay]
    var look: SavedLook

    var durationText: String {
        let total = clips.reduce(0.0) { $0 + $1.sourceDuration / max($1.speed, 0.25) }
        let s = Int(total.rounded())
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Store (App Support, JSON, offline)

final class DraftStore {
    static let shared = DraftStore()

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipspark-drafts.json")
    }

    func loadAll() -> [SavedDraft] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SavedDraft].self, from: data)) ?? []
    }

    private func saveAll(_ drafts: [SavedDraft]) {
        if let data = try? JSONEncoder().encode(drafts) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// Upsert by id; keeps newest 20 drafts.
    func save(_ draft: SavedDraft) {
        var all = loadAll()
        if let index = all.firstIndex(where: { $0.id == draft.id }) {
            all[index] = draft
        } else {
            all.insert(draft, at: 0)
        }
        if all.count > 20 { all.removeLast(all.count - 20) }
        saveAll(all)
    }

    func delete(_ id: UUID) {
        saveAll(loadAll().filter { $0.id != id })
    }

    func fetchAssets(localIDs: [String]) -> [PHAsset] {
        guard !localIDs.isEmpty else { return [] }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIDs, options: nil)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        // Keep saved order (fetch order is not guaranteed)
        let byID = Dictionary(uniqueKeysWithValues: assets.map { ($0.localIdentifier, $0) })
        return localIDs.compactMap { byID[$0] }
    }
}

// MARK: - Keyframe ⇄ saved forms

extension CSKeyframeVariation {
    var saved: SavedKeyframeVariation {
        switch self {
        case .hold: return SavedKeyframeVariation(type: "hold", preset: nil, c1x: nil, c1y: nil, c2x: nil, c2y: nil, stiffness: nil, damping: nil)
        case .linear: return SavedKeyframeVariation(type: "linear", preset: nil, c1x: nil, c1y: nil, c2x: nil, c2y: nil, stiffness: nil, damping: nil)
        case .preset(let p): return SavedKeyframeVariation(type: "preset", preset: p.rawValue, c1x: nil, c1y: nil, c2x: nil, c2y: nil, stiffness: nil, damping: nil)
        case .bezier(let c1x, let c1y, let c2x, let c2y):
            return SavedKeyframeVariation(type: "bezier", preset: nil, c1x: c1x, c1y: c1y, c2x: c2x, c2y: c2y, stiffness: nil, damping: nil)
        case .spring(let stiffness, let damping):
            return SavedKeyframeVariation(type: "spring", preset: nil, c1x: nil, c1y: nil, c2x: nil, c2y: nil, stiffness: stiffness, damping: damping)
        }
    }

    init(_ saved: SavedKeyframeVariation) {
        switch saved.type {
        case "hold": self = .hold
        case "preset": self = .preset(CSEasingPreset(rawValue: saved.preset ?? "") ?? .easeInOut)
        case "bezier":
            self = .bezier(c1x: saved.c1x ?? 0.3, c1y: saved.c1y ?? 0.3, c2x: saved.c2x ?? 0.7, c2y: saved.c2y ?? 0.7)
        case "spring": self = .spring(stiffness: saved.stiffness ?? 8, damping: saved.damping ?? 0.55)
        default: self = .linear
        }
    }
}

extension CSKeyframe {
    var saved: SavedKeyframe {
        SavedKeyframe(
            property: property.rawValue,
            time: time,
            value: value,
            variation: variation.saved,
            velocityInfluence: settings.velocityInfluence,
            clamped: settings.clamped,
            reversed: settings.reversed
        )
    }

    init(_ saved: SavedKeyframe) {
        self.init(
            property: CSKeyframeProperty(rawValue: saved.property) ?? .scale,
            time: saved.time,
            value: saved.value,
            variation: CSKeyframeVariation(saved.variation),
            settings: CSKeyframeSettings(
                velocityInfluence: saved.velocityInfluence,
                clamped: saved.clamped,
                reversed: saved.reversed
            )
        )
    }
}

// MARK: - Mapping EditorViewModel ⇄ SavedDraft

extension EditorViewModel {
    func toSavedDraft(name: String, id: UUID? = nil) -> SavedDraft? {
        guard !clips.isEmpty else { return nil }
        var draft = SavedDraft(
            id: id ?? UUID(),
            name: name,
            createdAt: Date(),
            assetLocalIDs: sourceAssets.map { $0.localIdentifier },
            clips: clips.map { clip in
                SavedClip(
                    assetIndex: clip.assetIndex,
                    sourceIn: clip.sourceIn,
                    sourceDuration: clip.sourceDuration,
                    speed: clip.speed,
                    volume: clip.volume,
                    isMuted: clip.isMuted,
                    transitionIn: clip.transitionIn.rawValue,
                    keyframes: clip.keyframes.map { $0.saved }
                )
            },
            overlays: overlays.map { overlay in
                SavedOverlay(
                    kind: overlay.textValue != nil ? .text : .sticker,
                    value: overlay.textValue ?? overlay.symbolName ?? "",
                    colorHex: ColorHex.encode(overlay.color),
                    fontSize: overlay.fontSize,
                    x: overlay.x,
                    y: overlay.y,
                    isBold: overlay.isBold,
                    scale: overlay.scale,
                    rotation: overlay.rotation,
                    opacity: overlay.opacity,
                    start: overlay.start,
                    duration: overlay.duration
                )
            },
            look: SavedLook(
                filter: look.filter.rawValue,
                brightness: look.brightness,
                contrast: look.contrast,
                saturation: look.saturation,
                motionBlur: look.motionBlur,
                motionBlurAngle: look.motionBlurAngle
            )
        )
        if let id { draft.id = id }
        return draft
    }

    func restore(from draft: SavedDraft, assets: [PHAsset]) {
        sourceAssets = assets
        clips = draft.clips.map { saved in
            ClipSegment(
                assetIndex: saved.assetIndex,
                sourceIn: saved.sourceIn,
                sourceDuration: saved.sourceDuration,
                speed: saved.speed,
                volume: saved.volume,
                isMuted: saved.isMuted,
                transitionIn: CSTransition(rawValue: saved.transitionIn) ?? .none,
                keyframes: (saved.keyframes ?? []).map { CSKeyframe($0) }
            )
        }
        overlays = draft.overlays.map { saved in
            var overlay: EditorOverlay
            switch saved.kind {
            case .text: overlay = EditorOverlay(kind: .text(saved.value))
            case .sticker: overlay = EditorOverlay(kind: .sticker(saved.value), fontSize: 60)
            }
            overlay.color = ColorHex.decode(saved.colorHex)
            // Legacy drafts were authored before the height-relative type
            // scale existed; bump their size so they look the same as before.
            let isLegacy = saved.scale == nil
            overlay.fontSize = isLegacy ? saved.fontSize * 1.7 : saved.fontSize
            overlay.x = saved.x
            overlay.y = saved.y
            overlay.isBold = saved.isBold
            overlay.scale = saved.scale ?? 1
            overlay.rotation = saved.rotation ?? 0
            overlay.opacity = saved.opacity ?? 1
            overlay.start = saved.start ?? 0
            overlay.duration = saved.duration
            return overlay
        }
        look = Look(
            filter: CSFilter(rawValue: draft.look.filter) ?? .none,
            brightness: draft.look.brightness,
            contrast: draft.look.contrast,
            saturation: draft.look.saturation,
            motionBlur: draft.look.motionBlur ?? 0,
            motionBlurAngle: draft.look.motionBlurAngle ?? 0
        )
        rebuildComposition()
        installTimeObserver()
    }
}

// MARK: - Color ⇄ hex packing (dark-trait resolved)

enum ColorHex {
    static func encode(_ color: Color) -> UInt32 {
        let ui = UIColor(color)
        let resolved = ui.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        let pack = { (v: CGFloat) -> UInt32 in UInt32((v.clamped01() * 255).rounded()) }
        return (pack(r) << 16) | (pack(g) << 8) | pack(b)
    }

    static func decode(_ hex: UInt32) -> Color {
        Color(hex: hex)
    }
}

private extension CGFloat {
    func clamped01() -> CGFloat {
        var v = self
        if v < 0 { v = 0 }
        if v > 1 { v = 1 }
        return v
    }
}
