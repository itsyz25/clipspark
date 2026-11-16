import Photos
import SwiftUI

/// Observable bridge to the device photo library. [OBS]: PHAsset is the only
/// iOS API that can enumerate library videos with durations; PHPicker cannot.
@MainActor
final class PhotoLibraryService: ObservableObject {
    enum AuthState: Equatable {
        case idle, granted, denied, limited
    }

    @Published var authState: AuthState = .idle
    @Published var videos: [PHAsset] = []

    private let imageManager = PHCachingImageManager()

    init() {
        refreshAuthState()
    }

    func refreshAuthState() {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: authState = .granted
        case .limited: authState = .limited
        case .denied, .restricted: authState = .denied
        case .notDetermined: authState = .idle
        @unknown default: authState = .denied
        }
    }

    func requestAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAuthState()
                if self?.authState == .granted || self?.authState == .limited {
                    self?.fetchVideos()
                }
            }
        }
    }

    func fetchVideos() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)

        let result = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        videos = assets
    }

    func thumbnail(for asset: PHAsset, size: CGSize, completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        // Offline by construction: never fetch from iCloud. Assets that only
        // exist in the cloud show a placeholder until downloaded on-device.
        options.isNetworkAccessAllowed = false
        imageManager.requestImage(
            for: asset, targetSize: size, contentMode: .aspectFill, options: options
        ) { image, _ in
            completion(image)
        }
    }

    /// mm:ss duration badge, per spec's timecode style.
    static func durationText(_ asset: PHAsset) -> String {
        let seconds = Int(asset.duration.rounded())
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
