import Foundation

/// A Photos asset reduced to what the selector needs.
public struct PhotoItem: Equatable, Hashable, Sendable {
    public let id: String          // PHAsset.localIdentifier
    public let creationDate: Date?

    public init(id: String, creationDate: Date?) {
        self.id = id
        self.creationDate = creationDate
    }
}

public enum Bucket: String, CaseIterable, Codable, Sendable {
    case recent
    case onThisDate
    case archive
}

/// Persistent tool state, stored as `state.json`.
public struct State: Codable, Equatable, Sendable {
    /// PHAssetCollection.localIdentifier of the managed album, recorded on first run.
    public var albumLocalIdentifier: String?
    public var lastRun: Date?

    public init(albumLocalIdentifier: String? = nil, lastRun: Date? = nil) {
        self.albumLocalIdentifier = albumLocalIdentifier
        self.lastRun = lastRun
    }
}

/// Per-asset album history, stored as `history.json`.
public struct History: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// Most recent run date the asset was in the album.
        public var lastShown: Date
        /// Number of nights the asset has been in the album, across all stays.
        public var timesShown: Int
        /// Start of the asset's current stay in the album; nil when it's not in the album.
        public var inAlbumSince: Date?

        public init(lastShown: Date, timesShown: Int, inAlbumSince: Date? = nil) {
            self.lastShown = lastShown
            self.timesShown = timesShown
            self.inAlbumSince = inAlbumSince
        }
    }

    public var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public func lastShown(_ id: String) -> Date? { entries[id]?.lastShown }
    public func timesShown(_ id: String) -> Int { entries[id]?.timesShown ?? 0 }
    public func inAlbumSince(_ id: String) -> Date? { entries[id]?.inAlbumSince }

    /// Records one night: every asset in `album` was shown on `date`; assets in
    /// `added` start a new stay today; everything else is marked out of the album.
    /// Entries for assets no longer in the source pool are dropped.
    public mutating func record(album: [String], added: Set<String>, on date: Date, pool: Set<String>) {
        let inAlbum = Set(album)
        for (id, entry) in entries where !inAlbum.contains(id) && entry.inAlbumSince != nil {
            entries[id]?.inAlbumSince = nil
        }
        for id in album {
            var entry = entries[id] ?? Entry(lastShown: date, timesShown: 0)
            entry.lastShown = date
            entry.timesShown += 1
            if added.contains(id) || entry.inAlbumSince == nil {
                entry.inAlbumSince = date
            }
            entries[id] = entry
        }
        entries = entries.filter { pool.contains($0.key) }
    }
}
