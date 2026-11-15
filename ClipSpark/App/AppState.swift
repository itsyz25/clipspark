import Photos
import SwiftUI

/// Identifiable wrapper so [PHAsset] can drive fullScreenCover(item:).
struct EditorPayload: Identifiable {
    let assets: [PHAsset]
    let template: ClipTemplate?
    var draft: SavedDraft?
    var id: ObjectIdentifier { ObjectIdentifier(assets as NSArray) }
}

/// Shared app router: project creation flow (optional template → album picker
/// → full-screen editor) shared by Home and Templates tabs.
@MainActor
final class AppState: ObservableObject {
    @Published var showPicker = false
    @Published var pendingTemplate: ClipTemplate?
    @Published var editorPayload: EditorPayload?

    func startProject(template: ClipTemplate? = nil) {
        pendingTemplate = template
        showPicker = true
    }

    func picked(_ assets: [PHAsset]) {
        editorPayload = EditorPayload(assets: assets, template: pendingTemplate)
        pendingTemplate = nil
    }

    func openDraft(_ draft: SavedDraft) {
        let assets = DraftStore.shared.fetchAssets(localIDs: draft.assetLocalIDs)
        guard !assets.isEmpty else { return } // source videos deleted from library
        editorPayload = EditorPayload(assets: assets, template: nil, draft: draft)
    }

    func closeEditor() {
        editorPayload = nil
    }
}
