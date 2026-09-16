import Foundation
import os

/// How a child process ended.
nonisolated enum ProcessTermination: Sendable, Equatable {
    /// The process exited on its own, with the given status.
    case exited(Int32)
    /// We killed it because the task was cancelled.
    case cancelled
    /// We killed it because it outran its timeout.
    case timedOut
    /// We killed it because its output passed `outputByteLimit`.
    case outputLimitExceeded
    /// It died from a signal we did not send.
    case signalled(Int32)
}

/// A process to run.
nonisolated struct ProcessInvocation: Sendable {
    var executable: URL
    var arguments: [String] = []
    var workingDirectory: URL?
    var environment: [String: String] = [:]

    /// Bytes to write to the child's stdin, which is then closed.
    ///
    /// This is how commit messages, pathspec lists and patches reach git — never
    /// as argv elements, which would blow past `ARG_MAX` on any real diff.
    var stdin: [UInt8]?

    /// Wall-clock budget. Every invocation gets one; a git command that blocks
    /// forever is indistinguishable from a hung app.
    var timeout: Duration = .seconds(30)

    /// Cap on each output stream. Guards against `git log -p` on a huge repo
    /// eating all of memory.
    var outputByteLimit: Int = 64 << 20
}

/// What the process produced.
nonisolated struct ProcessResult: Sendable {
    var termination: ProcessTermination

    /// Raw bytes, deliberately **not** `String`. Git paths need not be valid
    /// UTF-8, and decoding belongs in the parsers that know what they are
    /// looking at.
    var stdout: [UInt8]
    var stderr: [UInt8]

    var duration: Duration
    var stdoutTruncated: Bool
    var stderrTruncated: Bool

    var exitCode: Int32 {
        if case .exited(let code) = termination { return code }
        return -1
    }

    var didSucceed: Bool { termination == .exited(0) }

    /// stderr decoded for display and error matching. Lossy on purpose: it must
    /// never fail, and `LC_ALL=C` keeps the text ASCII anyway.
    var stderrText: String { String(decoding: stderr, as: UTF8.self) }

    /// stdout decoded the same way. Git reports the shape of a merge — "Already
    /// up to date", "Fast-forward", "CONFLICT" — on stdout, not stderr.
    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

nonisolated enum ProcessRunnerError: Error, Sendable {
    case launchFailed(String)
}

/// The single place in Grove that spawns a process.
///
/// `scripts/test.sh` fails the build if `Process(` appears in any other file,
/// because the bugs this type exists to prevent are the kind that get
/// reintroduced by a well-meaning one-off call site:
///
/// - **Pipe deadlock.** A pipe buffer is 64 KB. Draining stdout to completion
///   before reading stderr — or calling `waitUntilExit()` before draining at all
///   — hangs forever on any real `git diff`, with no error and no output.
///   Both streams are therefore drained concurrently, on their own queues.
/// - **Lost output.** Resuming when the process terminates drops whatever is
///   still sitting in the pipes. The continuation resumes only once *all three*
///   of stdout EOF, stderr EOF and termination have happened.
/// - **Zombie processes.** Cancellation and timeout escalate SIGTERM → SIGKILL,
///   so a cancelled diff cannot leave a `git` behind.
nonisolated enum ProcessRunner {

    /// Disarms SIGPIPE for the whole process, once, before anything is spawned.
    ///
    /// Writing to a pipe whose read end has closed raises SIGPIPE, and the
    /// default disposition is *terminate the process* — a signal, not a Swift
    /// error, so `try?` around the write cannot save us. A child that exits
    /// before reading all of its stdin is completely routine here (`git apply -`
    /// rejecting a patch, `git commit -F -` failing a hook), so without this a
    /// rejected patch would take Grove down with it. With SIGPIPE ignored the
    /// write simply fails with `EPIPE`, which the writer already handles.
    private static let disarmSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    nonisolated static func run(_ invocation: ProcessInvocation) async throws -> ProcessResult {
        _ = disarmSIGPIPE
        let coordinator = Coordinator(invocation: invocation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                coordinator.start(continuation)
            }
        } onCancel: {
            coordinator.kill(because: .cancelled)
        }
    }
}

// MARK: - Coordinator

/// Owns the process and the three-way completion handshake.
///
/// `@unchecked Sendable` is carried by the `OSAllocatedUnfairLock`: every piece
/// of mutable state lives inside it, and the pipe-reading queues, the timeout
/// timer and the cancellation handler all touch it only through the lock.
private nonisolated final class Coordinator: @unchecked Sendable {

    private struct State {
        var stdoutDone = false
        var stderrDone = false
        var didTerminate = false
        var didResume = false
        var didLaunch = false

        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        var stdoutTruncated = false
        var stderrTruncated = false

        /// Set when *we* killed it, so the reported termination reflects the real
        /// cause rather than the signal git happened to die from.
        var killReason: ProcessTermination?
        var exitCode: Int32 = -1
        var uncaughtSignal: Int32?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let process = Process()
    private let invocation: ProcessInvocation
    private let start = ContinuousClock.now

    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdinPipe = Pipe()

    private var continuation: CheckedContinuation<ProcessResult, any Error>?

    init(invocation: ProcessInvocation) {
        self.invocation = invocation
    }

    // MARK: Start

    func start(_ continuation: CheckedContinuation<ProcessResult, any Error>) {
        self.continuation = continuation

        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        process.environment = invocation.environment

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Never let a child inherit our stdin — a git that finds a TTY can block
        // forever waiting for input nobody will type.
        process.standardInput = invocation.stdin == nil ? FileHandle.nullDevice : stdinPipe

        process.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.withLock { state in
                state.didTerminate = true
                state.exitCode = proc.terminationStatus
                if proc.terminationReason == .uncaughtSignal {
                    state.uncaughtSignal = proc.terminationStatus
                }
            }
            self.finishIfReady()
        }

        do {
            try process.run()
            lock.withLock { $0.didLaunch = true }
        } catch {
            self.continuation = nil
            continuation.resume(
                throwing: ProcessRunnerError.launchFailed(error.localizedDescription))
            return
        }

        drain(stdoutPipe, isStdout: true)
        drain(stderrPipe, isStdout: false)
        writeStdin()
        scheduleTimeout()
    }

    // MARK: Pipes

    /// Reads one stream to EOF on its own queue.
    ///
    /// `availableData` blocks until bytes arrive or the write end closes, so the
    /// two calls must be on separate queues — which is precisely what stops the
    /// deadlock.
    private func drain(_ pipe: Pipe, isStdout: Bool) {
        let handle = pipe.fileHandleForReading

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }  // EOF

                guard let self else { break }

                let overflowed: Bool = self.lock.withLock { state in
                    if isStdout {
                        guard state.stdout.count + chunk.count <= self.invocation.outputByteLimit
                        else {
                            state.stdoutTruncated = true
                            return true
                        }
                        state.stdout.append(contentsOf: chunk)
                    } else {
                        guard state.stderr.count + chunk.count <= self.invocation.outputByteLimit
                        else {
                            state.stderrTruncated = true
                            return true
                        }
                        state.stderr.append(contentsOf: chunk)
                    }
                    return false
                }

                if overflowed {
                    self.kill(because: .outputLimitExceeded)
                    break
                }
            }

            try? handle.close()

            guard let self else { return }
            self.lock.withLock { state in
                if isStdout { state.stdoutDone = true } else { state.stderrDone = true }
            }
            self.finishIfReady()
        }
    }

    /// Writes stdin and closes it. The close matters: `git commit -F -` and
    /// `git apply -` will not proceed until they see EOF.
    private func writeStdin() {
        guard let bytes = invocation.stdin else { return }
        let handle = stdinPipe.fileHandleForWriting

        DispatchQueue.global(qos: .userInitiated).async {
            // EPIPE arrives as an ObjC exception through FileHandle, so this
            // deliberately uses the throwing API and swallows the failure: a
            // child that exits before reading its input is a normal outcome.
            try? handle.write(contentsOf: Data(bytes))
            try? handle.close()
        }
    }

    // MARK: Termination

    private func scheduleTimeout() {
        let seconds =
            Double(invocation.timeout.components.seconds)
            + Double(invocation.timeout.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.kill(because: .timedOut)
        }
    }

    /// SIGTERM now, SIGKILL shortly after if it is still alive.
    func kill(because reason: ProcessTermination) {
        let shouldSignal: Bool = lock.withLock { state in
            guard state.didLaunch, !state.didTerminate, state.killReason == nil else {
                return false
            }
            state.killReason = reason
            return true
        }
        guard shouldSignal else { return }

        let pid = process.processIdentifier
        if pid > 0 {
            Foundation.kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let stillRunning = self.lock.withLock { !$0.didTerminate }
                if stillRunning, pid > 0 { Foundation.kill(pid, SIGKILL) }
            }
        }
    }

    /// Resumes the continuation exactly once, and only when both pipes have hit
    /// EOF *and* the process has terminated.
    private func finishIfReady() {
        let result: ProcessResult? = lock.withLock { state in
            guard state.stdoutDone, state.stderrDone, state.didTerminate else { return nil }
            guard !state.didResume else { return nil }
            state.didResume = true

            let termination: ProcessTermination =
                state.killReason
                ?? state.uncaughtSignal.map { ProcessTermination.signalled($0) }
                ?? .exited(state.exitCode)

            return ProcessResult(
                termination: termination,
                stdout: state.stdout,
                stderr: state.stderr,
                duration: .zero,
                stdoutTruncated: state.stdoutTruncated,
                stderrTruncated: state.stderrTruncated
            )
        }

        guard var result, let continuation else { return }
        result.duration = .milliseconds((ContinuousClock.now - start).milliseconds)
        self.continuation = nil
        continuation.resume(returning: result)
    }
}

nonisolated extension Duration {
    fileprivate var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
