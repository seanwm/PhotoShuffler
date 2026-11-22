import Foundation
import Testing
@testable import ShufflerCore

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: 3))!
}

private func archivePool(_ n: Int, prefix: String = "a") -> [PhotoItem] {
    (0..<n).map { PhotoItem(id: "\(prefix)\($0)", creationDate: date(2010 + $0 % 12, 3 + $0 % 6, 1 + $0 % 28)) }
}

private func config(size: Int = 150, nights: Int = 3) -> Config {
    var c = Config()
    c.albumSize = size
    c.nightsInAlbum = nights
    return c
}

/// Runs the tool for several nights, applying each plan and recording history
/// the same way the CLI does.
private struct Simulation {
    var config: Config
    var pool: [PhotoItem]
    var album: [String] = []
    var history = History()
    var day = date(2026, 6, 1)
    var rng = SeededGenerator(seed: 11)
    /// id → nights per completed stay
    var stays: [String: [Int]] = [:]
    var stayStart: [String: Int] = [:]
    var night = 0
    var plans: [NightlyPlan] = []

    init(config: Config, pool: [PhotoItem]) {
        self.config = config
        self.pool = pool
    }

    mutating func runNight() {
        let selector = PhotoSelector(config: config, history: history, now: day, calendar: utc)
        let plan = selector.plan(pool: pool, currentAlbum: album, using: &rng)
        let diff = AlbumDiff(current: album, target: plan.target)
        for id in diff.toRemove { if let s = stayStart.removeValue(forKey: id) { stays[id, default: []].append(night - s) } }
        for id in diff.toAdd { stayStart[id] = night }
        album = plan.target
        history.record(album: album, added: Set(diff.toAdd), on: day, pool: Set(pool.map(\.id)))
        plans.append(plan)
        night += 1
        day = utc.date(byAdding: .day, value: 1, to: day)!
    }
}

@Suite struct RotationTests {
    @Test func defaultsMatchTheNewRules() {
        let c = Config()
        #expect(c.buckets.onThisDate.windowDays == 14)
        #expect(c.buckets.recent.maxNights == 10)
        #expect(c.nightsInAlbum == 3)
        #expect(PhotoSelector(config: c, history: History(), now: Date()).rotationSlots == 50)
        #expect(PhotoSelector(config: config(nights: 4), history: History(), now: Date()).rotationSlots == 38)
    }

    @Test func onThisDateWindowIsFourteenDaysByDefault() {
        let now = date(2026, 11, 22)
        let b = Bucketer(config: Config(), history: History(), now: now, calendar: utc)
        #expect(b.bucket(for: PhotoItem(id: "a", creationDate: date(2018, 12, 6))) == .onThisDate)   // +14
        #expect(b.bucket(for: PhotoItem(id: "b", creationDate: date(2018, 11, 8))) == .onThisDate)   // -14
        #expect(b.bucket(for: PhotoItem(id: "c", creationDate: date(2018, 12, 7))) == .archive)      // +15
    }

    @Test func recentPhotoMovesToArchiveAfterItsNights() {
        let now = date(2026, 11, 22)
        let photo = PhotoItem(id: "r", creationDate: date(2026, 11, 15))
        func bucket(shown: Int, cap: Int = 10) -> Bucket {
            var c = Config()
            c.buckets.recent.maxNights = cap
            let h = History(entries: shown == 0 ? [:] : ["r": .init(lastShown: now, timesShown: shown)])
            return Bucketer(config: c, history: h, now: now, calendar: utc).bucket(for: photo)
        }
        #expect(bucket(shown: 0) == .recent)
        #expect(bucket(shown: 9) == .recent)
        #expect(bucket(shown: 10) == .archive)
        #expect(bucket(shown: 50, cap: 0) == .recent)   // 0 = no cap
    }

    @Test func firstNightFillsTheAlbum() {
        var sim = Simulation(config: config(), pool: archivePool(600))
        sim.runNight()
        #expect(sim.album.count == 150)
        #expect(sim.plans[0].kept.isEmpty)
    }

    @Test func eachPhotoStaysNightsInAlbumAtSteadyState() {
        for nights in [3, 4] {
            var sim = Simulation(config: config(nights: nights), pool: archivePool(1500))
            for _ in 0..<16 { sim.runNight() }
            let slots = Int((150.0 / Double(nights)).rounded(.up))
            for plan in sim.plans.dropFirst() {
                #expect(plan.rotatedOut.count == slots)
                #expect(plan.draw.selected.count == slots)
                #expect(plan.target.count == 150)
            }
            // Photos added after the first night: every finished stay lasts about
            // nightsInAlbum nights (exactly, when 150 divides evenly).
            let allowed = 150 % slots == 0 ? [nights] : [nights - 1, nights]
            let firstCohort = Set(sim.plans[0].target)
            let checked = sim.stays.filter { !firstCohort.contains($0.key) }.flatMap(\.value)
            #expect(checked.count > 300)
            for stay in checked {
                #expect(allowed.contains(stay), "stay of \(stay) nights with nightsInAlbum \(nights)")
            }
        }
    }

    @Test func neverReaddsTonightWhatWasInTheAlbum() {
        var sim = Simulation(config: config(), pool: archivePool(400))
        sim.runNight()
        let before = Set(sim.album)
        sim.runNight()
        #expect(Set(sim.plans[1].draw.selected.map(\.item.id)).isDisjoint(with: before))
    }

    @Test func ineligiblePhotosCountTowardTheRotation() {
        var sim = Simulation(config: config(), pool: archivePool(600))
        sim.runNight()
        sim.runNight()
        // Un-favorite 10 photos that are in the album.
        let gone = Set(sim.album.suffix(10))
        sim.pool.removeAll { gone.contains($0.id) }
        sim.runNight()
        let plan = sim.plans[2]
        #expect(Set(plan.ineligible) == gone)
        #expect(plan.rotatedOut.count == 40)
        #expect(plan.draw.selected.count == 50)
        #expect(sim.album.count == 150)
    }

    @Test func photosWithUnknownStayRotateOutFirst() {
        // Adopting an existing album: nothing in history yet.
        let pool = archivePool(600)
        let existing = Array(pool.prefix(150).map(\.id))
        var sim = Simulation(config: config(), pool: pool)
        sim.album = existing
        var h = History()
        // Pretend the last 100 have known, recent stays.
        for id in existing.suffix(100) { h.entries[id] = .init(lastShown: date(2026, 5, 31), timesShown: 1, inAlbumSince: date(2026, 5, 31)) }
        sim.history = h
        sim.runNight()
        #expect(Set(sim.plans[0].rotatedOut) == Set(existing.prefix(50)))
    }

    @Test func smallPoolKeepsOutgoingPhotosRatherThanShrinking() {
        var sim = Simulation(config: config(), pool: archivePool(160))
        sim.runNight()
        sim.runNight()
        let plan = sim.plans[1]
        #expect(plan.draw.selected.count == 10)
        #expect(plan.kept.count == 140)
        #expect(sim.album.count == 150)
        #expect(plan.draw.notes.contains { $0.contains("kept 40") })
    }

    @Test func oneNightReplacesTheWholeAlbum() {
        var sim = Simulation(config: config(nights: 1), pool: archivePool(600))
        sim.runNight()
        let first = Set(sim.album)
        sim.runNight()
        #expect(Set(sim.album).isDisjoint(with: first))
    }

    @Test func bucketSharesHoldAcrossTheAlbum() {
        // 60 recent, 200 on-this-date, 1500 archive, relative to a fixed date.
        var pool = archivePool(1500)
        let start = date(2026, 6, 1)
        pool += (0..<60).map { PhotoItem(id: "r\($0)", creationDate: utc.date(byAdding: .day, value: -($0 % 25), to: start)!) }
        pool += (0..<200).map { PhotoItem(id: "o\($0)", creationDate: date(2008 + $0 % 15, 6, 1 + $0 % 5)) }
        var sim = Simulation(config: config(), pool: pool)
        sim.runNight()
        let mix = sim.plans[0].composition
        #expect(mix[.recent] == 30)
        #expect(mix[.onThisDate] == 38)
        #expect(mix[.archive] == 82)
    }
}
