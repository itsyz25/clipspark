import SwiftUI

/// Multi-track timeline: one video row plus one lane per text/sticker overlay.
///
/// Gestures are deliberately separated so they never fight each other:
///   • drag the playhead flag  → move the playhead itself
///   • drag the film strip     → scrub (content moves under the playhead)
///   • drag an overlay block   → slide that overlay in time
///   • drag an overlay edge    → trim that overlay
///   • pinch                   → zoom around the playhead
///   • tap                     → select a clip/overlay, or park the playhead
struct TimelineView: View {
    @ObservedObject var model: EditorViewModel

    /// Timeline time at the left edge of the viewport.
    @State private var scrollTime: Double = 0
    /// Playhead position inside the viewport, in points.
    @State private var playheadX: CGFloat = 0
    @State private var didLayout = false

    // Drag bookkeeping
    @State private var dragStartTime: Double = 0
    @State private var dragStartPlayheadX: CGFloat = 0
    @State private var dragMode: DragMode = .none
    @State private var overlayDragOrigin: (start: Double, end: Double)?
    @State private var isPinching = false
    @State private var pinchBasePPS: CGFloat = 40

    private enum DragMode: Equatable {
        case none, playhead, scrub
        case overlayBody(UUID), overlayStart(UUID), overlayEnd(UUID)
    }

    private let rulerHeight: CGFloat = 18
    private let videoTop: CGFloat = 21
    private let videoHeight: CGFloat = 46
    private let laneGap: CGFloat = 3
    private let laneHeight: CGFloat = 20

    /// Height the editor should give this view (video row + overlay lanes).
    static func preferredHeight(overlayCount: Int) -> CGFloat {
        let lanes = min(max(overlayCount, 1), 3)
        return 21 + 46 + 6 + CGFloat(lanes) * 23 + 8
    }

    private var totalDuration: Double {
        let fromClips = model.clips.map(\.end).max() ?? 0
        return max(fromClips, model.compositionDuration, 0.1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let pps = model.pixelsPerSecond

            Canvas { ctx, size in
                draw(ctx: &ctx, size: size, w: w, pps: pps)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard !isPinching else { return }
                        handleDragChanged(value, w: w, pps: pps)
                    }
                    .onEnded { value in
                        guard !isPinching else { return }
                        handleDragEnded(value, w: w, pps: pps)
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isPinching {
                            isPinching = true
                            pinchBasePPS = model.pixelsPerSecond
                        }
                        model.setZoom(pinchBasePPS * value)
                    }
                    .onEnded { _ in
                        isPinching = false
                    }
            )
            .onAppear {
                if !didLayout {
                    didLayout = true
                    playheadX = w / 2
                    follow(model.timecode, w: w, pps: pps)
                }
            }
            .onChange(of: model.timecode) { t in
                follow(t, w: w, pps: pps)
            }
            .onChange(of: model.pixelsPerSecond) { _ in
                follow(model.timecode, w: w, pps: model.pixelsPerSecond)
            }
            .onChange(of: model.clips.count) { _ in
                playheadX = w / 2
                follow(model.timecode, w: w, pps: pps)
            }
            // Keep the math honest when the view rotates / resizes.
            .onChange(of: w) { newW in
                playheadX = min(max(newW / 2, 14), newW - 14)
                follow(model.timecode, w: newW, pps: pps)
            }
        }
    }

    // MARK: - Scroll model

    /// Keeps the playhead over the current time: pick the scroll offset so the
    /// playhead sits at `playheadX`, clamping at both ends of the project.
    private func follow(_ t: Double, w: CGFloat, pps: CGFloat) {
        guard w > 1, pps > 1 else { return }
        let totalW = CGFloat(totalDuration) * pps
        let maxScroll = max(0, totalW - w)
        var anchor = playheadX <= 0 ? w / 2 : playheadX
        var scroll = CGFloat(t) * pps - anchor
        if scroll < 0 {
            scroll = 0
            anchor = CGFloat(t) * pps
        } else if scroll > maxScroll {
            scroll = maxScroll
            anchor = CGFloat(t) * pps - maxScroll
        }
        scrollTime = Double(scroll / pps)
        playheadX = min(max(anchor, 10), max(10, w - 10))
    }

    // MARK: - Gestures

    private func hitTest(_ p: CGPoint, w: CGFloat, pps: CGFloat) -> DragMode {
        // 1. Playhead flag (wide grab zone, full height)
        if abs(p.x - playheadX) <= 14 { return .playhead }

        // 2. Overlay lanes
        let lanes = Array(model.overlays.enumerated())
        for (index, overlay) in lanes.prefix(3) {
            let top = videoTop + videoHeight + 6 + CGFloat(index) * (laneHeight + laneGap)
            guard p.y >= top, p.y <= top + laneHeight else { continue }
            let x0 = x(for: overlay.start, pps: pps)
            let x1 = x(for: min(overlay.endTime, totalDuration), pps: pps)
            guard p.x >= x0 - 6, p.x <= x1 + 6 else { continue }
            if abs(p.x - x0) <= 12 { return .overlayStart(overlay.id) }
            if abs(p.x - x1) <= 12 { return .overlayEnd(overlay.id) }
            return .overlayBody(overlay.id)
        }

        // 3. Everything else scrubs.
        return .scrub
    }

    private func handleDragChanged(_ value: DragGesture.Value, w: CGFloat, pps: CGFloat) {
        if dragMode == .none {
            dragMode = hitTest(value.startLocation, w: w, pps: pps)
            dragStartTime = model.timecode
            dragStartPlayheadX = playheadX
            if case .overlayBody(let id) = dragMode,
               let overlay = model.overlays.first(where: { $0.id == id }) {
                overlayDragOrigin = (overlay.start, overlay.endTime)
                model.beginOverlayDrag()
            }
            if case .overlayStart(let id) = dragMode {
                if let overlay = model.overlays.first(where: { $0.id == id }) {
                    overlayDragOrigin = (overlay.start, overlay.endTime)
                }
                model.beginOverlayDrag()
            }
            if case .overlayEnd(let id) = dragMode {
                if let overlay = model.overlays.first(where: { $0.id == id }) {
                    overlayDragOrigin = (overlay.start, overlay.endTime)
                }
                model.beginOverlayDrag()
            }
            if case .playhead = dragMode {
                // Grab exactly where the finger landed, then follow it.
                dragStartPlayheadX = clampX(value.startLocation.x, w: w)
            }
            if case .scrub = dragMode {
                playheadX = w / 2 // scrub around the centre
                follow(dragStartTime, w: w, pps: pps)
            }
        }

        let dx = value.translation.width
        switch dragMode {
        case .playhead:
            let newX = clampX(dragStartPlayheadX + dx, w: w)
            playheadX = newX
            let t = scrollTime + Double(newX / pps)
            model.seek(to: t)

        case .scrub:
            let dt = Double(-dx / pps)
            model.seek(to: dragStartTime + dt)

        case .overlayBody(let id):
            guard let overlay = model.overlays.first(where: { $0.id == id }),
                  let origin = overlayDragOrigin else { return }
            let dt = Double(dx / pps)
            let length = origin.end - origin.start
            let maxStart = max(0, totalDuration - length)
            var copy = overlay
            copy.start = min(max(0, origin.start + dt), maxStart)
            model.updateOverlayLive(copy)

        case .overlayStart(let id):
            guard let overlay = model.overlays.first(where: { $0.id == id }),
                  let origin = overlayDragOrigin else { return }
            model.trimOverlayStart(overlay, at: origin.start + Double(dx / pps))

        case .overlayEnd(let id):
            guard let overlay = model.overlays.first(where: { $0.id == id }),
                  let origin = overlayDragOrigin else { return }
            model.trimOverlayEnd(overlay, at: origin.end + Double(dx / pps))

        case .none:
            break
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, w: CGFloat, pps: CGFloat) {
        let isTap = abs(value.translation.width) < 5 && abs(value.translation.height) < 5
        if isTap {
            handleTap(at: value.startLocation, w: w, pps: pps)
        }
        switch dragMode {
        case .overlayBody(let id), .overlayStart(let id), .overlayEnd(let id):
            model.finalizeOverlayDrag()
            if let overlay = model.overlays.first(where: { $0.id == id }) {
                model.selectOverlay(overlay)
            }
        case .playhead, .scrub:
            // Settle the playhead back to the middle for the next gesture.
            playheadX = w / 2
            follow(model.timecode, w: w, pps: pps)
            if !isTap { CSHaptics.snap() }
        case .none:
            break
        }
        dragMode = .none
        overlayDragOrigin = nil
    }

    private func handleTap(at p: CGPoint, w: CGFloat, pps: CGFloat) {
        let t = clampTime(Double(p.x / pps) + scrollTime)

        // Overlay lane tap → select that overlay
        for (index, overlay) in Array(model.overlays.enumerated()).prefix(3) {
            let top = videoTop + videoHeight + 6 + CGFloat(index) * (laneHeight + laneGap)
            guard p.y >= top, p.y <= top + laneHeight else { continue }
            let x0 = x(for: overlay.start, pps: pps)
            let x1 = x(for: min(overlay.endTime, totalDuration), pps: pps)
            if p.x >= x0 - 6, p.x <= x1 + 6 {
                model.seek(to: max(overlay.start, min(t, overlay.endTime)))
                model.selectOverlay(overlay)
                return
            }
        }

        if p.y > rulerHeight + 2, p.y < videoTop + videoHeight {
            // video row: select the clip under the finger, and seek there
            model.seek(to: t)
            if let row = model.clips.first(where: { t >= $0.start && t < $0.end }) {
                model.select(row)
            } else {
                model.deselectAll()
            }
        } else {
            model.seek(to: t)
            model.deselectAll()
        }
    }

    private func clampX(_ x: CGFloat, w: CGFloat) -> CGFloat {
        min(max(x, 10), max(10, w - 10))
    }

    private func clampTime(_ t: Double) -> Double {
        min(max(0, t), totalDuration)
    }

    // MARK: - Drawing

    private func x(for t: Double, pps: CGFloat) -> CGFloat {
        CGFloat(t - scrollTime) * pps
    }

    private func draw(ctx: inout GraphicsContext, size: CGSize, w: CGFloat, pps: CGFloat) {
        drawRuler(&ctx, size: size, pps: pps)
        drawVideoRow(&ctx, size: size, pps: pps)
        drawOverlayLanes(&ctx, size: size, pps: pps)
        drawPlayhead(&ctx, size: size)
    }

    private func drawRuler(_ ctx: inout GraphicsContext, size: CGSize, pps: CGFloat) {
        // Tick spacing adapts to zoom (never denser than ~44 pt).
        let candidates: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]
        let step = candidates.first { CGFloat($0) * pps >= 44 } ?? 60
        var t = (scrollTime / step).rounded(.down) * step
        let end = scrollTime + Double(size.width / pps)
        while t <= end {
            let px = x(for: t, pps: pps)
            if px >= -20, px <= size.width + 20 {
                var p = Path()
                p.move(to: CGPoint(x: px, y: rulerHeight - 6))
                p.addLine(to: CGPoint(x: px, y: rulerHeight))
                ctx.stroke(p, with: .color(CSTheme.hairline), lineWidth: 1)
                let label = Text(Self.tickLabel(t)).font(CSType.timecode)
                    .foregroundColor(CSTheme.textSecondary)
                ctx.draw(label, at: CGPoint(x: px + 3, y: rulerHeight - 9), anchor: .bottomLeading)
            }
            t += step
        }
    }

    private static func tickLabel(_ t: Double) -> String {
        let total = Int(t.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func drawVideoRow(_ ctx: inout GraphicsContext, size: CGSize, pps: CGFloat) {
        // Track background
        let bg = Path(roundedRect: CGRect(x: 0, y: videoTop, width: size.width, height: videoHeight),
                      cornerRadius: 6)
        ctx.fill(bg, with: .color(CSTheme.surface))

        for (index, clip) in model.clips.enumerated() {
            let start = clip.end > clip.start ? clip.start : 0
            let end = clip.end > clip.start ? clip.end : totalDuration
            let x0 = x(for: start, pps: pps)
            let x1 = x(for: end, pps: pps)
            guard x1 > -20, x0 < size.width + 20 else { continue }
            let rect = CGRect(x: x0 + 1, y: videoTop + 2,
                              width: max(6, x1 - x0 - 2), height: videoHeight - 4)
            let isSelected = clip.id == model.selectedClipID
            let path = Path(roundedRect: rect, cornerRadius: 5)
            ctx.fill(path, with: .color(CSTheme.seedPalette[clip.assetIndex % CSTheme.seedPalette.count]
                .opacity(isSelected ? 0.55 : 0.32)))
            ctx.stroke(path,
                       with: .color(isSelected ? CSTheme.selection : CSTheme.hairline),
                       lineWidth: isSelected ? 2 : 1)

            if rect.width > 34 {
                let label = Text(clip.trimmedDurationText)
                    .font(CSType.timecode).foregroundColor(CSTheme.textPrimary)
                ctx.draw(label, at: CGPoint(x: rect.minX + 5, y: rect.maxY - 4), anchor: .bottomLeading)
            }
            if clip.speed != 1.0, rect.width > 52 {
                let speed = Text(String(format: "%.2fx", clip.speed))
                    .font(CSType.timecode).foregroundColor(CSTheme.accent)
                ctx.draw(speed, at: CGPoint(x: rect.minX + 5, y: rect.minY + 3), anchor: .topLeading)
            }
            if index > 0, clip.transitionIn != .none {
                let badge = Path(ellipseIn: CGRect(x: rect.minX - 5, y: rect.minY + 3, width: 12, height: 12))
                ctx.fill(badge, with: .color(CSTheme.accent))
            }
            if isSelected {
                trimHandle(&ctx, x: rect.minX, top: rect.minY, height: rect.height)
                trimHandle(&ctx, x: rect.maxX - 8, top: rect.minY, height: rect.height)
            }
        }
    }

    private func trimHandle(_ ctx: inout GraphicsContext, x: CGFloat, top: CGFloat, height: CGFloat) {
        let r = CGRect(x: x, y: top + 2, width: 8, height: max(8, height - 4))
        ctx.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(CSTheme.selection))
    }

    private func drawOverlayLanes(_ ctx: inout GraphicsContext, size: CGSize, pps: CGFloat) {
        let visible = Array(model.overlays.enumerated()).prefix(3)
        for (index, overlay) in visible {
            let top = videoTop + videoHeight + 6 + CGFloat(index) * (laneHeight + laneGap)
            // lane background
            let lane = Path(roundedRect: CGRect(x: 0, y: top, width: size.width, height: laneHeight),
                            cornerRadius: 4)
            ctx.fill(lane, with: .color(CSTheme.surface.opacity(0.6)))

            let x0 = x(for: overlay.start, pps: pps)
            let x1 = x(for: min(overlay.endTime, totalDuration), pps: pps)
            guard x1 > -20, x0 < size.width + 20 else { continue }
            let rect = CGRect(x: x0, y: top + 1, width: max(10, x1 - x0), height: laneHeight - 2)
            let selected = overlay.id == model.selectedOverlayID
            let path = Path(roundedRect: rect, cornerRadius: 4)
            let tint = overlay.textValue != nil ? CSTheme.accent : CSTheme.accentViolet
            ctx.fill(path, with: .color(tint.opacity(selected ? 0.9 : 0.55)))
            if selected {
                ctx.stroke(path, with: .color(CSTheme.selection), lineWidth: 2)
                trimHandle(&ctx, x: rect.minX, top: rect.minY, height: rect.height)
                trimHandle(&ctx, x: rect.maxX - 8, top: rect.minY, height: rect.height)
            }
            if rect.width > 24 {
                let name: String = {
                    switch overlay.kind {
                    case .text(let t): return t
                    case .sticker: return "Sticker"
                    }
                }()
                let label = Text(name)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(selected ? .black : CSTheme.textPrimary)
                ctx.draw(label, at: CGPoint(x: rect.minX + 4, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func drawPlayhead(_ ctx: inout GraphicsContext, size: CGSize) {
        let x = min(max(playheadX, 0), size.width)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(CSTheme.accent), lineWidth: 2)

        // Flag (grab handle)
        var flag = Path()
        flag.move(to: CGPoint(x: x - 9, y: 0))
        flag.addLine(to: CGPoint(x: x + 9, y: 0))
        flag.addLine(to: CGPoint(x: x + 9, y: 7))
        flag.addLine(to: CGPoint(x: x + 2, y: 13))
        flag.addLine(to: CGPoint(x: x - 2, y: 13))
        flag.addLine(to: CGPoint(x: x - 9, y: 7))
        flag.closeSubpath()
        ctx.fill(flag, with: .color(CSTheme.accent))
    }
}
