import SwiftUI

/// Living style guide — a single screen that renders every token and component,
/// so each unit's visual audit has one canonical place to check.
public struct DesignSystemPreview: View {
    @State private var chipSelected = 0

    private let chips: [(CSIcon, String)] = [
        (.editClip, "Edit"), (.audio, "Audio"), (.text, "Text"),
        (.overlay, "Overlay"), (.effects, "Effects"), (.speed, "Speed"),
    ]

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CSSpacing.l) {
                Group {
                    Text("ClipSpark").font(CSType.title)
                    Text("Every cut, instantly.").font(CSType.body).foregroundStyle(CSTheme.textSecondary)
                }
                .accessibilityElement(children: .combine)

                // Colors
                Text("Palette").font(CSType.title)
                HStack(spacing: CSSpacing.s) {
                    swatch(CSTheme.bg, "BG")
                    swatch(CSTheme.surface, "Surface")
                    swatch(CSTheme.surfaceHigh, "Surface↑")
                    swatch(CSTheme.accent, "Accent")
                    swatch(CSTheme.selection, "Select")
                    swatch(CSTheme.textSecondary, "Text 2")
                }

                // CTA gradient
                Text("Primary CTA").font(CSType.title)
                CSPrimaryButton("New project", icon: .newProject) {}
                CSPrimaryButton("Export", icon: .export) {}

                // Tool chips
                Text("Tool chips").font(CSType.title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CSSpacing.s) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { i, chip in
                            CSToolChip(chip.0, chip.1, isSelected: chipSelected == i) {
                                chipSelected = i
                            }
                        }
                    }
                }

                // Cards + empty state
                Text("Card & empty state").font(CSType.title)
                CSCard {
                    VStack(alignment: .leading, spacing: CSSpacing.s) {
                        Text("Draft project").font(CSType.title)
                        Text("00:42 · 6 clips · edited 2h ago").font(CSType.timecode)
                            .foregroundStyle(CSTheme.textSecondary)
                    }
                }
                CSEmptyState(.drafts, "No drafts yet", "Start a project and it will appear here.")

                // Timecode
                Text("Timecode").font(CSType.title)
                Text("00:00:12 / 00:01:30").font(CSType.timecode)
                    .foregroundStyle(CSTheme.accent)
            }
            .padding(CSSpacing.l)
        }
        .background(CSTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func swatch(_ color: Color, _ name: String) -> some View {
        VStack(spacing: CSSpacing.xs) {
            RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous)
                .fill(color).strokeBorder(CSTheme.hairline, lineWidth: 1)
                .frame(width: 44, height: 44)
            Text(name).font(CSType.timecode).foregroundStyle(CSTheme.textSecondary)
        }
    }
}
