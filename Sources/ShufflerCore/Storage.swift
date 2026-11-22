import Foundation

/// Locations of the config, state, history and log files.
public struct Paths: Sendable {
    public static let toolName = "PhotoShuffler"

    public let supportDirectory: URL
    public let configFile: URL
    public let stateFile: URL
    public let historyFile: URL
    public let logFile: URL

    /// `configOverride` lets tests and manual runs use another folder;
    /// state and history always live next to the config file.
    public init(configOverride: URL? = nil) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        if let configOverride {
            configFile = configOverride
            supportDirectory = configOverride.deletingLastPathComponent()
        } else {
            supportDirectory = home.appendingPathComponent("Library/Application Support/\(Paths.toolName)", isDirectory: true)
            configFile = supportDirectory.appendingPathComponent("config.json")
        }
        stateFile = supportDirectory.appendingPathComponent("state.json")
        historyFile = supportDirectory.appendingPathComponent("history.json")
        logFile = home.appendingPathComponent("Library/Logs/\(Paths.toolName)/\(Paths.toolName).log")
    }
}

public enum JSONStore {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Returns nil if the file doesn't exist; throws if it exists but can't be parsed.
    public static func load<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder().decode(T.self, from: data)
    }

    /// Writes atomically, creating the parent folder if needed.
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }
}

/// Appends timestamped lines to the log file (and echoes to stdout).
/// Rotates to `.1` once the file passes 5 MB.
public final class RunLogger: @unchecked Sendable {
    private let fileURL: URL?
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()

    /// Pass nil to log to stdout only (used by --dry-run).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL { Self.prepare(fileURL) }
    }

    public func info(_ message: String) { write("INFO", message) }
    public func warn(_ message: String) { write("WARN", message) }
    public func error(_ message: String) { write("ERROR", message) }

    /// Prints to stdout without writing to the log file.
    public func console(_ message: String) { print(message) }

    private func write(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        if level == "ERROR" {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        } else {
            print(line)
        }
        guard let fileURL, let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func prepare(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
    }
}
