import Foundation

/// Result of running the 7-Zip CLI.
public struct SevenZipProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Closure that runs the 7-Zip CLI binary at `executableURL` with
/// `arguments`, captures stdout/stderr, and returns the result.
/// Tests inject a mock implementation; production uses
/// `SevenZipDefaultRunner.run`.
public typealias SevenZipRunner = @Sendable (URL, [String], String?) async throws -> SevenZipProcessResult

/// Streaming variant used for archive creation: the CLI is run with
/// `-bsp1` so it emits percentage progress to stdout, which is drained
/// incrementally (avoiding the pipe-fill deadlock) and forwarded to
/// `onProgress` as a `0.0...1.0` fraction.  stderr still goes to a temp
/// file like `run`.  Falls back to non-streaming callers by passing a nil
/// `onProgress`.
public typealias SevenZipProgressRunner = @Sendable (URL, [String], String?, (@Sendable (Double) -> Void)?) async throws -> SevenZipProcessResult

/// Default `Process`-based runner. Redirects stdout/stderr to temp files to
/// avoid the classic Pipe-fill deadlock when the CLI emits more than one
/// kernel pipe buffer (~64 KiB) of output.
public enum SevenZipDefaultRunner {
    public static let run: SevenZipRunner = { executableURL, arguments, stdin in
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("M7Archiver-7z-")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            let stdoutURL = scratch.appendingPathComponent("stdout.log")
            let stderrURL = scratch.appendingPathComponent("stderr.log")
            fileManager.createFile(atPath: stdoutURL.path, contents: nil)
            fileManager.createFile(atPath: stderrURL.path, contents: nil)

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle
            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                if let data = stdin.data(using: .utf8) {
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
                try input.fileHandleForWriting.close()
            } else {
                process.standardInput = FileHandle.nullDevice
                try process.run()
            }
            await withTaskCancellationHandler {
                process.waitUntilExit()
            } onCancel: {
                process.terminate()
            }

            try? stdoutHandle.close()
            try? stderrHandle.close()

            let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
            let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

            return SevenZipProcessResult(
                exitCode: process.terminationStatus,
                stdout: String(decoding: stdoutData, as: UTF8.self),
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }.value
    }

    /// Streaming runner for archive creation.  Drains stdout via a `Pipe`
    /// `readabilityHandler` (so the kernel pipe buffer never fills and
    /// deadlocks the process), parses the latest `NN%` token, and forwards
    /// it as a fraction.  stderr is redirected to a temp file like `run`.
    public static let runStreaming: SevenZipProgressRunner = { executableURL, arguments, stdin, onProgress in
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("M7Archiver-7z-")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: scratch) }

            let stderrURL = scratch.appendingPathComponent("stderr.log")
            fileManager.createFile(atPath: stderrURL.path, contents: nil)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)

            let stdoutPipe = Pipe()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrHandle

            // Accumulated stdout as a string for both progress parsing and
            // the final result (error messages reference stdout).  Carriage
            // returns / backspaces are left in place — the `NN%` regex
            // matches regardless of the surrounding control bytes.
            let accumulator = SevenZipProgressAccumulator(onProgress: onProgress)
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                accumulator.append(chunk)
            }

            if let stdin {
                let input = Pipe()
                process.standardInput = input
                try process.run()
                if let data = stdin.data(using: .utf8) {
                    try input.fileHandleForWriting.write(contentsOf: data)
                }
                try input.fileHandleForWriting.close()
            } else {
                process.standardInput = FileHandle.nullDevice
                try process.run()
            }
            await withTaskCancellationHandler {
                process.waitUntilExit()
            } onCancel: {
                process.terminate()
            }

            // Stop the handler and drain any trailing buffered bytes.
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            let trailing = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            if !trailing.isEmpty { accumulator.append(trailing) }
            try? stderrHandle.close()

            let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

            return SevenZipProcessResult(
                exitCode: process.terminationStatus,
                stdout: accumulator.string,
                stderr: String(decoding: stderrData, as: UTF8.self)
            )
        }.value
    }
}

/// Thread-safe accumulator for streaming 7-Zip stdout.  Decodes incoming
/// bytes as UTF-8, invokes `onProgress` with the latest parsed fraction,
/// and exposes the full decoded string for the final result.
final class SevenZipProgressAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var lastEmitted: Double?
    private let onProgress: (@Sendable (Double) -> Void)?

    init(onProgress: (@Sendable (Double) -> Void)?) {
        self.onProgress = onProgress
    }

    func append(_ chunk: Data) {
        let fraction: Double?
        let callback: (@Sendable (Double) -> Void)?
        lock.lock()
        data.append(chunk)
        fraction = SevenZipDefaultRunner.parseProgress(from: data)
        callback = onProgress
        lock.unlock()
        // Re-emit only when the value actually changes, to avoid flooding
        // the main actor with identical fractions.
        if let fraction, fraction != lastEmitted {
            lastEmitted = fraction
            callback?(fraction)
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

public extension SevenZipDefaultRunner {
    /// Extracts the latest completion fraction (`0.0...1.0`) from a chunk of
    /// 7-Zip `-bsp1` stdout.  7-Zip writes the percentage as `NN%` (with
    /// leading spaces and backspace/carriage-return overwrite sequences),
    /// so scanning for the last `(\d{1,3})%` match is robust to the
    /// surrounding control bytes.  Returns nil when no percentage has been
    /// emitted yet.
    static func parseProgress(from data: Data) -> Double? {
        let string = String(decoding: data, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,3})%"#) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        guard let match = regex.matches(in: string, range: range).last,
              match.numberOfRanges >= 2,
              let numberRange = Range(match.range(at: 1), in: string),
              let value = Int(string[numberRange])
        else { return nil }
        return min(max(Double(value) / 100.0, 0.0), 1.0)
    }
}
