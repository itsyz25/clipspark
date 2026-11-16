import Photos
import SwiftUI

/// Editor screen skeleton: canvas → state strip → timeline → tool dock
/// (dock is static in Unit 4; functional drawers arrive in Unit 6).
struct EditorView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = EditorViewModel()
    let assets: [PHAsset]
    var template: ClipTemplate? = nil
    var savedDraft: SavedDraft? = nil
    @State private var activeDrawer: EditorDrawer?
    @State private var showExport = false

    private var draftName: String { savedDraft?.name ?? "Project \(Self.dateFormat.string(from: Date()))" }
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // 1. Preview canvas + draggable overlays (text/stickers)
            ZStack {
                CanvasPlayerView(player: model.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous))
                    .onTapGesture { model.togglePlay() }
                    .accessibilityLabel(model.isPlaying ? "Pause preview" : "Play preview")

                GeometryReader { canvas in
                    ForEach(model.overlays) { overlay in
                        OverlayItem(
                            overlay: overlay,
                            model: model,
                            canvasSize: canvas.size
                        )
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .padding(CSSpacing.s)

            // 2. State strip: undo/redo · timecode · export
            HStack {
                Button { model.undo() } label: {
                    Image(systemName: CSIcon.undo.rawValue)
                        .foregroundStyle(model.canUndo ? CSTheme.textPrimary : CSTheme.textSecondary)
                }
                .disabled(!model.canUndo)
                Button { model.redo() } label: {
                    Image(systemName: CSIcon.redo.rawValue)
                        .foregroundStyle(model.canRedo ? CSTheme.textPrimary : CSTheme.textSecondary)
                }
                .disabled(!model.canRedo)
                Button { model.splitAtPlayhead() } label: {
                    Image(systemName: CSIcon.split.rawValue)
                        .foregroundStyle(CSTheme.textPrimary)
                }
                .accessibilityLabel("Split at playhead")
                Spacer()
                Text("\(model.timecodeText) / \(totalText)")
                    .font(CSType.timecode)
                    .foregroundStyle(CSTheme.accent)
                    .monospacedDigit()
                Spacer()
                Button {
                    showExport = true
                } label: {
                    Image(systemName: CSIcon.export.rawValue)
                        .foregroundStyle(CSTheme.accent)
                }
                .accessibilityLabel("Export project")
            }
            .font(.system(size: 18))
            .padding(.horizontal, CSSpacing.l)
            .padding(.vertical, CSSpacing.s)

            // 3. Timeline
            TimelineView(model: model)
                .frame(height: 72)
                .padding(.vertical, CSSpacing.s)
                .background(CSTheme.surface)

            // 4. Tool dock — chips open drawers; Edit opens clip inspector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CSSpacing.s) {
                    CSToolChip(.editClip, "Edit") {
                        if model.selectedClip == nil, let first = model.clips.first {
                            model.select(first)
                        }
                        activeDrawer = .inspector
                    }
                    CSToolChip(.text, "Text") { activeDrawer = .text }
                    CSToolChip(.sticker, "Sticker") { activeDrawer = .sticker }
                    CSToolChip(.filter, "Filters") { activeDrawer = .filter }
                    CSToolChip(.transition, "Transitions") {
                        if model.selectedClip == nil, let first = model.clips.dropFirst().first {
                            model.select(first)
                        }
                        activeDrawer = .transitions
                    }
                    CSToolChip(.audio, "Audio") { activeDrawer = .audio }
                    CSToolChip(.speed, "Speed") {
                        if model.selectedClip == nil, let first = model.clips.first {
                            model.select(first)
                        }
                        activeDrawer = .inspector
                    }
                }
                .padding(.horizontal, CSSpacing.l)
            }
            .padding(.vertical, CSSpacing.s)
            .background(CSTheme.surface)

            Spacer(minLength: 0)

            // 5. Drawer layer: tool drawers first, then clip inspector
            switch activeDrawer {
            case .text: TextDrawer(model: model, onClose: { activeDrawer = nil })
            case .sticker: StickerDrawer(model: model, onClose: { activeDrawer = nil })
            case .filter: FilterDrawer(model: model, onClose: { activeDrawer = nil })
            case .transitions: TransitionsDrawer(model: model, onClose: { activeDrawer = nil })
            case .audio: AudioDrawer(model: model, onClose: { activeDrawer = nil })
            case .inspector:
                if let selected = model.selectedClip {
                    ClipInspector(model: model, clip: selected)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            case nil: EmptyView()
            }
            .animation(CSMotion.easeOut, value: activeDrawer)
        }
        .background(CSTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Back") { dismiss() }.foregroundStyle(CSTheme.textPrimary)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Text("Untitled project").font(CSType.body)
                    .foregroundStyle(CSTheme.textSecondary)
            }
        }
        .onAppear {
            if model.clips.isEmpty {
                if let savedDraft {
                    model.restore(from: savedDraft, assets: assets)
                } else {
                    model.load(assets: assets, template: template)
                }
            }
        }
        .onDisappear {
            model.player.pause()
            // Autosave: every editor session persists as a draft (offline JSON)
            if let draft = model.toSavedDraft(name: draftName, id: savedDraft?.id) {
                DraftStore.shared.save(draft)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
        }
    }

    private var totalText: String {
        let total = Int(model.compositionDuration.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
