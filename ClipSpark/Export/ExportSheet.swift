import AVKit
import SwiftUI

/// Export sheet: resolution/fps options, progress ring, done state with
/// preview + share. 100% offline — the share sheet only hands out a local file.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = ExportViewModel()
    let model: EditorViewModel

    var body: some View {
        VStack(spacing: CSSpacing.l) {
            CSGrabber()
            Text("Export").font(CSType.title)

            switch exporter.state {
            case .idle:
                settings
                CSPrimaryButton("Export", icon: .export) { exporter.export(model: model) }
            case .exporting(let progress):
                progressRing(progress)
                Button("Cancel", role: .cancel) { exporter.cancel() }
                    .font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
            case .done(let url):
                doneView(url)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundStyle(CSTheme.danger)
                Text(message).font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
                CSPrimaryButton("Try again") { exporter.state = .idle }
            }
            Spacer(minLength: 0)
        }
        .padding(CSSpacing.l)
        .background(CSTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: Sections

    private var settings: some View {
        VStack(alignment: .leading, spacing: CSSpacing.m) {
            optionRow("Resolution", options: ExportViewModel.heightOptions.map { "\($0)p" },
                      selectedIndex: Binding(
                        get: { ExportViewModel.heightOptions.firstIndex(of: exporter.height) ?? 1 },
                        set: { exporter.height = ExportViewModel.heightOptions[$0] }))
            optionRow("Frame rate", options: ExportViewModel.fpsOptions.map { "\($0) fps" },
                      selectedIndex: Binding(
                        get: { ExportViewModel.fpsOptions.firstIndex(of: exporter.fps) ?? 0 },
                        set: { exporter.fps = ExportViewModel.fpsOptions[$0] }))
            Text("Transitions, filters, text and stickers are included. Everything renders on-device.")
                .font(CSType.timecode)
                .foregroundStyle(CSTheme.textSecondary)
        }
        .padding(.horizontal, CSSpacing.l)
    }

    private func optionRow(_ label: String, options: [String], selectedIndex: Binding<Int>) -> some View {
        HStack {
            Text(label).font(CSType.body).foregroundStyle(CSTheme.textSecondary)
            Spacer()
            HStack(spacing: CSSpacing.s) {
                ForEach(options.indices, id: \.self) { i in
                    Button {
                        CSHaptics.tick()
                        selectedIndex.wrappedValue = i
                    } label: {
                        Text(options[i]).font(CSType.chip)
                            .padding(.horizontal, CSSpacing.m)
                            .padding(.vertical, CSSpacing.s)
                            .background(selectedIndex.wrappedValue == i ? CSTheme.accent : CSTheme.surfaceHigh)
                            .foregroundStyle(selectedIndex.wrappedValue == i ? CSTheme.bg : CSTheme.textPrimary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func progressRing(_ progress: Double) -> some View {
        ZStack {
            Circle().stroke(CSTheme.hairline, lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(CSTheme.accentGradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(CSMotion.fastOut, value: progress)
            Text("\(Int(progress * 100))%").font(CSType.title).monospacedDigit()
        }
        .frame(width: 120, height: 120)
        .accessibilityLabel("Export progress \(Int(progress * 100)) percent")
    }

    private func doneView(_ url: URL) -> some View {
        VStack(spacing: CSSpacing.m) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(CSTheme.success)
            Text("Saved to Files-ready location").font(CSType.body)
                .foregroundStyle(CSTheme.textSecondary)
            VideoPlayer(player: AVPlayer(url: url))
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: CSRadius.card, style: .continuous))
            HStack(spacing: CSSpacing.m) {
                ShareLink(item: url) {
                    Label("Share", systemImage: CSIcon.export.rawValue)
                        .font(CSType.title)
                        .foregroundStyle(.black)
                        .padding(.horizontal, CSSpacing.l)
                        .padding(.vertical, CSSpacing.m)
                        .background(CSTheme.accent)
                        .clipShape(Capsule())
                }
                Button("Done") { dismiss() }
                    .font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
            }
        }
        .padding(.horizontal, CSSpacing.l)
    }
}
