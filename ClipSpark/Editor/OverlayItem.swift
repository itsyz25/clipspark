import SwiftUI

/// Which bottom drawer is open in the editor.
enum EditorDrawer: Equatable {
    case text, sticker, filter, audio, transitions, inspector, keyframes, overlay
}

/// One text/sticker overlay on the canvas.
///
/// Overlays are independent: each has its own position, scale, rotation,
/// opacity and timeline window, and they stack in `model.overlays` order.
/// Every gesture is live (no history write per tick); the undo step is
/// committed once when the gesture ends.
struct OverlayItem: View {
    let overlay: EditorViewModel.EditorOverlay
    @ObservedObject var model: EditorViewModel
    let canvasSize: CGSize

    @State private var gestureStart: EditorViewModel.EditorOverlay?
    @State private var resizeStart: CGFloat = 1
    @State private var rotationStart: Double = 0

    private var isSelected: Bool { overlay.id == model.selectedOverlayID }

    var body: some View {
        content
            .padding(6)
            .background(alignment: .center) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CSTheme.selection,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .overlay { if isSelected { chrome } }
            .scaleEffect(overlay.scale)
            .rotationEffect(.degrees(overlay.rotation))
            .opacity(overlay.opacity)
            .position(x: overlay.x * canvasSize.width, y: overlay.y * canvasSize.height)
            .contentShape(Rectangle())
            .onTapGesture { model.selectOverlay(overlay) }
            .gesture(moveGesture)
            .simultaneousGesture(pinchGesture)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(overlay.textValue ?? "Sticker") overlay, selected: \(isSelected)")
    }

    @ViewBuilder
    private var content: some View {
        // Overlay type sizes are authored against a 400 pt-tall reference
        // canvas — the exact same ratio the export uses (renderHeight / 400),
        // so what you see is what gets exported.
        let typeScale = max(0.2, canvasSize.height / 400)
        switch overlay.kind {
        case .text(let text):
            Text(text)
                .font(.system(size: overlay.fontSize * typeScale,
                              weight: overlay.isBold ? .bold : .regular))
                .foregroundStyle(overlay.color)
                .shadow(color: .black.opacity(0.55), radius: 2)
                .fixedSize()
        case .sticker(let symbol):
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: overlay.fontSize * typeScale, weight: .medium))
                .foregroundStyle(overlay.color)
                .shadow(color: .black.opacity(0.55), radius: 2)
        }
    }

    // MARK: - Selection chrome (resize corners, rotate handle, delete)

    private var chrome: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                corner(0, 0)
                corner(w, 0)
                corner(0, h)
                corner(w, h)
                rotateHandle
                    .offset(y: -h / 2 - 22)
                deleteHandle
                    .offset(x: -w / 2 - 4, y: -h / 2 - 4)
            }
            .frame(width: w, height: h)
        }
    }

    private func corner(_ x: CGFloat, _ y: CGFloat) -> some View {
        Circle()
            .fill(CSTheme.selection)
            .frame(width: 12, height: 12)
            .position(x: x, y: y)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if gestureStart == nil {
                            gestureStart = overlay
                            resizeStart = overlay.scale
                            model.beginOverlayDrag()
                        }
                        let delta = (value.translation.width + value.translation.height) / 160
                        var updated = overlay
                        updated.scale = min(5, max(0.15, resizeStart + delta))
                        model.updateOverlayLive(updated)
                    }
                    .onEnded { _ in
                        model.finalizeOverlayDrag()
                        gestureStart = nil
                        CSHaptics.snap()
                    }
            )
    }

    private var rotateHandle: some View {
        ZStack {
            Circle().fill(CSTheme.selection).frame(width: 22, height: 22)
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    if gestureStart == nil {
                        gestureStart = overlay
                        rotationStart = overlay.rotation
                        model.beginOverlayDrag()
                    }
                    var updated = overlay
                    updated.rotation = rotationStart + Double(value.translation.width) * 0.9
                    model.updateOverlayLive(updated)
                }
                .onEnded { _ in
                    model.finalizeOverlayDrag()
                    gestureStart = nil
                    CSHaptics.snap()
                }
        )
        .accessibilityLabel("Rotate overlay")
    }

    private var deleteHandle: some View {
        Button {
            model.deleteOverlay(overlay)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(CSTheme.danger)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Delete overlay")
    }

    // MARK: - Gestures

    private var moveGesture: some View {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = overlay
                    model.beginOverlayDrag()
                    model.selectOverlay(overlay)
                }
                guard let base = gestureStart, canvasSize.width > 1, canvasSize.height > 1 else { return }
                var updated = base
                updated.x = min(max(0.02, base.x + value.translation.width / canvasSize.width), 0.98)
                updated.y = min(max(0.02, base.y + value.translation.height / canvasSize.height), 0.98)
                model.updateOverlayLive(updated)
            }
            .onEnded { _ in
                model.finalizeOverlayDrag()
                gestureStart = nil
                CSHaptics.snap()
            }
    }

    private var pinchGesture: some View {
        MagnificationGesture()
            .onChanged { value in
                if gestureStart == nil {
                    gestureStart = overlay
                    resizeStart = overlay.scale
                    model.beginOverlayDrag()
                    model.selectOverlay(overlay)
                }
                var updated = overlay
                updated.scale = min(5, max(0.15, resizeStart * value))
                model.updateOverlayLive(updated)
            }
            .onEnded { _ in
                model.finalizeOverlayDrag()
                gestureStart = nil
            }
    }
}
