import Photos
import SwiftUI

/// Editor screen: canvas → transport strip → timeline → contextual tools →
/// drawer. The tool row is *contextual*: it only shows actions that apply to
/// what is currently selected (nothing / video clip / audio / text / overlay).
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
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                canvas
                transportStrip
                TimelineView(model: model)
                    .frame(height: TimelineView.preferredHeight(overlayCount: model.overlays.count))
                    .padding(.horizontal, CSSpacing.s)
                    .padding(.vertical, CSSpacing.xs)
                    .background(CSTheme.bg)
                contextBar
                Spacer(minLength: 0)
            }

            if let drawer = activeDrawer {
                drawerView(drawer)
                    .frame(maxHeight: 300)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(CSMotion.easeOut, value: activeDrawer)
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
            if let draft = model.toSavedDraft(name: draftName, id: savedDraft?.id) {
                DraftStore.shared.save(draft)
            }
        }
        .sheet(isPresented: $showExport) {
            ExportSheet(model: model)
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            CanvasPlayerView(player: model.player)
                .background(.black)

            GeometryReader { geo in
                ForEach(model.visibleOverlays(at: model.timecode)) { overlay in
                    OverlayItem(overlay: overlay, model: model, canvasSize: geo.size)
                }
            }

            if model.selectedClip != nil {
                RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous)
                    .strokeBorder(CSTheme.accent, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            if !model.isPlaying {
                Image(systemName: CSIcon.play.rawValue)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .allowsHitTesting(false)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: CSRadius.card / 2, style: .continuous))
        .padding(.horizontal, CSSpacing.s)
        .contentShape(Rectangle())
        .onTapGesture {
            // Tapping the frame clears a selection first; otherwise it plays.
            if model.selectedClip != nil || model.selectedOverlay != nil {
                model.deselectAll()
                activeDrawer = nil
            } else {
                model.togglePlay()
            }
        }
        .accessibilityLabel(model.isPlaying ? "Pause preview" : "Play preview")
    }

    // MARK: - Transport strip

    private var transportStrip: some View {
        HStack(spacing: CSSpacing.m) {
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

            Text("\(model.timecodeText) / \(model.totalText)")
                .font(CSType.timecode)
                .foregroundStyle(CSTheme.accent)
                .monospacedDigit()

            Spacer()

            Button {
                showExport = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: CSIcon.export.rawValue)
                    Text("Export").font(CSType.chip)
                }
                .foregroundStyle(CSTheme.accent)
            }
            .accessibilityLabel("Export project")
        }
        .font(.system(size: 18))
        .padding(.horizontal, CSSpacing.l)
        .padding(.vertical, CSSpacing.s)
    }

    // MARK: - Contextual tool bar

    private enum ContextState { case none, video, audio, text, overlay }

    private var contextState: ContextState {
        if activeDrawer == .audio { return .audio }
        if let overlay = model.selectedOverlay {
            return overlay.textValue != nil ? .text : .overlay
        }
        if model.selectedClip != nil { return .video }
        return .none
    }

    private var contextBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CSSpacing.s) {
                switch contextState {
                case .none:
                    chip(.split, "Split") { model.splitAtPlayhead() }
                    chip(.text, "Text") { activeDrawer = .text }
                    chip(.sticker, "Stickers") { activeDrawer = .sticker }
                    chip(.audio, "Audio") { activeDrawer = .audio }
                    chip(.filter, "Filters") { activeDrawer = .filter }
                    chip(.transition, "Transitions") { activeDrawer = .transitions }

                case .video:
                    chip(.split, "Split") { model.splitAtPlayhead() }
                    chip(.volume, "Volume") { activeDrawer = .audio }
                    chip(.speed, "Speed") { activeDrawer = .inspector }
                    chip(.keyframe, "Keyframes") { activeDrawer = .keyframes }
                    chip(.filter, "Effects") { activeDrawer = .filter }
                    chip(.transition, "Transitions") { activeDrawer = .transitions }
                    chip(.duplicate, "Duplicate") { if let c = model.selectedClip { model.duplicate(c) } }
                    chip(.delete, "Delete", danger: true) { if let c = model.selectedClip { model.delete(c) } }

                case .audio:
                    chip(.volume, "Volume") { activeDrawer = .audio }
                    chip(.split, "Split") { model.splitAtPlayhead() }
                    chip(.duplicate, "Duplicate") { if let c = model.selectedClip { model.duplicate(c) } }
                    chip(.delete, "Delete", danger: true) { if let c = model.selectedClip { model.delete(c) } }

                case .text:
                    chip(.text, "Edit") { activeDrawer = .overlay }
                    chip(.adjust, "Style") { activeDrawer = .overlay }
                    chip(.overlay, "Layer +") { forward() }
                    chip(.overlay, "Layer −") { backward() }
                    chip(.trim, "Start here") { if let o = model.selectedOverlay { model.overlayStartAtPlayhead(o) } }
                    chip(.trim, "End here") { if let o = model.selectedOverlay { model.overlayEndAtPlayhead(o) } }
                    chip(.duplicate, "Duplicate") { if let o = model.selectedOverlay { model.duplicateOverlay(o) } }
                    chip(.delete, "Delete", danger: true) { if let o = model.selectedOverlay { model.deleteOverlay(o) } }

                case .overlay:
                    chip(.overlay, "Layer +") { forward() }
                    chip(.overlay, "Layer −") { backward() }
                    chip(.trim, "Start here") { if let o = model.selectedOverlay { model.overlayStartAtPlayhead(o) } }
                    chip(.trim, "End here") { if let o = model.selectedOverlay { model.overlayEndAtPlayhead(o) } }
                    chip(.duplicate, "Duplicate") { if let o = model.selectedOverlay { model.duplicateOverlay(o) } }
                    chip(.delete, "Delete", danger: true) { if let o = model.selectedOverlay { model.deleteOverlay(o) } }
                }
            }
            .padding(.horizontal, CSSpacing.l)
        }
        .frame(height: 62)
        .background(CSTheme.surface)
    }

    private func forward() {
        if let o = model.selectedOverlay { model.bringOverlayForward(o) }
    }

    private func backward() {
        if let o = model.selectedOverlay { model.sendOverlayBackward(o) }
    }

    private func chip(_ icon: CSIcon, _ label: String, danger: Bool = false, action: @escaping () -> Void) -> some View {
        CSToolChip(icon, label, action: action)
            .overlay(alignment: .bottom) {
                if danger {
                    Capsule().fill(CSTheme.danger.opacity(0.6)).frame(height: 2).padding(.horizontal, 12)
                }
            }
    }

    // MARK: - Drawers

    @ViewBuilder
    private func drawerView(_ drawer: EditorDrawer) -> some View {
        switch drawer {
        case .text: TextDrawer(model: model, onClose: { activeDrawer = nil })
        case .sticker: StickerDrawer(model: model, onClose: { activeDrawer = nil })
        case .filter: FilterDrawer(model: model, onClose: { activeDrawer = nil })
        case .transitions: TransitionsDrawer(model: model, onClose: { activeDrawer = nil })
        case .audio: AudioDrawer(model: model, onClose: { activeDrawer = nil })
        case .keyframes: KeyframeDrawer(model: model, onClose: { activeDrawer = nil })
        case .overlay: OverlayDrawer(model: model, onClose: { activeDrawer = nil })
        case .inspector:
            if let selected = model.selectedClip {
                ClipInspector(model: model, clip: selected)
            }
        }
    }
}
