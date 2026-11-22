import Foundation

public struct SelectedPhoto: Equatable, Sendable {
    public let item: PhotoItem
    public let bucket: Bucket
    public let weight: Double
}

public struct SelectionResult: Sendable {
    /// The newly drawn photos, in selection order.
    public var selected: [SelectedPhoto] = []
    /// Slots each bucket was asked to fill after share scaling (before spill-over).
    public var quotas: [Bucket: Int] = [:]
    /// Candidates available in each bucket.
    public var poolCounts: [Bucket: Int] = [:]
    /// Items actually drawn from each bucket (archive includes spill-over).
    public var filled: [Bucket: Int] = [:]
    /// Human-readable notes about shortfalls and spill-over.
    public var notes: [String] = []

    public var selectedIDs: Set<String> { Set(selected.map(\.item.id)) }
}

/// One night's changes: which photos stay, which leave, and what's drawn to replace them.
public struct NightlyPlan: Sendable {
    /// Photos staying in the album, oldest stay first.
    public var kept: [String] = []
    /// Photos leaving because their stay is over (oldest first).
    public var rotatedOut: [String] = []
    /// Photos leaving because they're no longer eligible (not a favorite any more,
    /// a video when videos are off, or something added to the album by hand).
    public var ineligible: [String] = []
    /// New photos drawn for the open slots.
    public var draw = SelectionResult()
    /// Slots rotated each night at steady state (albumSize / nightsInAlbum, rounded up).
    public var rotationSlots = 0
    /// Bucket counts for the album after tonight's changes.
    public var composition: [Bucket: Int] = [:]

    /// The album's contents after tonight: kept photos, then new ones.
    public var target: [String] { kept + draw.selected.map(\.item.id) }
}

/// Builds each night's album changes from the source pool.
public struct PhotoSelector: Sendable {
    public let config: Config
    public let history: History
    public let now: Date
    public let calendar: Calendar

    public init(config: Config, history: History, now: Date, calendar: Calendar = .current) {
        self.config = config
        self.history = history
        self.now = now
        self.calendar = calendar
    }

    var bucketer: Bucketer { Bucketer(config: config, history: history, now: now, calendar: calendar) }

    /// Anti-repetition weight: 1 for never-shown or out-of-cooldown photos,
    /// rising linearly from `minWeight` to 1 across the cooldown period.
    /// (weight = 1 − decay, decay = 1 − daysSinceShown / cooldownDays)
    public func weight(for id: String) -> Double {
        guard config.cooldownDays > 0, let last = history.lastShown(id) else { return 1 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: now)).day ?? 0
        if days >= config.cooldownDays { return 1 }
        let linear = Double(max(days, 0)) / Double(config.cooldownDays)
        return max(config.minWeight, linear)
    }

    /// Photos swapped per night at steady state.
    public var rotationSlots: Int {
        Int((Double(config.albumSize) / Double(max(config.nightsInAlbum, 1))).rounded(.up))
    }

    /// Plans tonight's album: drops ineligible photos, rotates out the oldest
    /// stays so `rotationSlots` open up, and draws new photos for the open slots.
    /// Over `nightsInAlbum` nights the whole album turns over, and since every
    /// night's draw follows the bucket shares, so does the album as a whole.
    public func plan<R: RandomNumberGenerator>(pool: [PhotoItem], currentAlbum: [String], using rng: inout R) -> NightlyPlan {
        var plan = NightlyPlan()
        plan.rotationSlots = rotationSlots
        let poolIDs = Set(pool.map(\.id))
        plan.ineligible = currentAlbum.filter { !poolIDs.contains($0) }

        // Oldest stay first. Unknown start dates (a pre-existing album, or photos
        // added by hand) count as oldest; ties keep album order, which is add order.
        let eligible = currentAlbum.enumerated()
            .filter { poolIDs.contains($0.element) }
            .sorted { a, b in
                let da = history.inAlbumSince(a.element) ?? .distantPast
                let db = history.inAlbumSince(b.element) ?? .distantPast
                return da != db ? da < db : a.offset < b.offset
            }
            .map(\.element)

        let keepCount = max(0, min(eligible.count, config.albumSize - rotationSlots))
        plan.kept = Array(eligible.suffix(keepCount))
        plan.rotatedOut = Array(eligible.prefix(eligible.count - keepCount))

        // Never re-add tonight anything that was in the album last night.
        let current = Set(currentAlbum)
        let candidates = pool.filter { !current.contains($0.id) }
        plan.draw = select(count: config.albumSize - keepCount, pool: candidates, using: &rng)

        // Not enough fresh photos: keep the newest of the outgoing ones instead.
        let shortfall = config.albumSize - keepCount - plan.draw.selected.count
        if shortfall > 0, !plan.rotatedOut.isEmpty {
            let rescued = Array(plan.rotatedOut.suffix(shortfall))
            plan.rotatedOut.removeLast(rescued.count)
            plan.kept = rescued + plan.kept
            plan.draw.notes.append("not enough fresh photos: kept \(rescued.count) that were due to rotate out")
        }

        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for id in plan.target {
            if let item = byID[id] { plan.composition[bucketer.bucket(for: item), default: 0] += 1 }
        }
        return plan
    }

    /// Splits `n` slots into per-bucket quotas using the (normalized) shares.
    public func quotas(for n: Int) -> [Bucket: Int] {
        let b = config.buckets
        let total = b.recent.share + b.onThisDate.share + b.archive.share
        guard total > 0, n > 0 else { return [.recent: 0, .onThisDate: 0, .archive: max(n, 0)] }
        let recent = min(n, Int((Double(n) * b.recent.share / total).rounded()))
        let onThisDate = min(n - recent, Int((Double(n) * b.onThisDate.share / total).rounded()))
        return [.recent: recent, .onThisDate: onThisDate, .archive: n - recent - onThisDate]
    }

    public func quotas() -> [Bucket: Int] { quotas(for: config.albumSize) }

    /// Draws a full album's worth from the pool (no rotation).
    public func select<R: RandomNumberGenerator>(pool: [PhotoItem], using rng: inout R) -> SelectionResult {
        select(count: config.albumSize, pool: pool, using: &rng)
    }

    /// Draws `count` photos from `pool`, split across buckets by share.
    public func select<R: RandomNumberGenerator>(count: Int, pool: [PhotoItem], using rng: inout R) -> SelectionResult {
        var result = SelectionResult()
        let buckets = bucketer.partition(pool)
        let quotas = quotas(for: count)
        result.quotas = quotas
        for bucket in Bucket.allCases { result.poolCounts[bucket] = buckets[bucket]?.count ?? 0 }
        guard count > 0 else { return result }

        var remaining: [Bucket: [PhotoItem]] = buckets
        var archiveQuota = quotas[.archive] ?? 0

        // 1. Recent and on-this-date; shortfalls spill into archive.
        for bucket in [Bucket.recent, .onThisDate] {
            let quota = quotas[bucket] ?? 0
            let picked = draw(quota, from: remaining[bucket] ?? [], using: &rng)
            take(picked, bucket: bucket, into: &result, remaining: &remaining)
            let shortfall = quota - picked.count
            if shortfall > 0 {
                archiveQuota += shortfall
                result.notes.append("\(bucket.rawValue) bucket filled \(picked.count) of \(quota); \(shortfall) slot(s) moved to archive")
            }
        }

        // 2. Archive, including spill-over.
        let archivePicked = draw(archiveQuota, from: remaining[.archive] ?? [], using: &rng)
        take(archivePicked, bucket: .archive, into: &result, remaining: &remaining)

        // 3. If archive is short too, top up from whatever is left anywhere.
        let stillShort = archiveQuota - archivePicked.count
        if stillShort > 0 {
            result.notes.append("archive bucket filled \(archivePicked.count) of \(archiveQuota)")
            let leftovers = (remaining[.recent] ?? []) + (remaining[.onThisDate] ?? [])
            let topUp = draw(stillShort, from: leftovers, using: &rng)
            for item in topUp {
                take([item], bucket: bucketer.bucket(for: item), into: &result, remaining: &remaining)
            }
            if !topUp.isEmpty {
                result.notes.append("topped up \(topUp.count) slot(s) from the recent/on-this-date leftovers")
            }
            let unfilled = stillShort - topUp.count
            if unfilled > 0 {
                result.notes.append("source pool too small: drew \(result.selected.count) of \(count)")
            }
        }
        return result
    }

    private func take(_ items: [PhotoItem], bucket: Bucket, into result: inout SelectionResult, remaining: inout [Bucket: [PhotoItem]]) {
        guard !items.isEmpty else { return }
        let ids = Set(items.map(\.id))
        for item in items {
            result.selected.append(SelectedPhoto(item: item, bucket: bucket, weight: weight(for: item.id)))
        }
        result.filled[bucket, default: 0] += items.count
        for key in remaining.keys {
            remaining[key]?.removeAll { ids.contains($0.id) }
        }
    }

    /// Weighted random sampling without replacement (Efraimidis–Spirakis):
    /// each item gets key = ln(u) / w and the `count` largest keys win.
    /// Items with weight 0 are never drawn.
    func draw<R: RandomNumberGenerator>(_ count: Int, from items: [PhotoItem], using rng: inout R) -> [PhotoItem] {
        guard count > 0, !items.isEmpty else { return [] }
        var keyed: [(key: Double, item: PhotoItem)] = []
        keyed.reserveCapacity(items.count)
        for item in items {
            let w = weight(for: item.id)
            guard w > 0 else { continue }
            // u in (0, 1]; avoid ln(0).
            let u = Double.random(in: Double.ulpOfOne...1, using: &rng)
            keyed.append((log(u) / w, item))
        }
        keyed.sort { $0.key > $1.key }
        return keyed.prefix(count).map(\.item)
    }
}

/// The minimal set of changes that turns the current album into the target set.
public struct AlbumDiff: Equatable, Sendable {
    public let toAdd: [String]
    public let toRemove: [String]
    public let kept: Int

    public init(current: [String], target: [String]) {
        let currentSet = Set(current)
        let targetSet = Set(target)
        toAdd = target.filter { !currentSet.contains($0) }
        toRemove = current.filter { !targetSet.contains($0) }
        kept = currentSet.intersection(targetSet).count
    }

    public var isEmpty: Bool { toAdd.isEmpty && toRemove.isEmpty }
}
