import Foundation
import Photos
import ShufflerCore

struct Runner {
    let options: Options
    let paths: Paths
    let now = Date()

    init(options: Options) {
        self.options = options
        self.paths = Paths(configOverride: options.configPath.map { URL(fileURLWithPath: $0) })
    }

    func run() -> ExitCode {
        if options.authorize { return authorize() }

        // Dry runs log to the terminal only, so they write nothing to disk.
        let log = RunLogger(fileURL: options.dryRun ? nil : paths.logFile)
        do {
            return try perform(log: log)
        } catch {
            log.error("\(error)")
            return .failure
        }
    }

    // MARK: - --authorize

    private func authorize() -> ExitCode {
        let log = RunLogger(fileURL: paths.logFile)
        log.info("authorize: current Photos access is \(PhotoLibrary.authorizationStatus().label); requesting read/write access")
        let status = PhotoLibrary.requestAuthorization(timeout: 300)
        log.info("authorize: Photos access is now \(status.label)")
        return status == .authorized ? .success : .notAuthorized
    }

    // MARK: - Main run

    private func perform(log: RunLogger) throws -> ExitCode {
        let mode = options.dryRun ? "dry run" : "run"
        log.info("=== PhotoShuffler \(Options.version) \(mode) ===")

        // Config
        var config: Config
        if let loaded = try loadConfig() {
            config = loaded
        } else if options.dryRun {
            log.warn("no config at \(paths.configFile.path); using defaults for this dry run")
            config = Config()
        } else {
            try JSONStore.save(Config(), to: paths.configFile)
            log.warn("created a default config at \(paths.configFile.path). Review it (especially albumName), then run again.")
            return .configCreated
        }
        if let seed = options.seed { config.seed = seed }
        let problems = config.validationErrors()
        guard problems.isEmpty else {
            throw CLIError("invalid config \(paths.configFile.path):\n  - " + problems.joined(separator: "\n  - "))
        }
        config.warnings().forEach { log.warn($0) }

        // Photos access
        var status = PhotoLibrary.authorizationStatus()
        if status == .notDetermined {
            log.info("Photos access not determined; requesting")
            status = PhotoLibrary.requestAuthorization(timeout: 120)
        }
        guard status == .authorized else {
            log.error(PhotoLibraryError.notAuthorized(status).description)
            return .notAuthorized
        }

        // State and history
        var state: State
        do {
            state = try JSONStore.load(State.self, from: paths.stateFile) ?? State()
        } catch {
            // Don't guess: a broken state file could make us lose track of the album.
            throw CLIError("can't read \(paths.stateFile.path): \(error). Fix or delete it.")
        }
        var history: History
        do {
            history = try JSONStore.load(History.self, from: paths.historyFile) ?? History()
        } catch {
            log.warn("can't read \(paths.historyFile.path) (\(error)); starting with empty history")
            history = History()
        }

        // Source pool
        let library = PhotoLibrary()
        let pool = try library.favoritePool(includeVideos: config.includeVideos)
        guard !pool.isEmpty else {
            // An empty target would empty the album. Leave it alone instead.
            throw CLIError("Favorites has no \(config.includeVideos ? "photos or videos" : "photos"); leaving the album unchanged")
        }

        // Album
        let lookup = try library.findAlbum(storedID: state.albumLocalIdentifier, name: config.albumName)
        let album: PHAssetCollection?
        switch lookup {
        case .byIdentifier(let found):
            album = found
            if found.localizedTitle != config.albumName {
                log.warn("album found by stored identifier is titled \"\(found.localizedTitle ?? "")\", not \"\(config.albumName)\". Using it anyway. To switch albums, delete state.json.")
            }
        case .byName(let found):
            album = found
            log.info("found album \"\(config.albumName)\" by name")
        case .notFound:
            album = nil
            log.info("no album named \"\(config.albumName)\"; it will be created")
        }
        let currentIDs = album.map(library.assetIDs(in:)) ?? []

        // Selection
        var rng = SeededGenerator(seed: config.seed)
        let selector = PhotoSelector(config: config, history: history, now: now)
        let plan = selector.plan(pool: pool, currentAlbum: currentIDs, using: &rng)
        let targetIDs = plan.target
        let diff = AlbumDiff(current: currentIDs, target: targetIDs)

        logSummary(plan: plan, pool: pool, current: currentIDs.count, log: log)

        if options.dryRun {
            printPlan(plan, pool: pool, history: history, log: log)
            log.console("")
            log.console("Planned changes\(album == nil ? " (album \"\(config.albumName)\" would be created first)" : ""):")
            log.console("  add \(diff.toAdd.count), remove \(diff.toRemove.count), keep \(diff.kept)")
            log.console("Dry run: nothing was changed.")
            return .success
        }

        // Apply
        let target: PHAssetCollection
        if let album {
            target = album
        } else {
            target = try library.createAlbum(named: config.albumName)
            log.info("created album \"\(config.albumName)\"")
        }
        if state.albumLocalIdentifier != target.localIdentifier {
            state.albumLocalIdentifier = target.localIdentifier
            // Save right away so a later failure can't lead to a second album.
            try JSONStore.save(state, to: paths.stateFile)
            log.info("recorded album identifier \(target.localIdentifier)")
        }

        let applied = album == nil ? AlbumDiff(current: [], target: targetIDs) : diff
        try library.apply(applied, to: target)
        log.info("applied: added \(applied.toAdd.count), removed \(applied.toRemove.count), kept \(applied.kept)")

        history.record(album: targetIDs, added: Set(applied.toAdd), on: now, pool: Set(pool.map(\.id)))
        try JSONStore.save(history, to: paths.historyFile)
        state.lastRun = now
        try JSONStore.save(state, to: paths.stateFile)
        log.info("done")
        return .success
    }

    private func loadConfig() throws -> Config? {
        do {
            return try JSONStore.load(Config.self, from: paths.configFile)
        } catch {
            throw CLIError("can't parse \(paths.configFile.path): \(error)")
        }
    }

    // MARK: - Output

    private func logSummary(plan: NightlyPlan, pool: [PhotoItem], current: Int, log: RunLogger) {
        log.info("source pool: \(pool.count) favorites; album currently has \(current)")
        log.info("keep \(plan.kept.count), rotate out \(plan.rotatedOut.count), remove ineligible \(plan.ineligible.count), add \(plan.draw.selected.count) (steady-state rotation: \(plan.rotationSlots)/night)")
        log.info("new picks by bucket:")
        for bucket in Bucket.allCases {
            log.info(String(
                format: "  %-11@ quota %4d  candidates %5d  selected %4d",
                bucket.rawValue as NSString,
                plan.draw.quotas[bucket] ?? 0,
                plan.draw.poolCounts[bucket] ?? 0,
                plan.draw.filled[bucket] ?? 0
            ))
        }
        plan.draw.notes.forEach { log.info("  note: \($0)") }
        let mix = Bucket.allCases.map { "\($0.rawValue) \(plan.composition[$0] ?? 0)" }.joined(separator: ", ")
        log.info("album after this run: \(plan.target.count) items (\(mix))")
    }

    private func printPlan(_ plan: NightlyPlan, pool: [PhotoItem], history: History, log: RunLogger) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func created(_ id: String) -> String {
            byID[id]?.creationDate.map(formatter.string(from:)) ?? "unknown   "
        }
        func since(_ id: String) -> String {
            history.inAlbumSince(id).map(formatter.string(from:)) ?? "unknown   "
        }

        log.console("")
        log.console("Adding \(plan.draw.selected.count) (created, bucket, weight, asset id):")
        let sorted = plan.draw.selected.sorted {
            ($0.bucket.rawValue, $0.item.creationDate ?? .distantPast) < ($1.bucket.rawValue, $1.item.creationDate ?? .distantPast)
        }
        for photo in sorted {
            log.console(String(format: "  %@  %-10@  %.2f  %@", created(photo.item.id), photo.bucket.rawValue as NSString, photo.weight, photo.item.id))
        }
        if !plan.rotatedOut.isEmpty {
            log.console("")
            log.console("Rotating out \(plan.rotatedOut.count) (in album since, created, asset id):")
            for id in plan.rotatedOut { log.console("  \(since(id))  \(created(id))  \(id)") }
        }
        if !plan.ineligible.isEmpty {
            log.console("")
            log.console("Removing \(plan.ineligible.count) no longer eligible (not a favorite, a video, or added by hand):")
            for id in plan.ineligible { log.console("  \(id)") }
        }
        log.console("")
        log.console("Keeping \(plan.kept.count).")
    }
}
