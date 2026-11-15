import SwiftUI

/// Which bottom drawer is open in the editor.
enum EditorDrawer: Equatable {
    case text, sticker, filter, audio, transitions, inspector
}

/// A text/sticker overlay rendered on the canvas. Drag moves it (normalized
/// coordinates survive orientation & export scaling); tap selects, double-tap
/// deletes. Drag = one undo step (baseline pattern).
struct OverlayItem: View {
    let overlay: EditorViewModel.EditorOverlay
    @ObservedObject var model: EditorViewModel
    let canvasSize: CGSize

    var body: some View {
        content
            .font(.system(size: overlay.fontSize, weight: overlay.isBold ? .bold : .regular))
            .foregroundStyle(overlay.color)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .position(x: overlay.x * canvasSize.width, y: overlay.y * canvasSize.height)
            .onTapGesture { model.deleteOverlay(overlay) }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = overlay
                            model.beginOverlayDrag()
                        }
                        var updated = overlay
                        updated.x = max(0, min(1, (dragStart!.x * canvasSize.width + value.translation.width) / canvasSize.width))
                        updated.y = max(0, min(1, (dragStart!.y * canvasSize.height + value.translation.height) / canvasSize.height))
                        model.updateOverlay(updated)
                    }
                    .onEnded { _ in
                        model.finalizeOverlayDrag()
                        dragStart = nil
                        CSHaptics.snap()
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Overlay\(overlay.textValue.map { ": \($0)" } ?? ""), drag to move, double-tap to delete")
    }

    @State private var dragStart: EditorViewModel.EditorOverlay?

    @ViewBuilder
    private var content: some View {
        switch overlay.kind {
        case .text(let text):
            Text(text)
        case .sticker(let symbol):
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
        }
    }
}
