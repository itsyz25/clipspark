import AVFoundation
import CoreImage

/// Offline transition types. Every blend is computed in the compositor from
/// the two overlapping clips' own frames — no assets, no network.
enum CSTransition: String, CaseIterable, Equatable {
    case none, crossfade, pushLeft, pushRight, fadeBlack

    var label: String {
        switch self {
        case .none: "None"
        case .crossfade: "Dissolve"
        case .pushLeft: "Push →"
        case .pushRight: "Push ←"
        case .fadeBlack: "Black dip"
        }
    }

    /// Default junction length (seconds); clamped per junction to half of
    /// each neighboring clip so it can never exceed a clip's length.
    var duration: Double {
        switch self {
        case .none: 0
        case .crossfade, .fadeBlack: 0.5
        case .pushLeft, .pushRight: 0.4
        }
    }
    /// Small SF Symbol representing the transition type (timeline badge).
    var symbol: String {
        switch self {
        case .none: ""
        case .crossfade: "arrow.triangle.2.circlepath"
        case .pushLeft: "arrow.right.square"
        case .pushRight: "arrow.left.square"
        case .fadeBlack: "circle.lefthalf.filled"
        }
    }
}

/// Custom video compositor: renders the timeline frame-by-frame.
/// - Outside junctions: shows whichever track has a frame at that time.
/// - Inside a junction: blends outgoing/incoming per the transition type.
/// - Applies the project Look (brightness/contrast/saturation + photo-effect
///   filter) to every frame — replacing the previous CIFilter handler path.
final class TransitionCompositor: NSObject, AVVideoCompositing {
    struct Junction: Equatable {
        let time: Double
        let duration: Double
        let type: CSTransition
        let outTrack: Int32
        let inTrack: Int32
    }

    /// One clip's timeline window + its keyframes, keyed by composition
    /// track. Lets the compositor keyframe-transform each track's frames.
    struct ClipSpan {
        let trackID: Int32
        let start: Double
        let end: Double
        let keyframes: [CSKeyframe]
    }

    struct Config {
        var junctions: [Junction] = []
        var spans: [ClipSpan] = []
        var look = EditorViewModel.Look()
    }

    /// Injection point: rebuilt before the player item is swapped in.
    static var config = Config()

    // MARK: AVVideoCompositing

    var sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelFormatType_32BGRA,
        ],
    ]

    var requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferOpenGLESCompatibilityKey as String: true,
    ]

    func renderContextChanged(_ renderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let config = Self.config
        let time = request.compositionTime.seconds

        // Per-track preprocessing: keyframed transform/opacity + look. Every
        // frame belongs to exactly one clip, so the project look applies
        // per track (identical result to post-blend when unkeyed).
        func processedFrame(_ trackID: Int32) -> CIImage? {
            guard let frame = request.sourceFrame(byTrackID: trackID) else { return nil }
            let span = config.spans.first { $0.trackID == trackID }
            let localTime = span.map { max(0, min(time - $0.start, $0.end - $0.start)) } ?? time
            return Self.applyKeyframes(
                span?.keyframes ?? [], at: localTime, look: config.look,
                to: CIImage(cvPixelBuffer: frame)
            )
        }

        var image: CIImage?

        if let junction = config.junctions.first(where: { time >= $0.time && time < $0.time + $0.duration }) {
            let progress = (time - junction.time) / max(junction.duration, 0.001)
            image = blend(
                out: processedFrame(junction.outTrack),
                incoming: processedFrame(junction.inTrack),
                type: junction.type, progress: progress,
                size: request.renderContext.size
            )
        } else {
            // Single visible clip: take whichever track has a frame.
            for trackIDValue in request.sourceTrackIDs {
                if let frame = processedFrame(trackIDValue.int32Value) {
                    image = frame
                    break
                }
            }
        }

        guard let finalImage = image else {
            // No frame available: finish with a black frame so the pipeline
            // keeps flowing (CoreImage constant black, cropped to render size).
            finish(
                with: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                    .cropped(to: CGRect(origin: .zero, size: request.renderContext.size)),
                request: request
            )
            return
        }

        finish(with: finalImage, request: request)
    }

    /// Keyframed clip pass: scale / rotation / position / opacity evaluated
    /// at `t` (clip-relative seconds) and baked into the frame, then the
    /// effective look (project look with adjust values overridden by any
    /// brightness/contrast/saturation keyframes).
    static func applyKeyframes(
        _ keyframes: [CSKeyframe], at t: Double, look: EditorViewModel.Look, to image: CIImage
    ) -> CIImage {
        guard !keyframes.isEmpty else { return applyLook(look, to: image) }

        func value(_ property: CSKeyframeProperty, _ base: Double) -> Double {
            CSKeyframeEvaluator.evaluate(keyframes, property, staticBase: base, at: t)
        }

        let extent = image.extent
        let scale = value(.scale, 1)
        let rotation = value(.rotation, 0)
        let posX = value(.posX, 0)
        let posY = value(.posY, 0)
        let opacity = value(.opacity, 1)

        var transform = CGAffineTransform.identity
        transform = transform.translatedBy(x: extent.midX, y: extent.midY)
        transform = transform.rotated(by: rotation * .pi / 180)
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: -extent.midX, y: -extent.midY)
        transform = transform.translatedBy(x: posX * extent.width, y: posY * extent.height)
        var result = image.transformed(by: transform)

        if opacity < 0.999 {
            result = result.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: max(0, opacity)),
            ])
        }

        let effective = EditorViewModel.Look(
            filter: look.filter,
            brightness: keyframes.contains { $0.property == .brightness }
                ? value(.brightness, look.brightness) : look.brightness,
            contrast: keyframes.contains { $0.property == .contrast }
                ? value(.contrast, look.contrast) : look.contrast,
            saturation: keyframes.contains { $0.property == .saturation }
                ? value(.saturation, look.saturation) : look.saturation
        )
        return applyLook(effective, to: result)
    }

    /// The request API only accepts pixel buffers, so CIImages are rendered
    /// here (CI bottom-left origin flipped into buffer top-left space).
    private func finish(with image: CIImage, request: AVAsynchronousVideoCompositionRequest) {
        guard let buffer = request.renderContext.newPixelBuffer() else { return }
        let h = CGFloat(CVPixelBufferGetHeight(buffer))
        let flipped = image.transformed(
            by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: h)
        )
        let bounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(CVPixelBufferGetWidth(buffer)),
            height: h
        )
        Self.ciContext.render(flipped, to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: buffer)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Blends (all computed locally from the two source frames)

    private func blend(
        out: CIImage?, incoming: CIImage?, type: CSTransition, progress: Double, size: CGSize
    ) -> CIImage? {
        // Missing frames degrade gracefully: fall back to whichever exists.
        guard let out, let incoming else { return out ?? incoming }

        switch type {
        case .none:
            return incoming

        case .crossfade:
            let fadeIn = incoming.applyingFilter("CIColorMatrix", parameters: [
                "inputAlphaVector": CIVector(x: 0, y: 0, z: 0, w: progress),
            ])
            return out.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputImageKey: fadeIn,
                kCIInputBackgroundImageKey: out,
            ])

        case .pushLeft: // incoming slides in from the right
            let dx = size.width * (1 - progress)
            let outgoing = out.transformed(by: CGAffineTransform(translationX: -size.width * progress, y: 0))
            let entering = incoming.transformed(by: CGAffineTransform(translationX: dx, y: 0))
            return outgoing.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputImageKey: entering,
                kCIInputBackgroundImageKey: outgoing,
            ])

        case .pushRight:
            let dx = size.width * (progress - 1)
            let outgoing = out.transformed(by: CGAffineTransform(translationX: size.width * progress, y: 0))
            let entering = incoming.transformed(by: CGAffineTransform(translationX: dx, y: 0))
            return outgoing.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputImageKey: entering,
                kCIInputBackgroundImageKey: outgoing,
            ])

        case .fadeBlack:
            let black = CIImage(color: CIColor.black).cropped(to: out.extent)
            if progress < 0.5 {
                let overlay = black.applyingFilter("CIColorMatrix", parameters: [
                    "inputAlphaVector": CIVector(x: 0, y: 0, z: 0, w: progress * 2),
                ])
                return out.applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputImageKey: overlay,
                    kCIInputBackgroundImageKey: out,
                ])
            } else {
                let overlay = black.applyingFilter("CIColorMatrix", parameters: [
                    "inputAlphaVector": CIVector(x: 0, y: 0, z: 0, w: (1 - progress) * 2),
                ])
                return incoming.applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputImageKey: overlay,
                    kCIInputBackgroundImageKey: incoming,
                ])
            }
        }
    }

    /// Look pass shared by every rendered frame (same params as before,
    /// now applied inside the compositor so it composes with transitions).
    static func applyLook(_ look: EditorViewModel.Look, to image: CIImage) -> CIImage {
        var result = image
        if look.brightness != 0 || look.contrast != 1 || look.saturation != 1 {
            result = result.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: look.brightness,
                kCIInputContrastKey: look.contrast,
                kCIInputSaturationKey: look.saturation,
            ])
        }
        if let filterName = look.filter.ciFilterName {
            result = result.applyingFilter(filterName)
        }
        return result
    }
}
