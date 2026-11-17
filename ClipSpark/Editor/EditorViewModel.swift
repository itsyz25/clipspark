import AVFoundation
import Combine
import Photos
import SwiftUI

/// Editable editor core. Clips carry trim/speed/volume state; overlays
/// (text/sticker) and look (filter/adjust) are project state. All mutations go
/// through snapshot-based undo (clips + overlays together). 100% offline:
/// every preset is an iOS built-in — no network fetches exist in this file.
@MainActor
final class EditorViewModel: ObservableObject {
    // MARK: - Model

    struct ClipSegment: Identifiable, Equatable {
        var id = UUID()
        let assetIndex: Int
        var sourceIn: Double
        var sourceDuration: Double
        var speed: Double = 1.0
        var volume: Double = 1.0        // 0...2
        var isMuted: Bool = false
        /// Transition shown at the junction BETWEEN the previous clip and this one.
        var transitionIn: CSTransition = .none
        var start: Double = 0
        var end: Double = 0

        var timelineDuration: Double { sourceDuration / speed }

        static func == (lhs: ClipSegment, rhs: ClipSegment) -> Bool {
            lhs.id == rhs.id && lhs.sourceIn == rhs.sourceIn
                && lhs.sourceDuration == rhs.sourceDuration && lhs.speed == rhs.speed
                && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
                && lhs.transitionIn == rhs.transitionIn
        }

        var trimmedDurationText: String {
            let s = Int(timelineDuration.rounded())
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
    }

    /// Text/sticker placed over the canvas. Position is normalized (0...1).
    struct EditorOverlay: Identifiable, Equatable {
        enum Kind: Equatable { case text(String); case sticker(String) } // sticker = SF Symbol name
        let id = UUID()
        var kind: Kind
        var color: Color = .white
        var fontSize: CGFloat = 20
        var x: CGFloat = 0.5
        var y: CGFloat = 0.5
        var isBold: Bool = true

        static func == (lhs: EditorOverlay, rhs: EditorOverlay) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind
                && lhs.x == rhs.x && lhs.y == rhs.y
                && lhs.fontSize == rhs.fontSize && lhs.color == rhs.color
        }

        var textValue: String? {
            if case .text(let t) = kind { return t }
            return nil
        }
        var symbolName: String? {
            if case .sticker(let s) = kind { return s }
            return nil
        }
    }

    /// Look state. All presets are iOS built-in photo effects (offline).
    struct Look: Equatable {
        var filter: CSFilter = .none
        var brightness: Double = 0   // -0.2...0.2  (CI brightness)
        var contrast: Double = 1     // 0.5...1.5
        var saturation: Double = 1   // 0...2
    }

    struct ProjectState: Equatable {
        var clips: [ClipSegment]
        var overlays: [EditorOverlay]
        var look: Look
    }

    // MARK: - Published state

    @Published var clips: [ClipSegment] = []
    @Published var overlays: [EditorOverlay] = []
    @Published var look = Look()
    @Published var timecode: Double = 0
    @Published var isPlaying = false
    @Published var pixelsPerSecond: CGFloat = 40
    @Published var selectedClipID: UUID?
    @Published var canUndo = false
    @Published var canRedo = false

    var sourceAssets: [PHAsset] = []
    /// Decoded AVAssets matching sourceAssets by index (async-loaded; used for
    /// composition building — PHAsset itself has no tracks API).
    var avAssets: [AVAsset] = []
    private(set) var compositionDuration: Double = 0

    // MARK: - Undo/redo (snapshots include clips + overlays; cap 50)

    private var undoStack: [ProjectState] = []
    private var redoStack: [ProjectState] = []
    private let maxHistory = 50

    private var currentState: ProjectState {
        ProjectState(clips: clips, overlays: overlays, look: look)
    }

    private func restore(_ state: ProjectState) {
        clips = state.clips
        overlays = state.overlays
        look = state.look
        applyVideoComposition()
    }

    private func pushUndo() {
        undoStack.append(currentState)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentState)
        restore(previous)
        afterClipsChanged()
        CSHaptics.tick()
        syncUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentState)
        restore(next)
        afterClipsChanged()
        CSHaptics.tick()
        syncUndoFlags()
    }

    private func syncUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: - Player

    let player = AVPlayer()
    private var timeObserver: Any?

    // MARK: - Load

    func load(assets: [PHAsset], template: ClipTemplate? = nil) {
        sourceAssets = assets
        if let template {
            // Bundled offline recipe: preset speeds, transitions, title overlay
            clips = template.makeClips(
                assetCount: assets.count,
                assetDurations: assets.map { $0.duration } // TimeInterval == Double
            )
            overlays = template.makeOverlays()
        } else {
            clips = assets.enumerated().map { index, asset in
                ClipSegment(assetIndex: index, sourceIn: 0, sourceDuration: asset.duration)
            }
        }
        loadAVAssetsThenRebuild()
        installTimeObserver()
    }

    /// Photos hands out AVAssets asynchronously; composition rebuild waits for
    /// them. Fully on-device (PHImageManager), no network.
    private func loadAVAssetsThenRebuild() {
        let group = DispatchGroup()
        var loaded: [AVAsset?] = Array(repeating: nil, count: sourceAssets.count)
        let options = PHVideoRequestOptions()
        options.version = .current
        options.isNetworkAccessAllowed = false // offline by construction
        for (index, asset) in sourceAssets.enumerated() {
            group.enter()
            PHImageManager.default().requestAVAsset(
                forVideo: asset, options: options
            ) { avAsset, _, _ in
                loaded[index] = avAsset
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.avAssets = loaded.map { $0 ?? AVURLAsset(url: URL(fileURLWithPath: "/dev/null")) }
                self.rebuildComposition()
            }
        }
    }

    func installTimeObserver() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.timecode = time.seconds
            }
        }
    }

    // MARK: - Composition rebuild (dual video tracks + junction overlaps)

    /// Two alternating video tracks: transition junctions overlap the last
    /// `duration` seconds of clip N with the first of clip N+1; the custom
    /// compositor blends them (offline, computed from the clips' own frames).
    func rebuildComposition() {
        let built = buildComposition()
        compositionDuration = built.duration

        let item = AVPlayerItem(asset: built.composition)
        if let audioMix = built.audioMix {
            item.audioMix = audioMix
        }
        player.replaceCurrentItem(with: item)
        applyVideoComposition(junctions: built.junctions) // custom compositor: transitions + look
        seek(to: timecode, animateHaptics: false)
    }

    /// Shared builder used by BOTH preview and export — a single source of
    /// truth so the exported file always matches what was previewed.
    func buildComposition() -> (composition: AVMutableComposition, junctions: [TransitionCompositor.Junction], audioMix: AVAudioMix?, duration: Double, naturalSize: CGSize) {
        let composition = AVMutableComposition()
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        var junctions: [TransitionCompositor.Junction] = []
        var cursor: Double = 0
        var lastTrackID: Int32?
        var lastClip: ClipSegment?
        var naturalSize = CGSize(width: 1280, height: 720)
        var naturalSizeCaptured = false

        for (index, clip) in clips.enumerated() {
            guard
                let asset = avAssets[safe: clip.assetIndex],
                let videoSource = asset.tracks(withMediaType: .video).first,
                let compositionTrack = composition.addMutableTrack(
                    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
                )
            else { continue }

            var at = cursor
            // Junction overlap against the previous clip
            if
                let lastClip, let lastTrackID,
                clip.transitionIn != .none,
                clip.transitionIn.duration > 0
            {
                let overlap = min(
                    clip.transitionIn.duration,
                    lastClip.timelineDuration / 2,
                    clip.timelineDuration / 2
                )
                if overlap > 0.05 {
                    at = cursor - overlap
                    junctions.append(TransitionCompositor.Junction(
                        time: at,
                        duration: overlap,
                        type: clip.transitionIn,
                        outTrack: lastTrackID,
                        inTrack: compositionTrack.trackID
                    ))
                }
            }

            let atTime = CMTime(seconds: at, preferredTimescale: 600)
            let range = CMTimeRange(
                start: CMTime(seconds: clip.sourceIn, preferredTimescale: 600),
                duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)
            )
            try? compositionTrack.insertTimeRange(range, of: videoSource, at: atTime)

            // Audio: the clip's own sound, volume/mute via audio mix (offline)
            if let audioSource = asset.tracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(
                   withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try? audioTrack.insertTimeRange(range, of: audioSource, at: atTime)
                if clip.speed != 1.0 {
                    audioTrack.scaleTimeRange(
                        CMTimeRange(start: atTime, duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)),
                        toDuration: CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)
                    )
                }
                let params = AVMutableAudioMixInputParameters(track: audioTrack)
                params.setVolume(clip.isMuted ? 0 : Float(clip.volume), at: .zero)
                audioMixParams.append(params)
            }

            if clip.speed != 1.0 {
                compositionTrack.scaleTimeRange(
                    CMTimeRange(start: atTime, duration: CMTime(seconds: clip.sourceDuration, preferredTimescale: 600)),
                    toDuration: CMTime(seconds: clip.timelineDuration, preferredTimescale: 600)
                )
            }
            compositionTrack.preferredTransform = videoSource.preferredTransform

            // Capture the natural render size from the first clip (orientation-aware)
            if !naturalSizeCaptured {
                let transformed = videoSource.naturalSize.applying(videoSource.preferredTransform)
                naturalSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                naturalSizeCaptured = true
            }

            var updated = clip
            updated.start = at
            updated.end = at + clip.timelineDuration
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index] = updated
            }
            cursor = updated.end
            lastTrackID = compositionTrack.trackID
            lastClip = updated
        }

        return (
            composition: composition,
            junctions: junctions,
            audioMix: audioMixParams.isEmpty
                ? nil
                : AVMutableAudioMix.audioMix(withInputParameters: audioMixParams),
            duration: cursor,
            naturalSize: naturalSize
        )
    }

    // MARK: - Video composition (transitions + look, offline, GPU compositor)

    func applyVideoComposition(junctions: [TransitionCompositor.Junction] = []) {
        guard let item = player.currentItem else { return }

        let composition = AVMutableVideoComposition()
        composition.renderSize = buildComposition().naturalSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.customVideoCompositorClass = TransitionCompositor.self

        TransitionCompositor.config = TransitionCompositor.Config(junctions: junctions, look: look)
        item.videoComposition = composition
    }

    /// Look changes: one slider gesture = one undo step (baseline pattern).
    func beginLookChange() {
        lookBaseline = currentState
    }

    func finalizeLookChange() {
        guard lookBaseline != nil else { return }
        undoStack.append(lookBaseline!)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        lookBaseline = nil
        syncUndoFlags()
    }

    private var lookBaseline: ProjectState?

    /// Live look update during a gesture (no history writes per tick).
    func updateLookLive(_ transform: (inout Look) -> Void) {
        var copy = look
        transform(&copy)
        look = copy
        applyVideoComposition()
    }

    func setLook(_ newLook: Look) {
        look = newLook
        applyVideoComposition()
    }

    // MARK: - Edit entry points

    /// One entry point for every clip edit: snapshot → mutate → rebuild → seek.
    func mutate(_ change: (inout [ClipSegment]) -> Void, recenter: Bool = false) {
        pushUndo()
        var copy = clips
        change(&copy)
        clips = copy
        afterClipsChanged(recenter: recenter)
    }

    func mutateOverlays(_ change: (inout [EditorOverlay]) -> Void) {
        pushUndo()
        var copy = overlays
        change(&copy)
        overlays = copy
    }

    /// Continuous drag path for overlays: snapshot once at gesture start.
    func beginOverlayDrag() {
        overlayDragBaseline = currentState
    }

    func finalizeOverlayDrag() {
        guard overlayDragBaseline != nil else { return }
        undoStack.append(overlayDragBaseline!)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        overlayDragBaseline = nil
        syncUndoFlags()
    }

    private var overlayDragBaseline: ProjectState?

    private func afterClipsChanged(recenter: Bool = false) {
        rebuildComposition()
        if recenter, let selected = selectedClip {
            seek(to: selected.start + selected.timelineDuration / 2, animateHaptics: false)
        }
    }

    // MARK: - Derived

    var selectedClip: ClipSegment? {
        guard let selectedClipID else { return nil }
        return clips.first { $0.id == selectedClipID }
    }

    var timecodeText: String {
        let total = Int(timecode.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var totalText: String {
        let total = Int(compositionDuration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    func asset(for clip: ClipSegment) -> PHAsset? {
        sourceAssets[safe: clip.assetIndex]
    }

    // MARK: - Playback & scrubbing

    func togglePlay() {
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        CSHaptics.tick()
    }

    private var lastBoundaryCrossed = false

    func seek(to time: Double, animateHaptics: Bool = true) {
        let clamped = max(0, min(time, compositionDuration))
        if animateHaptics, !isPlaying {
            let crossed = clips.contains { $0.start > 0.01 && $0.start > timecode && $0.start <= clamped }
                || clips.contains { $0.end < compositionDuration - 0.01 && $0.end > timecode && $0.end <= clamped }
            if crossed, !lastBoundaryCrossed {
                CSHaptics.snap()
            }
            lastBoundaryCrossed = crossed
        }
        timecode = clamped
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    // MARK: - Clip edits (each = one undo step)

    func select(_ clip: ClipSegment?) {
        selectedClipID = clip?.id
        if clip != nil { CSHaptics.tick() }
    }

    func beginTrim() { trimBaseline = currentState }

    func finalizeTrim() {
        guard trimBaseline != nil else { return }
        undoStack.append(trimBaseline!)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        trimBaseline = nil
        syncUndoFlags()
    }

    private var trimBaseline: ProjectState?

    func trim(clipID: UUID, edge: TrimEdge, newTimelineSeconds: CGFloat) {
        guard let index = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[index]
        guard let asset = asset(for: clip) else { return }

        let sourceMax = asset.duration // PHAsset.duration is TimeInterval (Double)
        let newSourceDuration = newTimelineSeconds * clip.speed

        switch edge {
        case .leading:
            let newIn = max(0, min(clip.sourceIn + (clip.sourceDuration - newSourceDuration), sourceMax - 0.2))
            let newDuration = max(0.2, newSourceDuration)
            mutateWithoutUndo(index) { $0.sourceIn = newIn; $0.sourceDuration = newDuration }
        case .trailing:
            let newDuration = max(0.2, min(newSourceDuration, sourceMax - clip.sourceIn))
            mutateWithoutUndo(index) { $0.sourceDuration = newDuration }
        }
        seek(to: timecode, animateHaptics: false)
    }

    enum TrimEdge { case leading, trailing }

    private func mutateWithoutUndo(_ index: Int, _ change: (inout ClipSegment) -> Void) {
        var copy = clips
        change(&copy[index])
        clips = copy
        afterClipsChanged()
    }

    func splitAtPlayhead() {
        guard
            let index = clips.firstIndex(where: { timecode >= $0.start + 0.1 && timecode <= $0.end - 0.1 })
        else { return }
        let clip = clips[index]
        let localTimelineSeconds = timecode - clip.start
        let splitSourceIn = clip.sourceIn + localTimelineSeconds * clip.speed

        var left = clip
        left.sourceDuration = localTimelineSeconds * clip.speed
        var right = clip
        right.sourceIn = splitSourceIn
        right.sourceDuration = clip.sourceDuration - localTimelineSeconds * clip.speed

        mutate({ clips in
            clips.remove(at: index)
            clips.insert(contentsOf: [left, right], at: index)
        })
        selectedClipID = nil
        CSHaptics.cut()
    }

    func duplicate(_ clip: ClipSegment) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var copy = clip
        copy.id = UUID()
        mutate({ clips in clips.insert(copy, at: index + 1) })
    }

    func move(_ clip: ClipSegment, by delta: Int) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let target = index + delta
        guard clips.indices.contains(target) else { return }
        mutate({ clips in clips.swapAt(index, target) })
    }

    func delete(_ clip: ClipSegment) {
        mutate({ clips in clips.removeAll { $0.id == clip.id } })
        selectedClipID = nil
        CSHaptics.cut()
    }

    func setSpeed(_ clip: ClipSegment, _ speed: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        mutate({ clips in clips[index].speed = max(0.25, min(4.0, speed)) })
    }

    /// Live speed update during slider drag (no history per tick).
    func setSpeedLive(_ clip: ClipSegment, _ speed: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var copy = clips
        copy[index].speed = max(0.25, min(4.0, speed))
        clips = copy
        afterClipsChanged()
    }

    func setVolume(_ clip: ClipSegment, volume: Double, muted: Bool) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        mutate({ clips in
            clips[index].volume = max(0, min(2.0, volume))
            clips[index].isMuted = muted
        })
    }

    /// Sets the transition shown at the junction between the previous clip
    /// and the selected one. (First clip's transition applies at timeline
    /// start — no junction — so it's a no-op there.)
    func setTransition(_ clip: ClipSegment, _ type: CSTransition) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        guard index > 0 else { return } // no junction before the first clip
        mutate({ clips in clips[index].transitionIn = type })
    }

    // MARK: - Overlay edits

    func addText(_ text: String) {
        mutateOverlays { list in
            list.append(EditorOverlay(kind: .text(text)))
        }
    }

    func addSticker(_ symbolName: String) {
        mutateOverlays { list in
            list.append(EditorOverlay(kind: .sticker(symbolName), fontSize: 48))
        }
    }

    func updateOverlay(_ overlay: EditorOverlay) {
        if let index = overlays.firstIndex(where: { $0.id == overlay.id }) {
            overlays[index] = overlay
        }
    }

    func deleteOverlay(_ overlay: EditorOverlay) {
        mutateOverlays { list in
            list.removeAll { $0.id == overlay.id }
        }
        CSHaptics.tick()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }
}

// MARK: - Filters (iOS built-in photo effects — bundled with the OS, offline)

enum CSFilter: String, CaseIterable, Identifiable {
    case none, chrome, fade, instant, mono, noir, process, tonal, transfer

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "None"
        case .chrome: "Chrome"
        case .fade: "Fade"
        case .instant: "Instant"
        case .mono: "Mono"
        case .noir: "Noir"
        case .process: "Process"
        case .tonal: "Tonal"
        case .transfer: "Transfer"
        }
    }

    var ciFilterName: String? {
        switch self {
        case .none: nil
        case .chrome: "CIPhotoEffectChrome"
        case .fade: "CIPhotoEffectFade"
        case .instant: "CIPhotoEffectInstant"
        case .mono: "CIPhotoEffectMono"
        case .noir: "CIPhotoEffectNoir"
        case .process: "CIPhotoEffectProcess"
        case .tonal: "CIPhotoEffectTonal"
        case .transfer: "CIPhotoEffectTransfer"
        }
    }
}

// MARK: - Sticker set (SF Symbols, bundled, offline)

extension EditorViewModel {
    static let stickerCatalog: [(String, String)] = [
        ("face.smiling", "Happy"), ("face.dashed", "Meh"), ("heart.fill", "Heart"),
        ("star.fill", "Star"), ("bolt.fill", "Bolt"), ("flame.fill", "Fire"),
        ("hand.thumbsup.fill", "Nice"), ("checkmark.seal.fill", "Check"),
        ("zzz", "Zzz"), ("music.note", "Note"), ("sparkles", "Sparkle"),
        ("crown.fill", "Crown"),
    ]
}

// MARK: - Helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
