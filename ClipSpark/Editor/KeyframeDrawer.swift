import SwiftUI

// MARK: - Keyframe drawer
//
// Property picker → graph (curve sampled from the real evaluator) →
// tap-to-add / drag-to-move keyframes → per-keyframe inspector for the
// variation (hold/linear/presets/custom Bézier/spring) and custom settings.

struct KeyframeDrawer: View {
    @ObservedObject var model: EditorViewModel
    var onClose: () -> Void

    @State private var property: CSKeyframeProperty = .scale
    @State private var selectedKeyframeID: UUID?
    @State private var isDraggingPoint = false
    @StateObject private var presetLibrary = CSEasingPresetLibrary.shared

    var body: some View {
        CSDrawerContainer(title: "Keyframes", onClose: onClose) {
            if let clip = model.selectedClip {
                VStack(alignment: .leading, spacing: CSSpacing.m) {
                    HStack {
                        Menu {
                            ForEach(CSKeyframeProperty.allCases) { p in
                                Button(p.label) { property = p; selectedKeyframeID = nil }
                            }
                        } label: {
                            HStack(spacing: CSSpacing.xs) {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                Text(property.label).font(CSType.title)
                            }
                            .foregroundStyle(CSTheme.accent)
                        }
                        .accessibilityLabel("Keyframe property")
                        Spacer()
                        Button {
                            let t = model.timecode - clip.start
                            let evaluated = CSKeyframeEvaluator.evaluate(
                                clip.keyframes, property,
                                staticBase: property.staticBase(volume: clip.volume, look: model.look),
                                at: max(0, min(t, clip.timelineDuration))
                            )
                            model.addKeyframe(clip, property, value: evaluated, at: t)
                        } label: {
                            Label("Add here", systemImage: "diamond")
                                .font(CSType.chip)
                                .foregroundStyle(.black)
                                .padding(.horizontal, CSSpacing.s)
                                .padding(.vertical, CSSpacing.xs)
                                .background(CSTheme.accent)
                                .clipShape(Capsule())
                        }
                        .accessibilityLabel("Add keyframe at playhead")
                    }

                    graph(clip)
                        .frame(height: 200)
                        .background(CSTheme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2))

                    if let kf = selectedKeyframe {
                        inspector(clip, kf)
                    } else {
                        Text("Tap the graph to add a keyframe. Tap a point to edit its curve and custom settings.")
                            .font(CSType.chip)
                            .foregroundStyle(CSTheme.textSecondary)
                    }

                    if !model.keyframes(on: clip, for: property).isEmpty {
                        Button("Remove all \(property.label) keyframes") {
                            model.removeKeyframes(clip, property)
                            selectedKeyframeID = nil
                        }
                        .font(CSType.chip)
                        .foregroundStyle(CSTheme.danger)
                    }
                }
                .padding(.horizontal, CSSpacing.l)
            } else {
                Text("Select a clip on the timeline to keyframe it.")
                    .font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
                    .padding(.horizontal, CSSpacing.l)
            }
        }
    }

    private var selectedKeyframe: CSKeyframe? {
        guard let clip = model.selectedClip, let id = selectedKeyframeID else { return nil }
        return clip.keyframes.first { $0.id == id }
    }

    // MARK: Graph

    private func graph(_ clip: EditorViewModel.ClipSegment) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let range = property.range
            let span = max(clip.timelineDuration, 0.001)

            func xPos(_ t: Double) -> CGFloat { CGFloat(t / span) * w }
            func yPos(_ v: Double) -> CGFloat {
                let frac = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
                return h * (1 - CGFloat(max(-0.25, min(1.25, frac))))
            }

            ZStack {
                // Grid
                Path { p in
                    for i in 1...3 {
                        p.move(to: CGPoint(x: w * CGFloat(i) / 4, y: 0))
                        p.addLine(to: CGPoint(x: w * CGFloat(i) / 4, y: h))
                        p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 4))
                        p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 4))
                    }
                }
                .stroke(CSTheme.hairline, lineWidth: 0.5)

                // Curve sampled from the actual evaluator (shows overshoot etc.)
                Path { p in
                    var first = true
                    for px in stride(from: 0.0, through: w, by: 3.0) {
                        let t = Double(px) / Double(w) * span
                        let v = CSKeyframeEvaluator.evaluate(
                            clip.keyframes, property,
                            staticBase: property.staticBase(volume: clip.volume, look: model.look),
                            at: t
                        )
                        let point = CGPoint(x: px, y: yPos(v))
                        if first { p.move(to: point); first = false } else { p.addLine(to: point) }
                    }
                }
                .stroke(CSTheme.accent, lineWidth: 2)

                // Playhead
                Path { p in
                    let x = xPos(max(0, min(model.timecode - clip.start, span)))
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x, y: h))
                }
                .stroke(CSTheme.textSecondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

                // Keyframe handles
                ForEach(model.keyframes(on: clip, for: property)) { kf in
                    Circle()
                        .fill(kf.id == selectedKeyframeID ? CSTheme.selection : CSTheme.accent)
                        .frame(width: 14, height: 14)
                        .position(x: xPos(kf.time), y: yPos(kf.value))
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { g in
                                    if !isDraggingPoint {
                                        isDraggingPoint = true
                                        selectedKeyframeID = kf.id
                                        model.beginKeyframeDrag()
                                    }
                                    var moved = kf
                                    moved.time = max(0, min(span, Double(g.location.x / w) * span))
                                    moved.value = property.range.upperBound
                                        - Double(g.location.y / h) * (property.range.upperBound - property.range.lowerBound)
                                    moved.value = max(property.range.lowerBound, min(property.range.upperBound, moved.value))
                                    model.updateKeyframeLive(clip, moved)
                                }
                                .onEnded { _ in
                                    isDraggingPoint = false
                                    model.finalizeKeyframeDrag()
                                }
                        )
                        .onTapGesture { selectedKeyframeID = kf.id }
                        .accessibilityLabel("Keyframe at \(String(format: "%.2f", kf.time))s")
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { g in
                        // Ignore taps that land on an existing point (child
                        // gestures handle those — avoids a duplicate keyframe).
                        let hitRadius: CGFloat = 22
                        let nearExisting = model.keyframes(on: clip, for: property).contains { kf in
                            let dx = xPos(kf.time) - g.location.x
                            let dy = yPos(kf.value) - g.location.y
                            return dx * dx + dy * dy < hitRadius * hitRadius
                        }
                        guard !nearExisting else { return }
                        let t = Double(g.location.x / w) * span
                        var v = property.range.upperBound
                            - Double(g.location.y / h) * (property.range.upperBound - property.range.lowerBound)
                        v = max(property.range.lowerBound, min(property.range.upperBound, v))
                        model.addKeyframe(clip, property, value: v, at: t)
                        selectedKeyframeID = nil
                    }
            )
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private func inspector(_ clip: EditorViewModel.ClipSegment, _ kf: CSKeyframe) -> some View {
        VStack(alignment: .leading, spacing: CSSpacing.s) {
            HStack {
                Text("Keyframe @ \(String(format: "%.2f", kf.time))s").font(CSType.title)
                Spacer()
                Button {
                    model.removeKeyframe(clip, kf.id)
                    selectedKeyframeID = nil
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(CSTheme.danger)
                }
                .accessibilityLabel("Delete keyframe")
            }

            valueSlider(clip, kf)

            Menu {
                Button("Hold") { setVariation(kf) { .hold } }
                Button("Linear") { setVariation(kf) { .linear } }
                ForEach(CSEasingPreset.allCases) { p in
                    Button(p.label) { setVariation(kf) { .preset(p) } }
                }
                Menu("Custom Bézier") {
                    Button("Smooth (0.3 / 0.7)") { setVariation(kf) { .bezier(c1x: 0.3, c1y: 0.3, c2x: 0.7, c2y: 0.7) } }
                    Button("Snappy (0.2 / 1.0)") { setVariation(kf) { .bezier(c1x: 0.2, c1y: 0.2, c2x: 0.8, c2y: 1.0) } }
                    ForEach(presetLibrary.presets) { p in
                        Button("★ \(p.name)") {
                            setVariation(kf) { .bezier(c1x: p.c1x, c1y: p.c1y, c2x: p.c2x, c2y: p.c2y) }
                        }
                    }
                    Button("Save current control points…") {
                        presetLibrary.save(
                            name: "Curve \(presetLibrary.presets.count + 1)",
                            c1x: bezierPoints(kf).c1x, c1y: bezierPoints(kf).c1y,
                            c2x: bezierPoints(kf).c2x, c2y: bezierPoints(kf).c2y
                        )
                    }
                }
                Button("Spring") { setVariation(kf) { .spring(stiffness: 8, damping: 0.55) } }
            } label: {
                HStack(spacing: CSSpacing.xs) {
                    Text("Curve: \(kf.variation.label)").font(CSType.chip)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(CSTheme.accent)
                .padding(.horizontal, CSSpacing.s)
                .padding(.vertical, CSSpacing.xs)
                .background(CSTheme.surface)
                .clipShape(Capsule())
            }
            .accessibilityLabel("Keyframe curve")

            variationSettings(clip, kf)
        }
        .padding(CSSpacing.m)
        .background(CSTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2))
    }

    private func bezierPoints(_ kf: CSKeyframe) -> (c1x: Double, c1y: Double, c2x: Double, c2y: Double) {
        if case .bezier(let c1x, let c1y, let c2x, let c2y) = kf.variation {
            return (c1x, c1y, c2x, c2y)
        }
        return (0.3, 0.3, 0.7, 0.7)
    }

    private func setVariation(_ kf: CSKeyframe, _ make: () -> CSKeyframeVariation) {
        guard let clip = model.selectedClip else { return }
        var updated = kf
        updated.variation = make()
        model.updateKeyframe(clip, updated)
    }

    /// Live slider edit: one undo step per gesture (baseline pattern).
    private func liveSet(_ clip: EditorViewModel.ClipSegment, _ kf: CSKeyframe, _ change: (inout CSKeyframe) -> Void) {
        var updated = kf
        change(&updated)
        model.updateKeyframeLive(clip, updated)
    }

    @ViewBuilder
    private func valueSlider(_ clip: EditorViewModel.ClipSegment, _ kf: CSKeyframe) -> some View {
        HStack(spacing: CSSpacing.s) {
            Text(property.format(kf.value)).font(CSType.chip)
                .frame(width: 64, alignment: .leading)
            Slider(
                value: Binding(
                    get: { kf.value },
                    set: { v in liveSet(clip, kf) { $0.value = v } }
                ),
                in: property.range,
                onEditingChanged: { editing in
                    if editing { model.beginKeyframeDrag() } else { model.finalizeKeyframeDrag() }
                }
            )
        }
    }

    @ViewBuilder
    private func variationSettings(_ clip: EditorViewModel.ClipSegment, _ kf: CSKeyframe) -> some View {
        VStack(alignment: .leading, spacing: CSSpacing.xs) {
            switch kf.variation {
            case .bezier(let c1x, let c1y, let c2x, let c2y):
                curveSlider("Point 1 X", c1x) { v in
                    liveSet(clip, kf) { k in
                        if case .bezier(_, let y1, let x2, let y2) = k.variation { k.variation = .bezier(c1x: v, c1y: y1, c2x: x2, c2y: y2) }
                    }
                }
                curveSlider("Point 1 Y", c1y) { v in
                    liveSet(clip, kf) { k in
                        if case .bezier(let x1, _, let x2, let y2) = k.variation { k.variation = .bezier(c1x: x1, c1y: v, c2x: x2, c2y: y2) }
                    }
                }
                curveSlider("Point 2 X", c2x) { v in
                    liveSet(clip, kf) { k in
                        if case .bezier(let x1, let y1, _, let y2) = k.variation { k.variation = .bezier(c1x: x1, c1y: y1, c2x: v, c2y: y2) }
                    }
                }
                curveSlider("Point 2 Y", c2y) { v in
                    liveSet(clip, kf) { k in
                        if case .bezier(let x1, let y1, let x2, _) = k.variation { k.variation = .bezier(c1x: x1, c1y: y1, c2x: x2, c2y: v) }
                    }
                }
            case .spring(let stiffness, let damping):
                curveSlider("Snappiness", stiffness, 1...30) { v in
                    liveSet(clip, kf) { k in
                        if case .spring(_, let d) = k.variation { k.variation = .spring(stiffness: v, damping: d) }
                    }
                }
                curveSlider("Bounce", damping, 0.05...1) { v in
                    liveSet(clip, kf) { k in
                        if case .spring(let s, _) = k.variation { k.variation = .spring(stiffness: s, damping: v) }
                    }
                }
            default:
                EmptyView()
            }

            settingSlider("Velocity blend", kf.settings.velocityInfluence) { v in
                liveSet(clip, kf) { k in k.settings.velocityInfluence = v }
            }
            Toggle("Clamp to range", isOn: Binding(
                get: { kf.settings.clamped },
                set: { on in
                    var updated = kf; updated.settings.clamped = on
                    model.updateKeyframe(clip, updated)
                }
            ))
            .font(CSType.chip)
            Toggle("Reversed", isOn: Binding(
                get: { kf.settings.reversed },
                set: { on in
                    var updated = kf; updated.settings.reversed = on
                    model.updateKeyframe(clip, updated)
                }
            ))
            .font(CSType.chip)
        }
    }

    private func curveSlider(
        _ label: String, _ value: Double, _ range: ClosedRange<Double> = 0...1,
        _ set: @escaping (Double) -> Void
    ) -> some View {
        HStack(spacing: CSSpacing.s) {
            Text(label).font(CSType.chip).frame(width: 88, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
        }
    }

    private func settingSlider(_ label: String, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: CSSpacing.s) {
            Text(label).font(CSType.chip).frame(width: 88, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
        }
    }
}

// MARK: - Convenience accessors used by the drawer

extension CSKeyframe {
    var stiffness: Double {
        if case .spring(let s, _) = variation { return s }
        return 8
    }
}
