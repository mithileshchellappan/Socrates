#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// What to launch (docs/plan-m35.md §3.2).
struct ChildProcessSpec: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    /// Written to stdin, which is then closed; nil: stdin is /dev/null.
    var input: Data?
}

struct ChildProcessResult: Sendable {
    var status: Int32
    var reason: Process.TerminationReason
    /// The first 64 KB of stderr (diagnostics only; logged `.private`).
    var standardError: String
}

/// What the line handler wants after a stdout line.
enum LineDecision: Sendable {
    case proceed
    /// Terminate the child (SIGTERM, SIGKILL after 2 s); remaining output is drained unread.
    case stop
}

/// Runs one child process with structured concurrency only: `Process` and pipes, each pipe read
/// through its own readability handler (never `FileHandle.bytes`: its reads share one serial
/// executor, so a quiet stderr held every stdout line back until stderr spoke or closed), stdout
/// split into lines as it arrives, the exit through `terminationHandler`, and cancellation killing
/// the child (SIGTERM, then SIGKILL after 2 s).
enum ChildProcess {
    static let standardErrorLimit = 64 * 1024

    /// The children running now (their pids), so the app's quit can end them.
    private static let running = Mutex<Set<pid_t>>([])

    /// SIGTERM to every child still running (the app is quitting: a tool loop's server lives in
    /// the app, and nothing would read the child's output).
    static func terminateAll() {
        for pid in running.withLock({ $0 }) { kill(pid, SIGTERM) }
    }

    /// Launches `spec` and calls `onLine` with every stdout line (without its "\n"), in order, on
    /// the calling task. Returns once the child has exited. Throws `CancellationError` when the
    /// calling task was cancelled (the child is killed first) and whatever `onLine` throws (the
    /// child is killed first, too).
    static func run(
        _ spec: ChildProcessSpec,
        onLine: (Data) async throws -> LineDecision
    ) async throws -> ChildProcessResult {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        if let directory = spec.directory { process.currentDirectoryURL = directory }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = spec.input == nil ? FileHandle.nullDevice : stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exit = ExitSignal()
        process.terminationHandler = { process in
            _ = running.withLock { $0.remove(process.processIdentifier) }
            exit.exited(status: process.terminationStatus, reason: process.terminationReason)
        }
        do {
            try process.run()
        } catch {
            throw ClaudeError.claudeCodeProcess("could not start \(spec.executable.lastPathComponent) (\(error.localizedDescription))")
        }
        let pid = process.processIdentifier
        running.withLock { pids in
            if process.isRunning { pids.insert(pid) }
        }

        let standardOutput = chunks(of: stdoutPipe.fileHandleForReading)
        let standardErrorChunks = chunks(of: stderrPipe.fileHandleForReading)
        return try await withTaskCancellationHandler {
            async let standardError = collect(standardErrorChunks, limit: standardErrorLimit)
            async let wroteInput: Void = write(spec.input, to: stdinPipe.fileHandleForWriting)

            var failure: (any Error)?
            var stopped = false
            var line = Data()
            do {
                for await chunk in standardOutput {
                    // After a stop the rest is drained unread.
                    guard !stopped else { continue }
                    // Split on "\n" only: JSON lines may hold U+2028/U+2029, which `lines` splits on.
                    var start = chunk.startIndex
                    while !stopped, let newline = chunk[start...].firstIndex(of: 0x0A) {
                        line.append(chunk[start..<newline])
                        start = chunk.index(after: newline)
                        if !line.isEmpty, try await onLine(line) == .stop {
                            stopped = true
                            terminate(process)
                        }
                        line.removeAll(keepingCapacity: true)
                    }
                    if !stopped { line.append(chunk[start...]) }
                }
                // A cancelled task ends the stream early: no partial last line.
                try Task.checkCancellation()
                if !stopped, !line.isEmpty, try await onLine(line) == .stop {
                    stopped = true
                }
            } catch {
                failure = error
                terminate(process)
            }
            let (status, reason) = await exit.wait()
            _ = await wroteInput
            let errorText = await standardError
            if let failure { throw failure }
            try Task.checkCancellation()
            return ChildProcessResult(status: status, reason: reason, standardError: errorText)
        } onCancel: {
            terminate(process)
        }
    }

    /// Runs `spec` to completion and returns stdout, killing it after `timeout`.
    static func output(_ spec: ChildProcessSpec, timeout: Duration) async throws -> (result: ChildProcessResult, output: String) {
        try await withThrowingTaskGroup(of: (ChildProcessResult, String)?.self) { group in
            group.addTask {
                var lines: [String] = []
                let result = try await run(spec) { line in
                    lines.append(String(decoding: line, as: UTF8.self))
                    return .proceed
                }
                return (result, lines.joined(separator: "\n"))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                throw ClaudeError.claudeCodeProcess("\(spec.executable.lastPathComponent) did not answer within \(timeout)")
            }
            return value
        }
    }

    /// SIGTERM now, SIGKILL after 2 s if the child is still running.
    static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private static func write(_ input: Data?, to handle: FileHandle) async {
        guard let input else { return }
        // A child that exits early must not raise SIGPIPE in the app.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try handle.write(contentsOf: input)
        } catch {
            ClaudeClient.logger.debug("stdin closed early: \(String(describing: error), privacy: .private)")
        }
        try? handle.close()
    }

    /// What `handle` reads, as it arrives, until end of file. Each handle has its own readability
    /// source, so one pipe never waits for another.
    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { _ in handle.readabilityHandler = nil }
        }
    }

    /// The first `limit` bytes; the rest is drained so the child never blocks on a full pipe.
    private static func collect(_ chunks: AsyncStream<Data>, limit: Int) async -> String {
        var data = Data()
        for await chunk in chunks where data.count < limit {
            data.append(chunk.prefix(limit - data.count))
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The child's exit, awaited independently of task cancellation (a killed child exits soon).
private final class ExitSignal: Sendable {
    private struct State {
        var exit: (Int32, Process.TerminationReason)?
        var waiter: CheckedContinuation<(Int32, Process.TerminationReason), Never>?
    }

    private let state = Mutex(State())

    func exited(status: Int32, reason: Process.TerminationReason) {
        let waiter = state.withLock { state in
            state.exit = (status, reason)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: (status, reason))
    }

    func wait() async -> (Int32, Process.TerminationReason) {
        await withCheckedContinuation { continuation in
            let exit = state.withLock { state in
                if state.exit == nil { state.waiter = continuation }
                return state.exit
            }
            if let exit { continuation.resume(returning: exit) }
        }
    }
}
#endif
