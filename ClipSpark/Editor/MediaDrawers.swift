import SwiftUI

// MARK: - Generic drawer host (rounded top, grabber, close)
// All tool drawers share this container, per the design spec.

struct CSDrawerContainer<Content: View>: View {
    let title: String
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: CSSpacing.m) {
            CSGrabber()
            HStack {
                Text(title).font(CSType.title)
                Spacer()
                Button {
                    CSHaptics.tick()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CSTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(CSTheme.surface)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close \(title)")
            }
            .padding(.horizontal, CSSpacing.l)

            content
                .padding(.bottom, CSSpacing.l + CSSpacing.m)
        }
        .background(
            CSTheme.surfaceHigh
                .clipShape(RoundedCorners(radius: CSRadius.sheet, corners: [.topLeft, .topRight]))
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

// MARK: - Text drawer

struct TextDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void
    @State private var draft = ""

    private let swatchColors: [Color] = [.white, .black, CSTheme.accent, CSTheme.selection, .red, .blue, .yellow, .green]

    var body: some View {
        CSDrawerContainer(title: "Text", onClose: onClose) {
            VStack(alignment: .leading, spacing: CSSpacing.m) {
                TextField("Your text", text: $draft)
                    .font(CSType.body)
                    .padding(CSSpacing.m)
                    .background(CSTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2))
                    .submitLabel(.done)
                    .onSubmit(add)

                HStack(spacing: CSSpacing.s) {
                    ForEach(swatchColors, id: \.self) { color in
                        ZStack {
                            Circle().fill(color)
                            Circle().strokeBorder(CSTheme.hairline, lineWidth: 1)
                        }
                        .frame(width: 28, height: 28)
                        .onTapGesture { colorPicked(color) }
                        .accessibilityLabel("Text color")
                    }
                    Spacer()
                    CSPrimaryButton("Add", icon: .text) { add() }
                }
            }
            .padding(.horizontal, CSSpacing.l)
        }
    }

    private func colorPicked(_ color: Color) {
        if let last = model.overlays.last(where: { $0.textValue != nil }) {
            var updated = last
            updated.color = color
            model.updateOverlay(updated)
        }
        nextColor = color
        CSHaptics.tick()
    }

    @State private var nextColor: Color?

    private func add() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // addText() gives the new overlay its own timeline window at the
        // playhead and selects it (one undo step).
        model.addText(trimmed, color: nextColor)
        draft = ""
        CSHaptics.done()
    }
}

// MARK: - Sticker drawer

struct StickerDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    var body: some View {
        CSDrawerContainer(title: "Stickers", onClose: onClose) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: CSSpacing.m), count: 4), spacing: CSSpacing.m) {
                ForEach(EditorViewModel.stickerCatalog, id: \.0) { symbol, name in
                    Button {
                        model.addSticker(symbol)
                        CSHaptics.done()
                    } label: {
                        VStack(spacing: CSSpacing.xs) {
                            Image(systemName: symbol)
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(CSTheme.accent)
                            Text(name).font(CSType.chip)
                                .foregroundStyle(CSTheme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CSSpacing.s)
                        .background(CSTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(name) sticker")
                }
            }
            .padding(.horizontal, CSSpacing.l)
        }
    }
}

// MARK: - Filters + Adjust drawer (live preview, all offline)

struct FilterDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    var body: some View {
        CSDrawerContainer(title: "Filters", onClose: onClose) {
            VStack(alignment: .leading, spacing: CSSpacing.m) {
                // Presets
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CSSpacing.s) {
                        ForEach(CSFilter.allCases) { filter in
                            CSToolChip(.filter, filter.label, isSelected: model.look.filter == filter) {
                                model.beginLookChange()
                                var look = model.look
                                look.filter = filter
                                model.setLook(look)
                                model.finalizeLookChange() // preset tap = one undo step
                            }
                        }
                    }
                }

                // Adjust sliders (instant, GPU preview; one gesture = one undo step)
                VStack(spacing: CSSpacing.m) {
                    adjustSlider("Brightness", value: Binding(
                        get: { model.look.brightness },
                        set: { v in model.updateLookLive { $0.brightness = v } }
                    ), range: -0.2...0.2, format: { String(format: "%+.0f%%", $0 * 100) })
                    adjustSlider("Contrast", value: Binding(
                        get: { model.look.contrast },
                        set: { v in model.updateLookLive { $0.contrast = v } }
                    ), range: 0.5...1.5, format: { String(format: "%.2f×", $0) })
                    adjustSlider("Saturation", value: Binding(
                        get: { model.look.saturation },
                        set: { v in model.updateLookLive { $0.saturation = v } }
                    ), range: 0...2, format: { String(format: "%.0f%%", $0 * 100) })

                    // Genuine motion blur: Core Image in the shared compositor,
                    // so the preview and the exported file match exactly.
                    adjustSlider("Motion blur", value: Binding(
                        get: { model.look.motionBlur },
                        set: { v in model.updateLookLive { $0.motionBlur = v } }
                    ), range: 0...1, format: { $0 < 0.005 ? "Off" : String(format: "%.0f%%", $0 * 100) })

                    if model.look.motionBlur > 0.004 {
                        adjustSlider("Blur angle", value: Binding(
                            get: { model.look.motionBlurAngle },
                            set: { v in model.updateLookLive { $0.motionBlurAngle = v } }
                        ), range: 0...180, format: { String(format: "%.0f°", $0) })
                    }
                }
                .padding(.horizontal, CSSpacing.l)
                .onAppear { model.beginLookChange() } // baseline at drawer open
                .onDisappear { model.finalizeLookChange() } // commit when leaving
            }
        }
    }

    private func adjustSlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>, format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: CSSpacing.m) {
            Text(label).font(CSType.body).foregroundStyle(CSTheme.textSecondary)
                .frame(width: 84, alignment: .leading)
            Slider(value: value, in: range)
            Text(format(value.wrappedValue))
                .font(CSType.timecode)
                .foregroundStyle(CSTheme.accent)
                .monospacedDigit()
                .frame(width: 52)
        }
    }
}

// MARK: - Transitions drawer (offline GPU blends between clips)

struct TransitionsDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    var body: some View {
        CSDrawerContainer(title: "Transitions", onClose: onClose) {
            ScrollView {
                VStack(spacing: CSSpacing.m) {
                    if let selected = model.selectedClip {
                        let junctionIndex = model.clips.firstIndex(where: { $0.id == selected.id }) ?? 0
                        if junctionIndex == 0 {
                            Text("The first clip has no incoming junction — select a later clip.")
                                .font(CSType.body)
                                .foregroundStyle(CSTheme.textSecondary)
                        }
                        HStack(spacing: CSSpacing.s) {
                            ForEach(CSTransition.allCases, id: \.rawValue) { type in
                                CSToolChip(.transition, type.label, isSelected: selected.transitionIn == type) {
                                    model.setTransition(selected, type)
                                    CSHaptics.done()
                                }
                            }
                        }
                        Text("Applies at the junction between clip \(junctionIndex) and clip \(junctionIndex + 1).")
                            .font(CSType.timecode)
                            .foregroundStyle(CSTheme.textSecondary)
                    } else {
                        Text("Select a clip to set the transition entering it.")
                            .font(CSType.body)
                            .foregroundStyle(CSTheme.textSecondary)
                    }
                }
                .padding(.horizontal, CSSpacing.l)
            }
            .frame(maxHeight: 140)
        }
    }
}

// MARK: - Audio drawer (per-clip volume/mute from the clip's own audio)

struct AudioDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    var body: some View {
        CSDrawerContainer(title: "Audio", onClose: onClose) {
            ScrollView {
                VStack(spacing: CSSpacing.m) {
                    if let selected = model.selectedClip {
                        clipRow(selected)
                    } else {
                        Text("Select a clip on the timeline to adjust its sound.")
                            .font(CSType.body)
                            .foregroundStyle(CSTheme.textSecondary)
                    }
                    // [UNK] logged: device music library picker & bundled music
                    // arrive later; extracted audio already works via the mix.
                }
                .padding(.horizontal, CSSpacing.l)
            }
            .frame(maxHeight: 180)
        }
    }

    @ViewBuilder
    private func clipRow(_ clip: EditorViewModel.ClipSegment) -> some View {
        HStack(spacing: CSSpacing.m) {
            Text("Clip \(clip.assetIndex + 1)").font(CSType.body)
                .frame(width: 64, alignment: .leading)
            Button {
                model.setVolume(clip, volume: clip.volume, muted: !clip.isMuted)
            } label: {
                Image(systemName: clip.isMuted || clip.volume == 0
                    ? "speaker.slash.fill" : CSIcon.volume.rawValue)
                    .foregroundStyle(clip.isMuted ? CSTheme.danger : CSTheme.accent)
            }
            .accessibilityLabel(clip.isMuted ? "Unmute clip" : "Mute clip")
            Slider(value: Binding(
                get: { clip.volume },
                set: { v in model.setVolume(clip, volume: v, muted: clip.isMuted) }
            ), in: 0...2)
            Text("\(Int((clip.isMuted ? 0 : clip.volume) * 100))%")
                .font(CSType.timecode)
                .foregroundStyle(CSTheme.accent)
                .frame(width: 44)
        }
    }
}

// MARK: - Overlay drawer (edit the selected text/sticker)

/// Everything that belongs to one overlay: content, colour, weight, size,
/// opacity, duration, layer order. Sliders commit a single undo step per drag.
struct OverlayDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    private let swatchColors: [Color] = [.white, .black, CSTheme.accent, CSTheme.selection, .red, .blue, .yellow, .green]

    var body: some View {
        CSDrawerContainer(title: "Overlay", onClose: onClose) {
            if let overlay = model.selectedOverlay {
                editor(for: overlay)
            } else {
                VStack(alignment: .leading, spacing: CSSpacing.m) {
                    Text("Select an overlay on the canvas or in the timeline.")
                        .font(CSType.body)
                        .foregroundStyle(CSTheme.textSecondary)
                    // Quick access to every overlay, front-to-back.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: CSSpacing.s) {
                            ForEach(model.overlays.reversed()) { item in
                                Button {
                                    model.selectOverlay(item)
                                } label: {
                                    Text(item.textValue ?? "Sticker")
                                        .font(CSType.chip)
                                        .lineLimit(1)
                                        .padding(.horizontal, CSSpacing.m)
                                        .padding(.vertical, CSSpacing.xs)
                                        .background(CSTheme.surface)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, CSSpacing.l)
            }
        }
    }

    @ViewBuilder
    private func editor(for overlay: EditorViewModel.EditorOverlay) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CSSpacing.m) {
                if case .text(let text) = overlay.kind {
                    TextField("Overlay text", text: Binding(
                        get: { text },
                        set: { newValue in
                            var copy = overlay
                            copy.kind = .text(newValue)
                            model.updateOverlayLive(copy)
                        }
                    ))
                    .font(CSType.body)
                    .padding(CSSpacing.m)
                    .background(CSTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2))
                    .onSubmit { model.updateOverlay(overlay) }
                }

                // Colour + weight
                HStack(spacing: CSSpacing.s) {
                    ForEach(swatchColors, id: \.self) { color in
                        ZStack {
                            Circle().fill(color)
                            Circle().strokeBorder(
                                overlay.color == color ? CSTheme.selection : CSTheme.hairline,
                                lineWidth: overlay.color == color ? 2 : 1
                            )
                        }
                        .frame(width: 26, height: 26)
                        .onTapGesture {
                            var copy = overlay
                            copy.color = color
                            model.updateOverlay(copy)
                        }
                        .accessibilityLabel("Overlay colour")
                    }
                    Spacer()
                    Button {
                        var copy = overlay
                        copy.isBold.toggle()
                        model.updateOverlay(copy)
                    } label: {
                        Text("Bold")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(overlay.isBold ? CSTheme.bg : CSTheme.textPrimary)
                            .padding(.horizontal, CSSpacing.m)
                            .padding(.vertical, CSSpacing.xs)
                            .background(overlay.isBold ? CSTheme.accent : CSTheme.surfaceHigh)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                // Geometry + timing sliders (one undo step per gesture)
                overlaySlider("Size", value: Binding(
                    get: { Double(overlay.fontSize) },
                    set: { v in
                        var copy = overlay
                        copy.fontSize = CGFloat(v)
                        model.updateOverlayLive(copy)
                    }
                ), range: 14...140, format: { String(format: "%.0f", $0) })
                overlaySlider("Opacity", value: Binding(
                    get: { overlay.opacity },
                    set: { v in
                        var copy = overlay
                        copy.opacity = v
                        model.updateOverlayLive(copy)
                    }
                ), range: 0.1...1, format: { String(format: "%.0f%%", $0 * 100) })
                overlaySlider("Rotation", value: Binding(
                    get: { overlay.rotation },
                    set: { v in
                        var copy = overlay
                        copy.rotation = v
                        model.updateOverlayLive(copy)
                    }
                ), range: -180...180, format: { String(format: "%.0f°", $0) })

                Text(String(format: "Shown %.1fs – %.1fs",
                            overlay.start, min(overlay.endTime, max(overlay.start + 0.1, model.compositionDuration))))
                    .font(CSType.timecode)
                    .foregroundStyle(CSTheme.textSecondary)

                HStack(spacing: CSSpacing.s) {
                    smallButton("Start here") { model.overlayStartAtPlayhead(overlay) }
                    smallButton("End here") { model.overlayEndAtPlayhead(overlay) }
                    smallButton("Layer +") { model.bringOverlayForward(overlay) }
                    smallButton("Layer -") { model.sendOverlayBackward(overlay) }
                }
                HStack(spacing: CSSpacing.s) {
                    smallButton("Duplicate") { model.duplicateOverlay(overlay) }
                    smallButton("Delete", danger: true) { model.deleteOverlay(overlay) }
                }
            }
            .padding(.horizontal, CSSpacing.l)
        }
        .frame(maxHeight: 220)
    }

    private func overlaySlider(
        _ label: String, value: Binding<Double>, range: ClosedRange<Double>,
        format: @escaping (Double) -> String
    ) -> some View {
        HStack(spacing: CSSpacing.m) {
            Text(label).font(CSType.body).foregroundStyle(CSTheme.textSecondary)
                .frame(width: 70, alignment: .leading)
            Slider(value: value, in: range) { editing in
                if editing { model.beginOverlayDrag() } else { model.finalizeOverlayDrag() }
            }
            Text(format(value.wrappedValue))
                .font(CSType.timecode)
                .foregroundStyle(CSTheme.accent)
                .monospacedDigit()
                .frame(width: 50)
        }
    }

    private func smallButton(_ title: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(CSType.chip)
                .foregroundStyle(danger ? CSTheme.danger : CSTheme.textPrimary)
                .padding(.horizontal, CSSpacing.m)
                .padding(.vertical, CSSpacing.xs)
                .background(CSTheme.surface)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
