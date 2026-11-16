import Foundation
import Photos
import SwiftUI
import UIKit

// MARK: - Saved draft models (Codable, stored as local JSON — offline)

struct SavedClip: Codable, Equatable {
    var assetIndex: Int
    var sourceIn: Double
    var sourceDuration: Double
    var speed: Double
    var volume: Double
    var isMuted: Bool
    var transitionIn: String
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
}

struct SavedLook: Codable, Equatable {
    var filter: String
    var brightness: Double
    var contrast: Double
    var saturation: Double
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
                    transitionIn: clip.transitionIn.rawValue
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
                    isBold: overlay.isBold
                )
            },
            look: SavedLook(
                filter: look.filter.rawValue,
                brightness: look.brightness,
                contrast: look.contrast,
                saturation: look.saturation
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
                transitionIn: CSTransition(rawValue: saved.transitionIn) ?? .none
            )
        }
        overlays = draft.overlays.map { saved in
            var overlay: EditorOverlay
            switch saved.kind {
            case .text: overlay = EditorOverlay(kind: .text(saved.value))
            case .sticker: overlay = EditorOverlay(kind: .sticker(saved.value))
            }
            overlay.color = ColorHex.decode(saved.colorHex)
            overlay.fontSize = saved.fontSize
            overlay.x = saved.x
            overlay.y = saved.y
            overlay.isBold = saved.isBold
            return overlay
        }
        look = Look(
            filter: CSFilter(rawValue: draft.look.filter) ?? .none,
            brightness: draft.look.brightness,
            contrast: draft.look.contrast,
            saturation: draft.look.saturation
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
