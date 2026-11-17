import Photos
import SwiftUI

/// Horizontal film strip with fixed center playhead. Adds Unit-5 behaviors:
/// tap-to-select, trim handles on the selected clip, haptic boundary snap,
/// and scroll recentering after edits (split/delete/undo).
struct TimelineView: View {
    @ObservedObject var model: EditorViewModel

    private struct OffsetKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = nextValue()
        }
    }

    var body: some View {
        GeometryReader { outer in
            let center = outer.size.width / 2

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(model.clips.enumerated()), id: \.element.id) { index, clip in
                            ClipBlock(
                                clip: clip,
                                pixelsPerSecond: model.pixelsPerSecond,
                                isSelected: clip.id == model.selectedClipID,
                                showsJunctionBadge: index > 0,
                                model: model
                            )
                            .id(clip.id)
                        }
                        Color.clear.frame(width: center)
                    }
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: OffsetKey.self,
                                value: content.frame(in: .named("timeline")).minX
                            )
                        }
                    )
                }
                .coordinateSpace(name: "timeline")
                .scrollDisabled(model.isPlaying)
                .onPreferenceChange(OffsetKey.self) { offset in
                    let time = (center - offset) / model.pixelsPerSecond
                    model.seek(to: time)
                }
                .onChange(of: model.clips) { _ in
                    // Recenter playhead over the edited clip after split/undo etc.
                    guard let target = model.selectedClip ?? model.clips.last else { return }
                    proxy.scrollTo(target.id, anchor: .center)
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(CSTheme.accent)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .position(x: center, y: outer.size.height / 2)
                    .shadow(color: .black.opacity(0.6), radius: 1)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// One clip block: proportional width, selection outline, trim handles with
/// live-duration label (magnifier substitute), tap to select.
private struct ClipBlock: View {
    let clip: EditorViewModel.ClipSegment
    let pixelsPerSecond: CGFloat
    let isSelected: Bool
    let showsJunctionBadge: Bool
    @ObservedObject var model: EditorViewModel

    @State private var dragLabel: String?

    private var width: CGFloat {
        max(24, CGFloat(clip.timelineDuration) * pixelsPerSecond)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous)
                .fill(CSTheme.seedPalette[clip.assetIndex % CSTheme.seedPalette.count].opacity(0.4))
            RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous)
                .strokeBorder(isSelected ? CSTheme.selection : CSTheme.hairline, lineWidth: isSelected ? 2 : 1)
        }
        .frame(width: width, height: 56)
        .overlay(alignment: .bottomTrailing) { durationTag }
            .overlay(alignment: .topLeading) { junctionBadge }
            .overlay { trimHandles }
            .onTapGesture { model.select(isSelected ? nil : clip) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clip \(clip.assetIndex + 1), \(clip.trimmedDurationText), \(isSelected ? "selected" : "")")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var durationTag: some View {
        Text(dragLabel ?? clip.trimmedDurationText)
            .font(CSType.timecode)
            .padding(.horizontal, CSSpacing.xs)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6))
            .clipShape(Capsule())
            .padding(CSSpacing.xs)
    }

    @ViewBuilder
    private var junctionBadge: some View {
        if showsJunctionBadge, clip.transitionIn != .none {
            Image(systemName: clip.transitionIn.symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.black)
                .padding(CSSpacing.xs / 2)
                .background(CSTheme.accent)
                .clipShape(Circle())
                .padding(CSSpacing.xs / 2)
                .accessibilityLabel("Transition \(clip.transitionIn.label) entering this clip")
        }
    }

    @ViewBuilder
    private var trimHandles: some View {
        if isSelected {
            handle(edge: .leading)
            handle(edge: .trailing)
        }
    }

    private func handle(edge: EditorViewModel.TrimEdge) -> some View {
        let alignment: Alignment = edge == .leading ? .leading : .trailing
        return RoundedRectangle(cornerRadius: 3)
            .fill(CSTheme.selection)
            .frame(width: 10, height: 40)
            .overlay {
                Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(CSSpacing.xs)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragLabel == nil { model.beginTrim() } // one undo step per gesture
                        let raw = width + (edge == .trailing ? value.translation.width : -value.translation.width)
                        let seconds = max(0.2, raw / pixelsPerSecond)
                        model.trim(clipID: clip.id, edge: edge, newTimelineSeconds: seconds)
                        dragLabel = String(format: "%.1fs", seconds)
                    }
                    .onEnded { _ in
                        model.finalizeTrim()
                        dragLabel = nil
                        CSHaptics.snap()
                    }
            )
            .accessibilityLabel("Trim handle, \(edge == .leading ? "start" : "end")")
    }
}
