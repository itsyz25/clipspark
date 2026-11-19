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
        /// Per-property keyframes; times are clip-relative timeline seconds.
        var keyframes: [CSKeyframe] = []
        var start: Double = 0
        var end: Double = 0

        var timelineDuration: Double { sourceDuration / speed }

        static func == (lhs: ClipSegment, rhs: ClipSegment) -> Bool {
            lhs.id == rhs.id && lhs.sourceIn == rhs.sourceIn
                && lhs.sourceDuration == rhs.sourceDuration && lhs.speed == rhs.speed
                && lhs.volume == rhs.volume && lhs.isMuted == rhs.isMuted
                && lhs.transitionIn == rhs.transitionIn
                && lhs.keyframes == rhs.keyframes
        }

        var trimmedDurationText: String {
            let s = Int(timelineDuration.rounded())
            return String(format: "%02d:%02d", s / 60, s % 60)
        }
    }

    /// Text/sticker placed over the canvas. Position is normalized (0...1).
    /// Overlays are a stack: array order is z-order (last = frontmost), and
    /// each one has its own timeline window so several can overlap freely.
    struct EditorOverlay: Identifiable, Equatable {
        enum Kind: Equatable { case text(String); case sticker(String) } // sticker = SF Symbol name
        var id = UUID()
        var kind: Kind
        var color: Color = .white
        /// Authored against a 400 pt-tall reference canvas (both preview and
        /// export scale by height/400, so the ratio always matches).
        var fontSize: CGFloat = 34
        var x: CGFloat = 0.5
        var y: CGFloat = 0.5
        var isBold: Bool = true
        // Independent transform + timing (multiple, overlapping overlays)
        var scale: CGFloat = 1
        var rotation: Double = 0          // degrees, clockwise
        var opacity: Double = 1
        var start: Double = 0             // timeline seconds
        var duration: Double? = nil       // nil → until the end of the project

        /// Timeline time at which the overlay stops being visible.
        var endTime: Double { duration.map { start + $0 } ?? .greatestFiniteMagnitude }

        func isVisible(at t: Double) -> Bool { t >= start && t <= endTime }

        static func == (lhs: EditorOverlay, rhs: EditorOverlay) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind
                && lhs.x == rhs.x && lhs.y == rhs.y
                && lhs.fontSize == rhs.fontSize && lhs.color == rhs.color
                && lhs.scale == rhs.scale && lhs.rotation == rhs.rotation
                && lhs.opacity == rhs.opacity && lhs.start == rhs.start
                && lhs.duration == rhs.duration
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
        /// Shutter-style motion blur (0 = off). Radius scales with the amount,
        /// direction comes from `motionBlurAngle`. Real Core Image filter, so
        /// the preview and the exported file are identical.
        var motionBlur: Double = 0        // 0...1
        var motionBlurAngle: Double = 0   // degrees, 0...180
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
    /// Overlay selection is exclusive with clip selection (contextual toolbar).
    @Published var selectedOverlayID: UUID?
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
        lastJunctions = built.junctions
        lastSpans = built.spans
        lastNaturalSize = built.naturalSize

        let item = AVPlayerItem(asset: built.composition)
        if let audioMix = built.audioMix {
            item.audioMix = audioMix
        }
        player.replaceCurrentItem(with: item)
        applyVideoComposition() // custom compositor: transitions + look + keyframes
        seek(to: timecode, animateHaptics: false)
    }

    /// Last built composition state — reused when only the look or keyframe
    /// values change (no structural rebuild needed).
    private var lastJunctions: [TransitionCompositor.Junction] = []
    private var lastSpans: [TransitionCompositor.ClipSpan] = []
    private var lastTrackIDsByClipIndex: [Int: Int32] = [:]
    private var lastNaturalSize: CGSize = CGSize(width: 1280, height: 720)

    /// Shared builder used by BOTH preview and export — a single source of
    /// truth so the exported file always matches what was previewed.
    func buildComposition() -> (composition: AVMutableComposition, junctions: [TransitionCompositor.Junction], spans: [TransitionCompositor.ClipSpan], audioMix: AVAudioMix?, duration: Double, naturalSize: CGSize) {
        let composition = AVMutableComposition()
        var audioMixParams: [AVMutableAudioMixInputParameters] = []
        var junctions: [TransitionCompositor.Junction] = []
        var trackIDsByClipIndex: [Int: Int32] = [:]
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
                let volumeKeyframes = clip.keyframes
                    .filter { $0.property == .volume }
                    .sorted { $0.time < $1.time }
                if volumeKeyframes.isEmpty {
                    params.setVolume(clip.isMuted ? 0 : Float(clip.volume), at: .zero)
                } else {
                    // Keyframed volume: ramps between keyframes, absolute
                    // timeline time = clip start + keyframe time. Mute wins.
                    let muteFactor: Float = clip.isMuted ? 0 : 1
                    let kfs = volumeKeyframes
                    for i in 0..<(kfs.count - 1) {
                        let a = kfs[i], b = kfs[i + 1]
                        params.setVolume(
                            Float(max(0, min(2, a.value))) * muteFactor,
                            at: CMTime(seconds: at + a.time, preferredTimescale: 600)
                        )
                        params.setVolumeRamp(
                            fromStartVolume: Float(max(0, min(2, a.value))) * muteFactor,
                            toEndVolume: Float(max(0, min(2, b.value))) * muteFactor,
                            timeRange: CMTimeRange(
                                start: CMTime(seconds: at + a.time, preferredTimescale: 600),
                                duration: CMTime(seconds: max(0.01, b.time - a.time), preferredTimescale: 600)
                            )
                        )
                    }
                    let last = kfs[kfs.count - 1]
                    params.setVolume(
                        Float(max(0, min(2, last.value))) * muteFactor,
                        at: CMTime(seconds: at + last.time, preferredTimescale: 600)
                    )
                }
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
            trackIDsByClipIndex[index] = compositionTrack.trackID
            lastClip = updated
        }

        var mix: AVAudioMix? = nil
        if !audioMixParams.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = audioMixParams
            mix = audioMix
        }

        // Per-clip spans: identity + keyframes per composition track, so the
        // compositor can apply keyframed transforms/opacity/adjust per frame.
        lastTrackIDsByClipIndex = trackIDsByClipIndex
        var spans: [TransitionCompositor.ClipSpan] = []
        for (index, clip) in clips.enumerated() where !clip.keyframes.isEmpty {
            guard let trackID = trackIDsByClipIndex[index] else { continue }
            spans.append(TransitionCompositor.ClipSpan(
                trackID: trackID,
                start: clip.start,
                end: clip.end,
                keyframes: clip.keyframes
            ))
        }

        return (
            composition: composition,
            junctions: junctions,
            spans: spans,
            audioMix: mix,
            duration: cursor,
            naturalSize: naturalSize
        )
    }

    // MARK: - Video composition (transitions + look, offline, GPU compositor)

    func applyVideoComposition() {
        guard let item = player.currentItem else { return }

        // Fresh spans from current clip state — keyframe edits must show
        // immediately without a structural composition rebuild.
        var spans: [TransitionCompositor.ClipSpan] = []
        for (index, clip) in clips.enumerated() where !clip.keyframes.isEmpty {
            guard let trackID = lastTrackIDsByClipIndex[index], clip.end > clip.start else { continue }
            spans.append(TransitionCompositor.ClipSpan(
                trackID: trackID,
                start: clip.start,
                end: clip.end,
                keyframes: clip.keyframes
            ))
        }
        lastSpans = spans

        let composition = AVMutableVideoComposition()
        composition.renderSize = lastNaturalSize
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.customVideoCompositorClass = TransitionCompositor.self

        TransitionCompositor.config = TransitionCompositor.Config(
            junctions: lastJunctions,
            spans: lastSpans,
            look: look
        )
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
        if clip != nil {
            selectedOverlayID = nil
            CSHaptics.tick()
        }
    }

    // MARK: - Timeline zoom (pinch)

    static let minPixelsPerSecond: CGFloat = 12
    static let maxPixelsPerSecond: CGFloat = 200

    func zoomTimeline(by factor: CGFloat) {
        pixelsPerSecond = min(
            Self.maxPixelsPerSecond,
            max(Self.minPixelsPerSecond, pixelsPerSecond * max(0.2, factor))
        )
    }

    func setZoom(_ value: CGFloat) {
        pixelsPerSecond = min(Self.maxPixelsPerSecond, max(Self.minPixelsPerSecond, value))
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
        left.keyframes = clip.keyframes.filter { $0.time <= localTimelineSeconds }
        var right = clip
        right.id = UUID()
        right.sourceIn = splitSourceIn
        right.sourceDuration = clip.sourceDuration - localTimelineSeconds * clip.speed
        right.keyframes = clip.keyframes
            .filter { $0.time > localTimelineSeconds }
            .map { var kf = $0; kf.time -= localTimelineSeconds; return kf }

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

    // MARK: - Keyframe edits

    func keyframes(on clip: ClipSegment, for property: CSKeyframeProperty) -> [CSKeyframe] {
        clip.keyframes.filter { $0.property == property }.sorted { $0.time < $1.time }
    }

    /// Adds one keyframe at clip-relative seconds `t` (one undo step).
    func addKeyframe(_ clip: ClipSegment, _ property: CSKeyframeProperty, value: Double, at t: Double) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let r = property.range
        let kf = CSKeyframe(
            property: property,
            time: max(0, min(t, clip.timelineDuration)),
            value: max(r.lowerBound, min(r.upperBound, value))
        )
        mutate({ clips in clips[index].keyframes.append(kf) })
        CSHaptics.tick()
    }

    /// Removes one keyframe by id (one undo step).
    func removeKeyframe(_ clip: ClipSegment, _ id: UUID) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        mutate({ clips in
            clips[index].keyframes.removeAll { $0.id == id }
        })
    }

    /// Clears every keyframe of one property (one undo step).
    func removeKeyframes(_ clip: ClipSegment, _ property: CSKeyframeProperty) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        mutate({ clips in
            clips[index].keyframes.removeAll { $0.property == property }
        })
    }

    /// Single-shot keyframe update (one undo step).
    func updateKeyframe(_ clip: ClipSegment, _ kf: CSKeyframe) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        mutate({ clips in
            if let i = clips[index].keyframes.firstIndex(where: { $0.id == kf.id }) {
                clips[index].keyframes[i] = kf
            }
        })
    }

    // Live drag support: snapshot at gesture start, no history per tick.

    func beginKeyframeDrag() { keyframeDragBaseline = currentState }

    func finalizeKeyframeDrag() {
        guard keyframeDragBaseline != nil else { return }
        undoStack.append(keyframeDragBaseline!)
        if undoStack.count > maxHistory { undoStack.removeFirst() }
        redoStack.removeAll()
        keyframeDragBaseline = nil
        syncUndoFlags()
    }

    private var keyframeDragBaseline: ProjectState?

    /// Live keyframe move during a drag. Volume keyframes need an audio-mix
    /// rebuild; all other properties only need a compositor config refresh.
    func updateKeyframeLive(_ clip: ClipSegment, _ kf: CSKeyframe) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        var copy = clips
        if let i = copy[index].keyframes.firstIndex(where: { $0.id == kf.id }) {
            copy[index].keyframes[i] = kf
        }
        clips = copy
        if kf.property == .volume {
            afterClipsChanged()
        } else {
            applyVideoComposition()
        }
    }

    /// Cheap path when keyframe VALUES change outside a drag (inspector sliders).
    func refreshKeyframes() {
        applyVideoComposition()
        if let clip = selectedClip, clip.keyframes.contains(where: { $0.property == .volume }) {
            afterClipsChanged() // volume ramps live in the audio mix
        }
    }

    // MARK: - Overlay edits (multiple, stacked, independently timed)

    /// Default on-screen life for a new overlay: from the playhead, 3 s long
    /// (clamped to the project) so several overlays can overlap freely.
    private var defaultOverlayWindow: (start: Double, duration: Double?) {
        let total = compositionDuration > 0 ? compositionDuration : 5
        let start = min(max(0, timecode), max(0, total - 0.5))
        let remaining = total - start
        return (start, remaining > 0.5 ? min(3, remaining) : nil)
    }

    func addText(_ text: String, color: Color? = nil) {
        let window = defaultOverlayWindow
        var overlay = EditorOverlay(kind: .text(text))
        overlay.start = window.start
        overlay.duration = window.duration
        if let color { overlay.color = color }
        mutateOverlays { $0.append(overlay) }
        selectOverlay(overlay)
    }

    func addSticker(_ symbolName: String) {
        let window = defaultOverlayWindow
        var overlay = EditorOverlay(kind: .sticker(symbolName), fontSize: 60)
        overlay.start = window.start
        overlay.duration = window.duration
        mutateOverlays { $0.append(overlay) }
        selectOverlay(overlay)
    }

    var selectedOverlay: EditorOverlay? {
        guard let selectedOverlayID else { return nil }
        return overlays.first { $0.id == selectedOverlayID }
    }

    func selectOverlay(_ overlay: EditorOverlay?) {
        selectedOverlayID = overlay?.id
        if overlay != nil {
            selectedClipID = nil
            CSHaptics.tick()
        }
    }

    func deselectAll() {
        selectedClipID = nil
        selectedOverlayID = nil
    }

    /// Overlays visible at a given timeline time, back-to-front (z-order).
    func visibleOverlays(at t: Double) -> [EditorOverlay] {
        overlays.filter { $0.isVisible(at: t) }
    }

    /// Committed overlay edit (one undo step). Used by drawers/pickers.
    func updateOverlay(_ overlay: EditorOverlay) {
        mutateOverlays { list in
            if let index = list.firstIndex(where: { $0.id == overlay.id }) {
                list[index] = overlay
            }
        }
    }

    /// Live gesture path (drag / pinch / rotate): no history write per tick.
    func updateOverlayLive(_ overlay: EditorOverlay) {
        if let index = overlays.firstIndex(where: { $0.id == overlay.id }) {
            overlays[index] = overlay
        }
    }

    func duplicateOverlay(_ overlay: EditorOverlay) {
        var copy = overlay
        copy.id = UUID()
        copy.x = min(1, overlay.x + 0.04)
        copy.y = min(1, overlay.y + 0.04)
        mutateOverlays { $0.append(copy) }
        selectOverlay(copy)
    }

    func deleteOverlay(_ overlay: EditorOverlay) {
        mutateOverlays { list in
            list.removeAll { $0.id == overlay.id }
        }
        if selectedOverlayID == overlay.id { selectedOverlayID = nil }
        CSHaptics.tick()
    }

    // MARK: - Overlay stacking + timing

    func bringOverlayForward(_ overlay: EditorOverlay) { moveOverlay(overlay, by: 1) }
    func sendOverlayBackward(_ overlay: EditorOverlay) { moveOverlay(overlay, by: -1) }

    /// Array order is z-order: later == drawn on top.
    private func moveOverlay(_ overlay: EditorOverlay, by delta: Int) {
        guard let index = overlays.firstIndex(where: { $0.id == overlay.id }) else { return }
        let target = index + delta
        guard overlays.indices.contains(target) else { return }
        mutateOverlays { $0.swapAt(index, target) }
        CSHaptics.tick()
    }

    /// Trim the overlay's in-point to the given timeline time.
    func trimOverlayStart(_ overlay: EditorOverlay, at t: Double) {
        let end = overlay.endTime
        let newStart = min(max(0, t), max(0, end - 0.1))
        var copy = overlay
        copy.start = newStart
        if overlay.duration != nil { copy.duration = max(0.1, end - newStart) }
        updateOverlayLive(copy)
    }

    /// Trim the overlay's out-point to the given timeline time.
    func trimOverlayEnd(_ overlay: EditorOverlay, at t: Double) {
        var copy = overlay
        copy.duration = max(0.1, t - overlay.start)
        updateOverlayLive(copy)
    }

    /// "Start here" / "End here" at the playhead (one undo step each).
    func overlayStartAtPlayhead(_ overlay: EditorOverlay) {
        let end = overlay.endTime
        var copy = overlay
        copy.start = min(max(0, timecode), max(0, end - 0.1))
        updateOverlay(copy)
    }

    func overlayEndAtPlayhead(_ overlay: EditorOverlay) {
        var copy = overlay
        copy.duration = max(0.1, timecode - overlay.start)
        updateOverlay(copy)
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
