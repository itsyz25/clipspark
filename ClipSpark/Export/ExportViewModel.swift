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
        let w = (h * aspect).rounded(.down, toMultipleOf: 2)
        let renderSize = CGSize(width: max(2, w), height: h)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.customVideoCompositorClass = TransitionCompositor.self
        TransitionCompositor.config = TransitionCompositor.Config(junctions: built.junctions, look: model.look)

        // Bake overlays (text/stickers) into the exported frames, offline
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: makeVideoLayer(size: renderSize),
            in: makeOverlayLayer(overlays: model.overlays, size: renderSize)
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
                self.state = .exporting(progress: exportSession.progress)
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
    private func makeOverlayLayer(overlays: [EditorViewModel.EditorOverlay], size: CGSize) -> CALayer {
        let container = CALayer()
        container.frame = CGRect(origin: .zero, size: size)
        let scale = size.height / 400

        for overlay in overlays {
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

            // Position: normalized center coordinates → layer frame center
            let itemSize = itemLayer.bounds.size
            itemLayer.frame.origin = CGPoint(
                x: overlay.x * size.width - itemSize.width / 2,
                y: overlay.y * size.height - itemSize.height / 2
            )
            itemLayer.shadowColor = UIColor.black.cgColor
            itemLayer.shadowOpacity = 0.5
            itemLayer.shadowRadius = 2
            container.addSublayer(itemLayer)
        }
        return container
    }
}
