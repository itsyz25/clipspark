import SwiftUI

// MARK: - Home
struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @State private var drafts: [SavedDraft] = DraftStore.shared.loadAll()
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CSSpacing.l) {
                    if !hasSeenIntro {
                        CSCard {
                            HStack(spacing: CSSpacing.m) {
                                Image(systemName: CSIcon.newProject.rawValue)
                                    .font(.system(size: 24))
                                    .foregroundStyle(CSTheme.accent)
                                VStack(alignment: .leading, spacing: CSSpacing.xs) {
                                    Text("Every cut, instantly.").font(CSType.title)
                                    Text("Tap New project, pick clips, and edit — everything works offline.")
                                        .font(CSType.body)
                                        .foregroundStyle(CSTheme.textSecondary)
                                }
                                Spacer()
                                Button {
                                    hasSeenIntro = true
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(CSTheme.textSecondary)
                                }
                                .accessibilityLabel("Dismiss hint")
                            }
                        }
                    }

                    CSPrimaryButton("New project", icon: .newProject) {
                        app.startProject()
                    }
                    .frame(maxWidth: .infinity)

                    draftsSection
                    templateFeedSection
                }
                .padding(CSSpacing.l)
            }
            .background(CSTheme.bg.ignoresSafeArea())
            .navigationTitle("ClipSpark")
            .onAppear {
                drafts = DraftStore.shared.loadAll() // refresh after editor autosave
            }
            .sheet(isPresented: $app.showPicker) {
                MediaPickerView { assets in
                    app.picked(assets)
                }
            }
            .fullScreenCover(item: Binding(
                get: { app.editorPayload },
                set: { app.editorPayload = $0 }
            )) { payload in
                EditorView(assets: payload.assets, template: payload.template)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Image(systemName: CSIcon.inbox.rawValue)
                        .foregroundStyle(CSTheme.textSecondary)
                }
            }
        }
    }

    private var draftsSection: some View {
        VStack(alignment: .leading, spacing: CSSpacing.s) {
            if drafts.isEmpty {
                CSCard { CSEmptyState(.drafts, "No drafts yet", "Start a project and it will appear here.") }
            } else {
                Text("Drafts").font(CSType.title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: CSSpacing.m) {
                        ForEach(drafts) { draft in
                            DraftCard(draft: draft) {
                                app.openDraft(draft)
                            }
                        }
                    }
                }
            }
        }
    }

    private var templateFeedSection: some View {
        VStack(alignment: .leading, spacing: CSSpacing.s) {
            Text("Templates").font(CSType.title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CSSpacing.m) {
                    ForEach(ClipTemplate.catalog) { template in
                        TemplateCard(template: template) {
                            app.startProject(template: template)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Cards
private struct DraftCard: View {
    let draft: SavedDraft
    var action: () -> Void = {}

    var body: some View {
        Button {
            CSHaptics.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: CSSpacing.xs) {
                RoundedRectangle(cornerRadius: CSRadius.card, style: .continuous)
                    .fill(CSTheme.surfaceHigh)
                    .strokeBorder(CSTheme.hairline, lineWidth: 1)
                    .frame(width: 148, height: 92)
                    .overlay(alignment: .center) {
                        Image(systemName: CSIcon.editClip.rawValue)
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(CSTheme.textSecondary)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Text(draft.durationText).font(CSType.timecode)
                            .padding(CSSpacing.xs)
                            .background(.black.opacity(0.6))
                            .clipShape(Capsule())
                            .padding(CSSpacing.xs)
                    }

                Text(draft.name).font(CSType.body).lineLimit(1)
                Text("\(draft.clips.count) clips").font(CSType.timecode)
                    .foregroundStyle(CSTheme.textSecondary)
            }
            .frame(width: 148, alignment: .leading)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                DraftStore.shared.delete(draft.id)
                drafts.removeAll { $0.id == draft.id }
            } label: {
                Label("Delete draft", systemImage: CSIcon.delete.rawValue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Draft \(draft.name), \(draft.durationText)")
    }
}

// MARK: - Template card (real bundled recipe → picker → editor)
struct TemplateCard: View {
    let template: ClipTemplate
    var action: () -> Void = {}

    private var seedColor: Color {
        CSTheme.seedPalette[template.colorSeed % CSTheme.seedPalette.count].opacity(0.3)
    }

    var body: some View {
        Button {
            CSHaptics.tick()
            action()
        } label: {
            VStack(alignment: .leading, spacing: CSSpacing.xs) {
                RoundedRectangle(cornerRadius: CSRadius.card, style: .continuous)
                    .fill(seedColor)
                    .strokeBorder(CSTheme.hairline, lineWidth: 1)
                    .frame(width: 120, height: 160)
                    .overlay(alignment: .center) {
                        Image(systemName: CSIcon.templates.rawValue)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(CSTheme.textSecondary)
                    }
                Text(template.name).font(CSType.body).lineLimit(1)
                Text("\(template.uses) uses").font(CSType.timecode)
                    .foregroundStyle(CSTheme.textSecondary)
            }
            .frame(width: 120, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Use template \(template.name)")
    }
}
