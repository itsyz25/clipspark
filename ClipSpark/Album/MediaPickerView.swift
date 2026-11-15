import Photos
import SwiftUI

/// Media picker — CapCut-style: 3-column grid, multi-select with numbered
/// checkmarks, duration badges, done-bar, permission states.
struct MediaPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = PhotoLibraryService()
    @State private var selectedOrder: [PHAsset] = []

    var onDone: ([PHAsset]) -> Void

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    private let thumbSize = UIScreen.main.bounds.width / 3

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips (folder-style tabs; collections arrive in a later unit)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CSSpacing.s) {
                    CSToolChip(.importMedia, "All videos", isSelected: true)
                    CSToolChip(.sticker, "Selfies", isSelected: false)
                    CSToolChip(.templates, "By date", isSelected: false)
                }
                .padding(.horizontal, CSSpacing.l)
                .padding(.vertical, CSSpacing.s)
            }

            pickerBody

            // Done bar
            HStack {
                Button("Cancel") { dismiss() }
                    .font(CSType.body).foregroundStyle(CSTheme.textSecondary)
                Spacer()
                CSPrimaryButton(
                    selectedOrder.isEmpty ? "Select clips" : "Add \(selectedOrder.count)",
                    icon: selectedOrder.isEmpty ? nil : .newProject
                ) {
                    onDone(selectedOrder)
                    dismiss()
                }
                .disabled(selectedOrder.isEmpty)
                .opacity(selectedOrder.isEmpty ? 0.4 : 1)
            }
            .padding(CSSpacing.l)
            .background(CSTheme.surface)
        }
        .background(CSTheme.bg.ignoresSafeArea())
        .onAppear {
            if library.authState == .idle { library.requestAccess() }
            if library.authState == .granted || library.authState == .limited { library.fetchVideos() }
        }
    }

    @ViewBuilder
    private var pickerBody: some View {
        switch library.authState {
        case .idle:
            VStack(spacing: CSSpacing.m) {
                CSEmptyState(.importMedia, "Allow photo access", "ClipSpark needs access to your videos to start a project.")
                CSPrimaryButton("Allow access", icon: .newProject) { library.requestAccess() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(spacing: CSSpacing.m) {
                CSEmptyState(.importMedia, "Access denied", "Enable photo access in Settings, then come back.")
                CSPrimaryButton("Open Settings", icon: .settings) {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .granted, .limited:
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(library.videos, id: \.localIdentifier) { asset in
                        AssetCell(asset: asset, service: library, orderIndex: selectedOrder.firstIndex(of: asset)) {
                            toggle(asset)
                        }
                        .frame(width: thumbSize, height: thumbSize)
                    }
                }
            }
        }
    }

    private func toggle(_ asset: PHAsset) {
        CSHaptics.tick()
        if let index = selectedOrder.firstIndex(of: asset) {
            selectedOrder.remove(at: index)
        } else {
            selectedOrder.append(asset)
        }
    }
}

// MARK: - Cell
private struct AssetCell: View {
    @State private var thumbnail: UIImage?
    let asset: PHAsset
    let service: PhotoLibraryService
    let orderIndex: Int?
    let onTap: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable().scaledToFill()
                } else {
                    Rectangle().fill(CSTheme.surfaceHigh)
                }
            }
            .clipped()

            // Duration badge
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(PhotoLibraryService.durationText(asset))
                        .font(CSType.timecode)
                        .padding(.horizontal, CSSpacing.xs)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(CSSpacing.xs)
                }
            }

            selectionBadge.padding(CSSpacing.s)
        }
        .contentShape(Rectangle())
        .overlay(
            orderIndex != nil
                ? Rectangle().strokeBorder(CSTheme.accent, lineWidth: 2)
                : nil
        )
        .task {
            guard thumbnail == nil else { return }
            let size = CGSize(width: thumbPx, height: thumbPx)
            service.thumbnail(for: asset, size: size) { image in
                self.thumbnail = image
            }
        }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Video, \(PhotoLibraryService.durationText(asset))\(orderIndex != nil ? ", selected" : "")")
        .accessibilityAddTraits(orderIndex != nil ? .isSelected : [])
    }

    private var thumbPx: CGFloat { UIScreen.main.bounds.width / 3 * UIScreen.main.scale }

    @ViewBuilder
    private var selectionBadge: some View {
        ZStack {
            Circle()
                .fill(orderIndex != nil ? CSTheme.accent : .black.opacity(0.4))
                .strokeBorder(orderIndex != nil ? CSTheme.accent : .white.opacity(0.8), lineWidth: 1.5)
                .frame(width: 26, height: 26)
            if let orderIndex {
                Text("\(orderIndex + 1)").font(CSType.chip)
                    .foregroundStyle(.black).bold()
            }
        }
    }
}
