import Foundation
import Testing
@testable import ShufflerCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private func item(_ id: String, _ y: Int, _ m: Int, _ d: Int) -> PhotoItem {
    PhotoItem(id: id, creationDate: date(y, m, d))
}

// MARK: - Bucketing

@Suite struct BucketingTests {
    let now = date(2026, 11, 22)

    func bucketer(recent: Int = 30, onThisDate: Int = 7, now: Date? = nil) -> Bucketer {
        Bucketer(recentDays: recent, onThisDateDays: onThisDate, now: now ?? self.now, calendar: utc)
    }

    @Test func recentWindow() {
        let b = bucketer()
        #expect(b.bucket(for: item("a", 2026, 11, 1)) == .recent)
        #expect(b.bucket(for: item("b", 2026, 10, 23)) == .recent)   // exactly 30 days
        #expect(b.bucket(for: item("c", 2026, 10, 21)) == .archive)
    }

    @Test func onThisDateWindowInPreviousYears() {
        let b = bucketer()
        #expect(b.bucket(for: item("a", 2019, 11, 22)) == .onThisDate)
        #expect(b.bucket(for: item("b", 2019, 11, 15)) == .onThisDate)  // -7
        #expect(b.bucket(for: item("c", 2019, 11, 29)) == .onThisDate)  // +7
        #expect(b.bucket(for: item("d", 2019, 11, 30)) == .archive)     // +8
        #expect(b.bucket(for: item("e", 2026, 5, 1)) == .archive)       // this year, not recent
    }

    @Test func onThisDateCrossesNewYear() {
        let b = bucketer(now: date(2027, 1, 2))
        #expect(b.bucket(for: item("a", 2020, 12, 28)) == .onThisDate)  // 5 days before Jan 2 2021
        #expect(b.bucket(for: item("b", 2021, 1, 8)) == .onThisDate)
        #expect(b.bucket(for: item("c", 2026, 12, 28)) == .recent)      // last week, not "a year ago"
    }

    @Test func recentTakesPrecedence() {
        // A photo from last Dec 30 when it's Jan 2 is both recent and near the date.
        let b = bucketer(now: date(2027, 1, 2))
        #expect(b.bucket(for: item("a", 2026, 12, 30)) == .recent)
    }

    @Test func missingDateGoesToArchive() {
        #expect(bucketer().bucket(for: PhotoItem(id: "x", creationDate: nil)) == .archive)
    }
}

// MARK: - Weights

@Suite struct WeightTests {
    let now = date(2026, 11, 22)

    func selector(cooldown: Int = 21, minWeight: Double = 0.05, history: [String: Date]) -> PhotoSelector {
        var config = Config()
        config.cooldownDays = cooldown
        config.minWeight = minWeight
        let h = History(entries: history.mapValues { History.Entry(lastShown: $0, timesShown: 1) })
        return PhotoSelector(config: config, history: h, now: now, calendar: utc)
    }

    @Test func neverShownIsFullWeight() {
        #expect(selector(history: [:]).weight(for: "a") == 1)
    }

    @Test func linearRecoveryAcrossCooldown() {
        let s = selector(history: ["shownYesterday": date(2026, 11, 21), "halfway": date(2026, 11, 12), "done": date(2026, 11, 1)])
        #expect(s.weight(for: "shownYesterday") == 0.05)          // 1/21 ≈ 0.048 → floored
        #expect(abs(s.weight(for: "halfway") - 10.0 / 21.0) < 1e-9)
        #expect(s.weight(for: "done") == 1)
    }

    @Test func zeroCooldownDisablesDecay() {
        #expect(selector(cooldown: 0, history: ["a": date(2026, 11, 22)]).weight(for: "a") == 1)
    }
}

// MARK: - Selection

@Suite struct SelectionTests {
    let now = date(2026, 11, 22)

    /// 40 recent, 40 on-this-date, 400 archive.
    func pool() -> [PhotoItem] {
        var items: [PhotoItem] = []
        for i in 0..<40 { items.append(item("r\(i)", 2026, 11, 1 + i % 20)) }
        for i in 0..<40 { items.append(item("o\(i)", 2010 + i % 15, 11, 20 + i % 3)) }
        for i in 0..<400 { items.append(item("a\(i)", 2010 + i % 15, 3 + i % 6, 1 + i % 28)) }
        return items
    }

    func config(size: Int = 100) -> Config {
        var c = Config()
        c.albumSize = size
        return c
    }

    @Test func quotasFollowShares() {
        let s = PhotoSelector(config: config(size: 150), history: History(), now: now, calendar: utc)
        let q = s.quotas()
        #expect(q[.recent] == 30)
        #expect(q[.onThisDate] == 38)   // 37.5 rounds up
        #expect(q[.archive] == 82)
        #expect(q.values.reduce(0, +) == 150)
    }

    @Test func fillsEachBucketToQuota() {
        var rng = SeededGenerator(seed: 1)
        let s = PhotoSelector(config: config(size: 100), history: History(), now: now, calendar: utc)
        let r = s.select(pool: pool(), using: &rng)
        #expect(r.selected.count == 100)
        #expect(r.filled[.recent] == 20)
        #expect(r.filled[.onThisDate] == 25)
        #expect(r.filled[.archive] == 55)
        #expect(Set(r.selected.map(\.item.id)).count == 100)   // no duplicates
    }

    @Test func shortBucketSpillsIntoArchive() {
        var c = config(size: 100)
        c.buckets.recent.share = 0.5
        let small = pool().filter { !$0.id.hasPrefix("r") } + [item("r0", 2026, 11, 20), item("r1", 2026, 11, 21)]
        var rng = SeededGenerator(seed: 2)
        let r = PhotoSelector(config: c, history: History(), now: now, calendar: utc).select(pool: small, using: &rng)
        #expect(r.filled[.recent] == 2)
        #expect(r.selected.count == 100)
        #expect(r.notes.contains { $0.contains("recent bucket filled 2") })
    }

    @Test func tinyPoolFillsWhatItCan() {
        let tiny = [item("r0", 2026, 11, 20), item("o0", 2015, 11, 22), item("a0", 2015, 4, 1)]
        var rng = SeededGenerator(seed: 3)
        let r = PhotoSelector(config: config(size: 150), history: History(), now: now, calendar: utc).select(pool: tiny, using: &rng)
        #expect(r.selected.count == 3)
    }

    @Test func seedIsReproducible() {
        let s = PhotoSelector(config: config(), history: History(), now: now, calendar: utc)
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42), c = SeededGenerator(seed: 43)
        let ra = s.select(pool: pool(), using: &a).selected.map(\.item.id)
        let rb = s.select(pool: pool(), using: &b).selected.map(\.item.id)
        let rc = s.select(pool: pool(), using: &c).selected.map(\.item.id)
        #expect(ra == rb)
        #expect(ra != rc)
    }

    @Test func cooldownReducesRepeats() {
        // Show half the archive yesterday; the next draw should mostly avoid it.
        let shown = (0..<200).map { "a\($0)" }
        let history = History(entries: Dictionary(uniqueKeysWithValues: shown.map { ($0, History.Entry(lastShown: date(2026, 11, 21), timesShown: 1)) }))
        var rng = SeededGenerator(seed: 7)
        let r = PhotoSelector(config: config(), history: history, now: now, calendar: utc).select(pool: pool(), using: &rng)
        let repeats = r.selected.filter { shown.contains($0.item.id) }.count
        #expect(repeats < 10)
    }

    @Test func zeroWeightIsNeverDrawn() {
        var c = config(size: 10)
        c.minWeight = 0
        c.buckets = .init(recent: .init(share: 0), onThisDate: .init(share: 0), archive: .init(share: 1))
        let items = (0..<20).map { item("a\($0)", 2015, 4, 1) }
        let history = History(entries: Dictionary(uniqueKeysWithValues: (0..<15).map { ("a\($0)", History.Entry(lastShown: now, timesShown: 1)) }))
        var rng = SeededGenerator(seed: 9)
        let r = PhotoSelector(config: c, history: history, now: now, calendar: utc).select(pool: items, using: &rng)
        #expect(Set(r.selected.map(\.item.id)) == Set((15..<20).map { "a\($0)" }))
    }
}

// MARK: - Diff, history, config

@Suite struct SupportTests {
    @Test func diffOnlyTouchesChanges() {
        let d = AlbumDiff(current: ["a", "b", "c"], target: ["b", "c", "d", "e"])
        #expect(d.toAdd == ["d", "e"])
        #expect(d.toRemove == ["a"])
        #expect(d.kept == 2)
        #expect(AlbumDiff(current: ["a"], target: ["a"]).isEmpty)
    }

    @Test func historyRecordsAndPrunes() {
        var h = History()
        let d1 = date(2026, 11, 21), d2 = date(2026, 11, 22)
        h.record(album: ["a", "b", "c"], added: ["a", "b", "c"], on: d1, pool: ["a", "b", "c"])
        h.record(album: ["a"], added: [], on: d2, pool: ["a", "c"])
        #expect(h.entries["a"] == History.Entry(lastShown: d2, timesShown: 2, inAlbumSince: d1))
        #expect(h.entries["b"] == nil)                       // no longer a favorite
        #expect(h.entries["c"]?.inAlbumSince == nil)         // left the album
        #expect(h.entries["c"]?.timesShown == 1)
    }

    @Test func configDefaultsFillMissingKeys() throws {
        let json = #"{"albumName": "TV", "buckets": {"recent": {"share": 0.3}}}"#
        let c = try JSONStore.decoder().decode(Config.self, from: Data(json.utf8))
        #expect(c.albumName == "TV")
        #expect(c.albumSize == 150)
        #expect(c.buckets.recent.share == 0.3)
        #expect(c.buckets.recent.windowDays == 30)
        #expect(c.buckets.archive.share == 0.55)
        #expect(c.cooldownDays == 21)
        #expect(c.validationErrors().isEmpty)
        #expect(!c.warnings().isEmpty)   // shares add to 1.1
    }

    @Test func configValidation() {
        var c = Config()
        c.albumSize = 0
        c.minWeight = 2
        #expect(c.validationErrors().count == 2)
    }

    @Test func sampleConfigParses() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/config.sample.json")
        let c = try #require(try JSONStore.load(Config.self, from: url))
        #expect(c.validationErrors().isEmpty)
        #expect(c.warnings().isEmpty)
    }
}
