import Foundation

let options: Options
do {
    options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(ExitCode.failure.rawValue)
}

exit(Runner(options: options).run().rawValue)
