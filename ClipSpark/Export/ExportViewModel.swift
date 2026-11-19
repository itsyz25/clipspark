import AVFoundation
import Combine
import SwiftUI

/// Offline export: rebuilds the same composition the preview uses, runs the
/// custom compositor (transitions + look), bakes text/sticker overlays in via
/// a Core Animation tool, and encodes with hardware AVAssetExportSession.
/// No network at any step.
@MainActor
final class ExportViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting(progress: Double)
        case done(URL)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var height: Int = 1080
    @Published var fps: Int = 30

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    static let heightOptions = [720, 1080, 2160]
    static let fpsOptions = [30, 60]

    func export(model: EditorViewModel) {
        guard case .idle = state else { return }
        model.player.pause() // no concurrent playback during export
        let built = model.buildComposition()
        guard built.duration > 0.1 else {
            state = .failed("Project is empty.")
            return
        }

        // Target render size: keep aspect, set height option (even numbers only)
        let aspect = built.naturalSize.width / built.naturalSize.height
        let h = CGFloat(height)
        let w = (h * aspect / 2).rounded(.down) * 2 // even width
        let renderSize = CGSize(width: max(2, w), height: h)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.customVideoCompositorClass = TransitionCompositor.self
        TransitionCompositor.config = TransitionCompositor.Config(
            junctions: built.junctions,
            spans: built.spans,
            look: model.look
        )

        // Bake overlays (text/stickers) into the exported frames, offline.
        // Timing + transform + layer order match the preview exactly.
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: makeVideoLayer(size: renderSize),
            in: makeOverlayLayer(
                overlays: model.overlays, size: renderSize, duration: built.duration
            )
        )

        let preset: String
        switch height {
        case 720: preset = AVAssetExportPreset1280x720
        case 2160: preset = AVAssetExportPreset3840x2160
        default: preset = AVAssetExportPreset1920x1080
        }

        guard let exportSession = AVAssetExportSession(asset: built.composition, presetName: preset) else {
            state = .failed("Encoder unavailable on this device.")
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClipSpark-\(Int(Date().timeIntervalSince1970)).mp4")
        exportSession.outputURL = url
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        exportSession.audioMix = built.audioMix
        session = exportSession
        state = .exporting(progress: 0)

        // Progress polling (~10 Hz), then completion
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .exporting = self.state else { return }
                self.state = .exporting(progress: Double(exportSession.progress))
            }
        }

        exportSession.exportAsynchronously {
            Task { @MainActor in
                self.progressTimer?.invalidate()
                self.progressTimer = nil
                switch exportSession.status {
                case .completed:
                    CSHaptics.done()
                    self.state = .done(url)
                case .cancelled:
                    self.state = .idle
                default:
                    self.state = .failed(exportSession.error?.localizedDescription ?? "Export failed.")
                }
            }
        }
    }

    func cancel() {
        session?.cancelExport()
        progressTimer?.invalidate()
        progressTimer = nil
        state = .idle
    }

    // MARK: - Overlay baking (Core Animation layers)

    private func makeVideoLayer(size: CGSize) -> CALayer {
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        return layer
    }

    /// Preview canvas ≈ 400pt tall; scale overlay geometry proportionally.
    /// Layers are added in array order, so the stack matches the preview
    /// (last overlay = frontmost). Each overlay gets its own timeline window
    /// via an opacity keyframe animation in composition time.
    private func makeOverlayLayer(
        overlays: [EditorViewModel.EditorOverlay], size: CGSize, duration: Double
    ) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)
        let scale = size.height / 400

        for overlay in overlays {
            guard overlay.isVisible(at: 0) || overlay.start < duration else { continue }
            let itemLayer: CALayer
            switch overlay.kind {
            case .text(let text):
                let textLayer = CATextLayer()
                textLayer.string = text
                textLayer.fontSize = overlay.fontSize * scale
                textLayer.font = UIFont.systemFont(
                    ofSize: textLayer.fontSize,
                    weight: overlay.isBold ? .bold : .regular
                )
                textLayer.foregroundColor = UIColor(overlay.color).cgColor
                textLayer.alignmentMode = .center
                textLayer.contentsGravity = .center
                textLayer.isWrapped = false
                let bounds = (text as NSString).boundingRect(
                    with: CGSize(width: size.width * 0.9, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: UIFont.systemFont(ofSize: textLayer.fontSize, weight: overlay.isBold ? .bold : .regular)],
                    context: nil
                )
                textLayer.bounds = CGRect(
                    x: 0, y: 0,
                    width: max(bounds.width, 10) + 8,
                    height: max(bounds.height, textLayer.fontSize * 1.2) + 4
                )
                itemLayer = textLayer

            case .sticker(let symbolName):
                let imageLayer = CALayer()
                let side = overlay.fontSize * scale
                if let image = UIImage(systemName: symbolName)?
                    .applyingSymbolConfiguration(.init(pointSize: side, weight: .medium)) {
                    imageLayer.contents = image.cgImage
                    imageLayer.contentsGravity = .resize
                }
                imageLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
                itemLayer = imageLayer
            }

            // Center anchor; CA layers are bottom-left origin, so flip the
            // normalized top-down y from the preview.
            itemLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            itemLayer.bounds = CGRect(origin: .zero, size: itemLayer.bounds.size)
            itemLayer.position = CGPoint(
                x: overlay.x * size.width,
                y: (1 - overlay.y) * size.height
            )
            let transform = CATransform3DConcat(
                CATransform3DMakeScale(overlay.scale, overlay.scale, 1),
                CATransform3DMakeRotation(CGFloat(overlay.rotation * .pi / 180), 0, 0, 1)
            )
            itemLayer.transform = transform
            itemLayer.shadowColor = UIColor.black.cgColor
            itemLayer.shadowOpacity = 0.5
            itemLayer.shadowRadius = 2

            let alpha = CGFloat(max(0, min(1, overlay.opacity)))
            if let timing = visibilityAnimation(
                overlay: overlay, total: duration, opacity: alpha
            ) {
                itemLayer.opacity = 0
                itemLayer.add(timing, forKey: "visibility")
            } else {
                itemLayer.opacity = Float(alpha)
            }
            container.addSublayer(itemLayer)
        }
        return container
    }

    /// Opacity keyframes that make a layer visible only inside its window.
    private func visibilityAnimation(
        overlay: EditorViewModel.EditorOverlay, total: Double, opacity: CGFloat
    ) -> CAKeyframeAnimation? {
        guard total > 0.01 else { return nil }
        let shownStart = max(0, min(overlay.start, total))
        let shownEnd = max(shownStart, min(overlay.endTime, total))
        let startsAtZero = shownStart <= 0.0001
        let endsAtTotal = shownEnd >= total - 0.0001
        guard !(startsAtZero && endsAtTotal) else { return nil }

        var times: [Double] = []
        var alphas: [CGFloat] = []
        if startsAtZero {
            times.append(0); alphas.append(opacity)
        } else {
            times.append(0); alphas.append(0)
            times.append(shownStart); alphas.append(opacity)
        }
        if endsAtTotal {
            times.append(max(shownEnd, times.last! + 0.0001)); alphas.append(opacity)
            times.append(total); alphas.append(opacity)
        } else {
            times.append(max(shownEnd, times.last! + 0.0001)); alphas.append(0)
            times.append(max(total, times.last! + 0.0001)); alphas.append(0)
        }

        let anim = CAKeyframeAnimation(keyPath: "opacity")
        anim.values = alphas.map { NSNumber(value: Double($0)) }
        anim.keyTimes = times.map { NSNumber(value: $0 / total) }
        anim.beginTime = AVCoreAnimationBeginTimeAtZero
        anim.duration = total
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.calculationMode = .linear
        return anim
    }
}
