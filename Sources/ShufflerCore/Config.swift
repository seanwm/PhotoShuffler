import Foundation

/// User-editable settings, stored as `config.json` in the support folder.
/// Every key is optional in the file; missing keys fall back to the defaults below.
public struct Config: Codable, Equatable, Sendable {
    public struct Buckets: Codable, Equatable, Sendable {
        public var recent: Recent
        public var onThisDate: OnThisDate
        public var archive: Archive

        public init(recent: Recent = .init(), onThisDate: OnThisDate = .init(), archive: Archive = .init()) {
            self.recent = recent
            self.onThisDate = onThisDate
            self.archive = archive
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            recent = try c.decodeIfPresent(Recent.self, forKey: .recent) ?? .init()
            onThisDate = try c.decodeIfPresent(OnThisDate.self, forKey: .onThisDate) ?? .init()
            archive = try c.decodeIfPresent(Archive.self, forKey: .archive) ?? .init()
        }
    }

    /// Photos created in the last `windowDays` days.
    public struct Recent: Codable, Equatable, Sendable {
        public var share: Double = 0.20
        public var windowDays: Int = 30
        /// A recent photo stops counting as "recent" after this many nights in the
        /// album and competes in the archive bucket instead. 0 means no cap.
        public var maxNights: Int = 10
        public init(share: Double = 0.20, windowDays: Int = 30, maxNights: Int = 10) {
            self.share = share
            self.windowDays = windowDays
            self.maxNights = maxNights
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            share = try c.decodeIfPresent(Double.self, forKey: .share) ?? 0.20
            windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 30
            maxNights = try c.decodeIfPresent(Int.self, forKey: .maxNights) ?? 10
        }
    }

    /// Photos created within ±`windowDays` of today's month/day in a previous year.
    public struct OnThisDate: Codable, Equatable, Sendable {
        public var share: Double = 0.25
        public var windowDays: Int = 14
        public init(share: Double = 0.25, windowDays: Int = 14) {
            self.share = share
            self.windowDays = windowDays
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            share = try c.decodeIfPresent(Double.self, forKey: .share) ?? 0.25
            windowDays = try c.decodeIfPresent(Int.self, forKey: .windowDays) ?? 14
        }
    }

    /// Everything else. Also receives slots the other buckets can't fill.
    public struct Archive: Codable, Equatable, Sendable {
        public var share: Double = 0.55
        public init(share: Double = 0.55) { self.share = share }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            share = try c.decodeIfPresent(Double.self, forKey: .share) ?? 0.55
        }
    }

    /// Name of the managed album. Used to find the album only if the stored
    /// identifier in state.json is missing or stale, and to name it on creation.
    public var albumName: String = "Apple TV Screensaver"
    /// Target number of items in the album.
    public var albumSize: Int = 150
    /// How many nights each photo stays in the album. Each night the oldest
    /// 1/nightsInAlbum of the album is swapped for new picks (3 → a third).
    /// 1 replaces the whole album every night.
    public var nightsInAlbum: Int = 3
    /// Include videos from Favorites (default: photos only).
    public var includeVideos: Bool = false
    public var buckets: Buckets = .init()
    /// Days after being shown before a photo is back to full weight.
    public var cooldownDays: Int = 21
    /// Weight floor for photos still in cooldown (0...1). Keeps small pools workable.
    public var minWeight: Double = 0.05
    /// Fixed RNG seed for reproducible selections. Leave null for a fresh draw each night.
    public var seed: UInt64? = nil

    public init() {}

    enum CodingKeys: String, CodingKey {
        case albumName, albumSize, nightsInAlbum, includeVideos, buckets, cooldownDays, minWeight, seed
    }

    public init(from decoder: Decoder) throws {
        let d = Config()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albumName = try c.decodeIfPresent(String.self, forKey: .albumName) ?? d.albumName
        albumSize = try c.decodeIfPresent(Int.self, forKey: .albumSize) ?? d.albumSize
        nightsInAlbum = try c.decodeIfPresent(Int.self, forKey: .nightsInAlbum) ?? d.nightsInAlbum
        includeVideos = try c.decodeIfPresent(Bool.self, forKey: .includeVideos) ?? d.includeVideos
        buckets = try c.decodeIfPresent(Buckets.self, forKey: .buckets) ?? d.buckets
        cooldownDays = try c.decodeIfPresent(Int.self, forKey: .cooldownDays) ?? d.cooldownDays
        minWeight = try c.decodeIfPresent(Double.self, forKey: .minWeight) ?? d.minWeight
        seed = try c.decodeIfPresent(UInt64.self, forKey: .seed) ?? d.seed
    }

    /// Written explicitly so a generated config shows `"seed": null` like the sample.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(albumName, forKey: .albumName)
        try c.encode(albumSize, forKey: .albumSize)
        try c.encode(nightsInAlbum, forKey: .nightsInAlbum)
        try c.encode(includeVideos, forKey: .includeVideos)
        try c.encode(buckets, forKey: .buckets)
        try c.encode(cooldownDays, forKey: .cooldownDays)
        try c.encode(minWeight, forKey: .minWeight)
        try c.encode(seed, forKey: .seed)
    }

    /// Returns a list of problems that make the config unusable. Empty means valid.
    public func validationErrors() -> [String] {
        var errors: [String] = []
        if albumName.trimmingCharacters(in: .whitespaces).isEmpty { errors.append("albumName must not be empty") }
        if albumSize <= 0 { errors.append("albumSize must be greater than 0") }
        if nightsInAlbum < 1 { errors.append("nightsInAlbum must be at least 1") }
        if buckets.recent.maxNights < 0 { errors.append("buckets.recent.maxNights must be >= 0 (0 = no cap)") }
        if buckets.recent.windowDays < 0 { errors.append("buckets.recent.windowDays must be >= 0") }
        if buckets.onThisDate.windowDays < 0 { errors.append("buckets.onThisDate.windowDays must be >= 0") }
        if buckets.onThisDate.windowDays > 182 { errors.append("buckets.onThisDate.windowDays must be <= 182") }
        for (name, share) in [("recent", buckets.recent.share), ("onThisDate", buckets.onThisDate.share), ("archive", buckets.archive.share)]
        where share < 0 || !share.isFinite {
            errors.append("buckets.\(name).share must be a non-negative number")
        }
        if totalShare <= 0 { errors.append("bucket shares must add up to more than 0") }
        if cooldownDays < 0 { errors.append("cooldownDays must be >= 0") }
        if !(0...1).contains(minWeight) { errors.append("minWeight must be between 0 and 1") }
        return errors
    }

    var totalShare: Double { buckets.recent.share + buckets.onThisDate.share + buckets.archive.share }

    /// Non-fatal notes worth logging (e.g. shares not summing to 1).
    public func warnings() -> [String] {
        var notes: [String] = []
        if totalShare > 0, abs(totalShare - 1) > 0.001 {
            notes.append(String(format: "bucket shares add up to %.3f, not 1; they will be scaled proportionally", totalShare))
        }
        if minWeight == 0 {
            notes.append("minWeight is 0: photos in cooldown are excluded entirely, so buckets may run short")
        }
        return notes
    }
}
