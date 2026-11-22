import Foundation
import Photos
import ShufflerCore

// SAFETY: This is the only file that talks to PhotoKit. The only write APIs it
// uses are PHAssetCollectionChangeRequest addAssets / removeAssets on the managed
// album, and creationRequestForAssetCollection to create that album once.
// It never deletes assets or collections and never touches Favorites or other
// albums. Tests/ShufflerCoreTests/SafetyTests.swift enforces this.

enum PhotoLibraryError: Error, CustomStringConvertible {
    case notAuthorized(PHAuthorizationStatus)
    case favoritesNotFound
    case ambiguousAlbumName(String, Int)
    case storedAlbumNotEditable(String)
    case albumCreationFailed(String)
    case changeFailed(String)

    var description: String {
        switch self {
        case .notAuthorized(let status):
            return "Photos access is \(status.label). Grant full access: run scripts/authorize.sh, or System Settings > Privacy & Security > Photos > PhotoShuffler."
        case .favoritesNotFound:
            return "Couldn't find the Favorites smart album."
        case .ambiguousAlbumName(let name, let count):
            return "Found \(count) albums named \"\(name)\". Rename the extras (or set the stored identifier in state.json) so there's exactly one."
        case .storedAlbumNotEditable(let id):
            return "The stored album \(id) is not a regular editable album. Fix or delete albumLocalIdentifier in state.json."
        case .albumCreationFailed(let detail):
            return "Couldn't create the album: \(detail)"
        case .changeFailed(let detail):
            return "Couldn't update the album: \(detail)"
        }
    }
}

extension PHAuthorizationStatus {
    var label: String {
        switch self {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized (full access)"
        case .limited: return "limited (selected photos only)"
        @unknown default: return "unknown (\(rawValue))"
        }
    }
}

enum AlbumLookup {
    case byIdentifier(PHAssetCollection)
    case byName(PHAssetCollection)
    case notFound
}

struct PhotoLibrary {
    // MARK: Authorization

    static func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Requests read/write access and waits for the answer. Returns the current
    /// status immediately if it has already been decided.
    static func requestAuthorization(timeout: TimeInterval) -> PHAuthorizationStatus {
        let current = authorizationStatus()
        guard current == .notDetermined else { return current }
        let semaphore = DispatchSemaphore(value: 0)
        let box = StatusBox()
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            box.status = status
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            return authorizationStatus()
        }
        return box.status ?? authorizationStatus()
    }

    private final class StatusBox: @unchecked Sendable {
        var status: PHAuthorizationStatus?
    }

    // MARK: Reading

    /// Photos (and optionally videos) in the Favorites smart album.
    func favoritePool(includeVideos: Bool) throws -> [PhotoItem] {
        guard let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil
        ).firstObject else {
            throw PhotoLibraryError.favoritesNotFound
        }
        let options = PHFetchOptions()
        options.predicate = includeVideos
            ? NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            : NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let assets = PHAsset.fetchAssets(in: favorites, options: options)
        var items: [PhotoItem] = []
        items.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in
            items.append(PhotoItem(id: asset.localIdentifier, creationDate: asset.creationDate))
        }
        return items
    }

    /// Finds the managed album: stored identifier first, then exact name.
    func findAlbum(storedID: String?, name: String) throws -> AlbumLookup {
        if let storedID,
           let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [storedID], options: nil).firstObject {
            guard album.assetCollectionType == .album,
                  album.assetCollectionSubtype == .albumRegular,
                  album.canPerform(.addContent), album.canPerform(.removeContent) else {
                throw PhotoLibraryError.storedAlbumNotEditable(storedID)
            }
            return .byIdentifier(album)
        }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title == %@", name)
        let matches = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options)
        switch matches.count {
        case 0: return .notFound
        case 1: return .byName(matches.firstObject!)
        default: throw PhotoLibraryError.ambiguousAlbumName(name, matches.count)
        }
    }

    func assetIDs(in album: PHAssetCollection) -> [String] {
        let assets = PHAsset.fetchAssets(in: album, options: nil)
        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        assets.enumerateObjects { asset, _, _ in ids.append(asset.localIdentifier) }
        return ids
    }

    // MARK: Writing (managed album only)

    /// Creates the managed album. Called only when neither the stored identifier
    /// nor the album name matches an existing album.
    func createAlbum(named name: String) throws -> PHAssetCollection {
        var placeholderID: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
                placeholderID = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            throw PhotoLibraryError.albumCreationFailed(error.localizedDescription)
        }
        guard let placeholderID,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholderID], options: nil).firstObject else {
            throw PhotoLibraryError.albumCreationFailed("new album not found after creation")
        }
        return album
    }

    /// Applies the diff to the managed album in a single performChanges block.
    func apply(_ diff: AlbumDiff, to album: PHAssetCollection) throws {
        guard !diff.isEmpty else { return }
        let toRemove = PHAsset.fetchAssets(withLocalIdentifiers: diff.toRemove, options: nil)
        let toAdd = PHAsset.fetchAssets(withLocalIdentifiers: diff.toAdd, options: nil)
        let currentContents = PHAsset.fetchAssets(in: album, options: nil)
        var requestFailed = false
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                guard let request = PHAssetCollectionChangeRequest(for: album, assets: currentContents) else {
                    requestFailed = true
                    return
                }
                if toRemove.count > 0 { request.removeAssets(toRemove) }
                if toAdd.count > 0 { request.addAssets(toAdd) }
            }
        } catch {
            throw PhotoLibraryError.changeFailed(error.localizedDescription)
        }
        if requestFailed {
            throw PhotoLibraryError.changeFailed("Photos refused a change request for the album")
        }
    }
}
