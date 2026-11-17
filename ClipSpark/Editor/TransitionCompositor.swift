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

    struct Config {
        var junctions: [Junction] = []
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
        let context = request.renderContext

        var image: CIImage?

        if let junction = config.junctions.first(where: { time >= $0.time && time < $0.time + $0.duration }) {
            let outFrame = request.sourceFrame(byTrackID: junction.outTrack).map(CIImage.init(cvPixelBuffer:))
            let inFrame = request.sourceFrame(byTrackID: junction.inTrack).map(CIImage.init(cvPixelBuffer:))
            let progress = (time - junction.time) / max(junction.duration, 0.001)
            image = blend(
                out: outFrame, incoming: inFrame,
                type: junction.type, progress: progress,
                size: context.size
            )
        } else {
            // Single visible clip: take whichever track has a frame.
            for trackIDValue in request.sourceTrackIDs {
                let trackID = trackIDValue.int32Value
                if let frame = request.sourceFrame(byTrackID: trackID) {
                    image = CIImage(cvPixelBuffer: frame)
                    break
                }
            }
        }

        guard var finalImage = image else {
            // No frame available: finish with a black frame so the pipeline
            // keeps flowing (CoreImage constant black, cropped to render size).
            finish(
                with: CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                    .cropped(to: CGRect(origin: .zero, size: context.size)),
                request: request
            )
            return
        }

        finalImage = Self.applyLook(config.look, to: finalImage)
        finish(with: finalImage, request: request)
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
