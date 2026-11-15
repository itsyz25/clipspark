import SwiftUI

/// Bundled, offline templates (no network, no remote packs). A template is a
/// recipe applied to the user's picked clips: per-clip speed, the transition
/// entering clips 2+, and an optional title overlay.
struct ClipTemplate: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let tagline: String
    let uses: String
    let colorSeed: Int

    /// Applied to every clip.
    let speed: Double
    /// Applied at junctions from clip 2 onward.
    let transitionIn: CSTransition
    /// Optional title overlay (bold, accent color, centered high).
    let titleOverlay: String?
    /// Speed-ramp feel: alternate clip speeds [fast, slow].
    let alternatingSpeed: Bool

    static let catalog: [ClipTemplate] = [
        ClipTemplate(
            name: "Beat drop", tagline: "Fast cuts, punchy rhythm",
            uses: "2.1M", colorSeed: 0,
            speed: 1.5, transitionIn: .pushLeft, titleOverlay: nil, alternatingSpeed: true
        ),
        ClipTemplate(
            name: "Vlog intro", tagline: "Soft open with a title",
            uses: "890K", colorSeed: 1,
            speed: 1.0, transitionIn: .crossfade, titleOverlay: "My Story", alternatingSpeed: false
        ),
        ClipTemplate(
            name: "Product show", tagline: "Clean showcase dips",
            uses: "610K", colorSeed: 2,
            speed: 1.0, transitionIn: .fadeBlack, titleOverlay: "New Arrival", alternatingSpeed: false
        ),
        ClipTemplate(
            name: "Retro film", tagline: "Mono look, slow push",
            uses: "480K", colorSeed: 0,
            speed: 0.8, transitionIn: .crossfade, titleOverlay: "memories", alternatingSpeed: false
        ),
    ]
}

extension ClipTemplate {
    /// Builds the initial clip list for the given assets under this recipe.
    func makeClips(assetCount: Int, assetDurations: [Double]) -> [EditorViewModel.ClipSegment] {
        var result: [EditorViewModel.ClipSegment] = []
        for index in 0..<assetCount {
            let duration = index < assetDurations.count ? assetDurations[index] : 0
            var clip = EditorViewModel.ClipSegment(
                assetIndex: index,
                sourceIn: 0,
                sourceDuration: duration
            )
            if alternatingSpeed {
                clip.speed = index % 2 == 0 ? speed : max(0.25, speed / 2)
            } else {
                clip.speed = speed
            }
            clip.transitionIn = index == 0 ? .none : transitionIn
            result.append(clip)
        }
        return result
    }

    func makeOverlays() -> [EditorViewModel.EditorOverlay] {
        guard let title = titleOverlay else { return [] }
        var overlay = EditorViewModel.EditorOverlay(kind: .text(title))
        overlay.y = 0.2
        overlay.fontSize = 28
        return [overlay]
    }
}
