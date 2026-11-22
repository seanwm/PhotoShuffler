import Foundation

struct Options {
    var dryRun = false
    var authorize = false
    var seed: UInt64?
    var configPath: String?

    static let usage = """
    Usage: PhotoShuffler [options]

    Refreshes one Photos album with a weighted selection of your Favorites.

    Options:
      --dry-run          Print the proposed selection and planned changes. Writes nothing.
      --seed <n>         Fixed random seed (overrides "seed" in the config).
      --config <path>    Use this config file. State and history live next to it.
                         Default: ~/Library/Application Support/PhotoShuffler/config.json
      --authorize        Ask macOS for Photos access, report the result, and exit.
      --version          Print the version.
      -h, --help         Show this help.

    Exit codes: 0 success, 1 error, 2 config created (review it, then rerun),
                3 Photos access not granted.
    """

    static func parse(_ args: [String]) throws -> Options {
        var options = Options()
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--dry-run":
                options.dryRun = true
            case "--authorize":
                options.authorize = true
            case "--seed":
                guard let value = iterator.next(), let seed = UInt64(value) else {
                    throw CLIError("--seed needs a non-negative integer")
                }
                options.seed = seed
            case "--config":
                guard let value = iterator.next() else { throw CLIError("--config needs a path") }
                options.configPath = (value as NSString).expandingTildeInPath
            case "--version":
                print("PhotoShuffler \(version)")
                exit(0)
            case "-h", "--help":
                print(usage)
                exit(0)
            default:
                // LaunchServices may pass -psn_… when opened via `open`; ignore it.
                if arg.hasPrefix("-psn_") { continue }
                throw CLIError("unknown option \(arg)\n\n\(usage)")
            }
        }
        return options
    }

    static let version = "0.1.0"
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ExitCode: Int32 {
    case success = 0
    case failure = 1
    case configCreated = 2
    case notAuthorized = 3
}
