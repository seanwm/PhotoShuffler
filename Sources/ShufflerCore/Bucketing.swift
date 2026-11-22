import Foundation

/// Assigns photos to buckets. Precedence: recent, then on-this-date, then archive.
public struct Bucketer: Sendable {
    public let recentDays: Int
    public let onThisDateDays: Int
    /// Nights in the album after which a recent photo counts as archive. 0 = no cap.
    public let recentMaxNights: Int
    public let history: History
    public let now: Date
    public let calendar: Calendar

    public init(
        recentDays: Int,
        onThisDateDays: Int,
        recentMaxNights: Int = 0,
        history: History = History(),
        now: Date,
        calendar: Calendar = .current
    ) {
        self.recentDays = recentDays
        self.onThisDateDays = onThisDateDays
        self.recentMaxNights = recentMaxNights
        self.history = history
        self.now = now
        self.calendar = calendar
    }

    public init(config: Config, history: History, now: Date, calendar: Calendar = .current) {
        self.init(
            recentDays: config.buckets.recent.windowDays,
            onThisDateDays: config.buckets.onThisDate.windowDays,
            recentMaxNights: config.buckets.recent.maxNights,
            history: history,
            now: now,
            calendar: calendar
        )
    }

    public func bucket(for item: PhotoItem) -> Bucket {
        guard let date = item.creationDate else { return .archive }
        // Recent photos that have used up their nights fall through to the
        // other buckets (in practice, archive).
        let capped = recentMaxNights > 0 && history.timesShown(item.id) >= recentMaxNights
        if isRecent(date) && !capped { return .recent }
        if isOnThisDate(date) { return .onThisDate }
        return .archive
    }

    public func partition(_ items: [PhotoItem]) -> [Bucket: [PhotoItem]] {
        var result: [Bucket: [PhotoItem]] = [.recent: [], .onThisDate: [], .archive: []]
        for item in items {
            result[bucket(for: item), default: []].append(item)
        }
        return result
    }

    func isRecent(_ date: Date) -> Bool {
        guard let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return date >= cutoff
    }

    /// True if `date` is in an earlier year than today and falls within
    /// ±onThisDateDays of today's month/day. Handles windows that cross New Year
    /// by checking the anniversary in the photo's year and the years either side.
    func isOnThisDate(_ date: Date) -> Bool {
        let todayYear = calendar.component(.year, from: now)
        let photoYear = calendar.component(.year, from: date)
        guard photoYear < todayYear else { return false }

        let today = calendar.dateComponents([.month, .day], from: now)
        let photoDay = calendar.startOfDay(for: date)
        // Anniversaries in the current year are excluded: "on this date" means a
        // previous year, and the current year is the recent bucket's job.
        for year in (photoYear - 1)...min(photoYear + 1, todayYear - 1) {
            var comps = DateComponents()
            comps.year = year
            comps.month = today.month
            comps.day = today.day
            guard let anniversary = calendar.date(from: comps) else { continue }
            let distance = abs(calendar.dateComponents([.day], from: photoDay, to: anniversary).day ?? .max)
            if distance <= onThisDateDays { return true }
        }
        return false
    }
}
