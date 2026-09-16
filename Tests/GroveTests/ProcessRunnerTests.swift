import Foundation
import Testing

@testable import Grove

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    private func invocation(_ path: String, _ args: String...) -> ProcessInvocation {
        ProcessInvocation(executable: URL(filePath: path), arguments: args)
    }

    // MARK: Basics

    @Test("captures stdout and a zero exit")
    func capturesStdout() async throws {
        let result = try await ProcessRunner.run(invocation("/bin/echo", "merhaba"))

        #expect(result.didSucceed)
        #expect(result.termination == .exited(0))
        #expect(String(decoding: result.stdout, as: UTF8.self) == "merhaba\n")
        #expect(result.stderr.isEmpty)
        #expect(!result.stdoutTruncated)
    }

    @Test("reports a non-zero exit without throwing")
    func nonZeroExit() async throws {
        let result = try await ProcessRunner.run(invocation("/bin/sh", "-c", "exit 3"))

        #expect(!result.didSucceed)
        #expect(result.termination == .exited(3))
        #expect(result.exitCode == 3)
    }

    @Test("captures stderr separately from stdout")
    func capturesStderr() async throws {
        let result = try await ProcessRunner.run(
            invocation("/bin/sh", "-c", "echo out; echo err >&2")
        )

        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(result.stderrText == "err\n")
    }

    @Test("throws rather than hanging when the executable does not exist")
    func launchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(invocation("/nonexistent/binary"))
        }
    }

    // MARK: The deadlock cases — the reason this type exists

    @Test("reads 50 MB of stdout without deadlocking", .timeLimit(.minutes(1)))
    func largeStdout() async throws {
        let bytes = 50 << 20
        let result = try await ProcessRunner.run(
            invocation("/usr/bin/head", "-c", "\(bytes)", "/dev/zero")
        )

        #expect(result.didSucceed)
        #expect(result.stdout.count == bytes)
        #expect(!result.stdoutTruncated)
    }

    /// The classic failure: the child fills the stderr pipe buffer while the
    /// parent is still draining stdout, and both sides block forever. Writing
    /// stderr *first* makes a sequential drainer hang deterministically.
    @Test("reads large stdout and stderr concurrently", .timeLimit(.minutes(1)))
    func largeBothStreams() async throws {
        let half = 20 << 20
        let result = try await ProcessRunner.run(
            invocation(
                "/bin/sh", "-c",
                "head -c \(half) /dev/zero >&2; head -c \(half) /dev/zero"
            )
        )

        #expect(result.didSucceed)
        #expect(result.stdout.count == half)
        #expect(result.stderr.count == half)
    }

    @Test("does not lose output buffered at the moment the process exits")
    func noTailLoss() async throws {
        // A fast-exiting process that writes right before terminating is where a
        // runner that resumes on terminationHandler alone drops the tail.
        for _ in 0..<20 {
            let result = try await ProcessRunner.run(
                invocation("/bin/sh", "-c", "printf 'x%.0s' $(seq 1 10000)")
            )
            #expect(result.stdout.count == 10_000)
        }
    }

    // MARK: stdin

    @Test("writes stdin and closes it so the child can finish")
    func writesStdin() async throws {
        var inv = invocation("/bin/cat")
        inv.stdin = Array("commit message body".utf8)

        let result = try await ProcessRunner.run(inv)

        #expect(result.didSucceed)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "commit message body")
    }

    @Test("survives a child that exits without reading stdin (EPIPE)")
    func stdinEPIPE() async throws {
        var inv = invocation("/bin/sh", "-c", "exit 0")
        inv.stdin = [UInt8](repeating: 0x41, count: 1 << 20)

        let result = try await ProcessRunner.run(inv)
        #expect(result.termination == .exited(0))
    }

    // MARK: Timeout, cancellation, limits

    @Test("kills a process that outruns its timeout", .timeLimit(.minutes(1)))
    func timeout() async throws {
        var inv = invocation("/bin/sleep", "30")
        inv.timeout = .seconds(1)

        let result = try await ProcessRunner.run(inv)

        #expect(result.termination == .timedOut)
        #expect(!result.didSucceed)
    }

    @Test("kills a process when its task is cancelled", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        let marker = "grove-cancel-\(UUID().uuidString)"

        let task = Task {
            try await ProcessRunner.run(invocation("/bin/sh", "-c", "sleep 30 # \(marker)"))
        }

        // Give it time to actually spawn before cancelling.
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()

        let result = try await task.value
        #expect(result.termination == .cancelled)

        // And nothing is left behind.
        try await Task.sleep(for: .milliseconds(300))
        #expect(!Self.processExists(matching: marker))
    }

    @Test("truncates and kills when output passes the limit", .timeLimit(.minutes(1)))
    func outputLimit() async throws {
        var inv = invocation("/usr/bin/head", "-c", "\(50 << 20)", "/dev/zero")
        inv.outputByteLimit = 1 << 20

        let result = try await ProcessRunner.run(inv)

        #expect(result.stdoutTruncated)
        #expect(result.stdout.count <= 1 << 20)
        #expect(result.termination == .outputLimitExceeded)
    }

    // MARK: Concurrency

    @Test("runs many processes concurrently without interleaving their output")
    func concurrentRuns() async throws {
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for i in 0..<24 {
                group.addTask {
                    let r = try await ProcessRunner.run(
                        ProcessInvocation(
                            executable: URL(filePath: "/bin/echo"),
                            arguments: ["value-\(i)"]
                        )
                    )
                    return (i, String(decoding: r.stdout, as: UTF8.self))
                }
            }
            var out: [Int: String] = [:]
            for try await (i, text) in group { out[i] = text }
            return out
        }

        #expect(results.count == 24)
        for i in 0..<24 {
            #expect(results[i] == "value-\(i)\n")
        }
    }

    // MARK: Helper

    private static func processExists(matching marker: String) -> Bool {
        let probe = Process()
        probe.executableURL = URL(filePath: "/usr/bin/pgrep")
        probe.arguments = ["-f", marker]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        try? probe.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        return !data.isEmpty
    }
}
