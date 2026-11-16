import SwiftUI

/// Bottom drawer for the selected clip: Split · Duplicate · Move · Speed · Delete.
/// (Volume/animation/adjust arrive with the Unit-6 drawers.)
struct ClipInspector: View {
    @ObservedObject var model: EditorViewModel
    let clip: EditorViewModel.ClipSegment

    @State private var speed: Double = 1.0

    var body: some View {
        VStack(spacing: CSSpacing.s) {
            CSGrabber()

            HStack(spacing: CSSpacing.m) {
                inspectorButton(.split, "Split", model.splitAtPlayhead)
                inspectorButton(.duplicate, "Duplicate") { model.duplicate(clip) }
                inspectorButton(.undo, "Move left") { model.move(clip, by: -1) }
                inspectorButton(.redo, "Move right") { model.move(clip, by: 1) }
                inspectorButton(.delete, "Delete", style: .danger) { model.delete(clip) }
            }
            .padding(.horizontal, CSSpacing.l)

            // Speed curve lite: single slider this unit
            HStack(spacing: CSSpacing.m) {
                Text("Speed").font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
                Slider(value: Binding(
                    get: { speed },
                    set: { newValue in
                        speed = newValue
                        model.setSpeedLive(clip, newValue)
                    }
                ), in: 0.25...4.0)
                Text("\(String(format: "%.2f", speed))×")
                    .font(CSType.timecode)
                    .foregroundStyle(CSTheme.accent)
                    .monospacedDigit()
                    .frame(width: 48)
            }
            .padding(.horizontal, CSSpacing.l)
            .padding(.bottom, CSSpacing.m)
        }
        .background(
            CSTheme.surfaceHigh
                .clipShape(RoundedCorners(radius: CSRadius.sheet, corners: [.topLeft, .topRight]))
                .ignoresSafeArea(edges: .bottom)
        )
        .onAppear {
            speed = clip.speed
            model.beginLookChange() // one undo step covers this drawer session
        }
        .onDisappear { model.finalizeLookChange() }
        .onChange(of: clip.speed) { newSpeed in
            speed = newSpeed // stay in sync after undo/redo
        }
    }

    private enum ButtonStyle { case standard, danger }

    private func inspectorButton(
        _ icon: CSIcon, _ label: String, style: ButtonStyle = .standard, action: @escaping () -> Void
    ) -> some View {
        Button {
            CSHaptics.tick()
            action()
        } label: {
            VStack(spacing: CSSpacing.xs) {
                icon.symbol.font(.system(size: 18, weight: .medium))
                Text(label).font(CSType.chip)
            }
            .foregroundStyle(style == .danger ? CSTheme.danger : CSTheme.textPrimary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Corner-radius helper for the drawer's rounded top.
struct RoundedCorners: Shape {
    var radius: CGFloat
    var corners: UIRectCorner

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        ).cgPath)
    }
}
