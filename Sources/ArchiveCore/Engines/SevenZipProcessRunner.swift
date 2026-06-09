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
}
