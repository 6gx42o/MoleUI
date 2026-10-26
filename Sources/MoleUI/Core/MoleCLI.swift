import Foundation

/// Bridge to the `mo` binary. Three jobs: find it, run it, stream it.
final class MoleCLI: @unchecked Sendable {
    static let shared = MoleCLI()

    enum CLIError: LocalizedError {
        case notInstalled
        case streamEnded
        case failed(command: String, exitCode: Int32, stderr: String)
        case decode(command: String, underlying: Error, sample: String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "The mo binary could not be found."
            case .streamEnded:
                return "The status collector stopped."
            case let .failed(command, code, stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return "mo \(command) exited with \(code)" + (detail.isEmpty ? "" : ":\n\(detail)")
            case let .decode(command, underlying, sample):
                return "Could not read the output of mo \(command): \(underlying.localizedDescription)\n\(sample)"
            }
        }
    }

    struct Output {
        var stdout: String
        var stderr: String
        var exitCode: Int32
        var stdoutData: Data
    }

    /// Native Apple-silicon Homebrew (/opt/homebrew) first, then the Intel one
    /// under /usr/local, which this Mac ran under Rosetta until it was migrated.
    /// A GUI app inherits launchd's PATH, not the shell's, which is why this
    /// cannot just be `which mo`.
    private static let candidatePaths = [
        "/opt/homebrew/bin/mo",
        "/usr/local/bin/mo",
        NSHomeDirectory() + "/.local/bin/mo",
        "/usr/bin/mo",
    ]

    private(set) lazy var binaryPath: String? = Self.locate()

    var isInstalled: Bool { binaryPath != nil }

    private static func locate() -> String? {
        let fm = FileManager.default
        for path in candidatePaths where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask a login shell, which does source the user's profile.
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "command -v mo"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let found = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.isEmpty, fm.isExecutableFile(atPath: found) { return found }
        } catch {
            return nil
        }
        return nil
    }

    /// Mole honours NO_COLOR (tests/no_color.bats), which suppresses colour —
    /// though not cursor control like `\e[2J`, so parsers still strip escapes.
    ///
    /// `input` feeds stdin. Two different contracts live here:
    ///   * nil → /dev/null, which is how `mo clean` takes its non-interactive
    ///     path rather than blocking on a TTY prompt that will never come.
    ///   * a string → answers a prompt `mo uninstall` asks even under
    ///     `--dry-run`, where EOF means "abort" and the preview never prints.
    /// Either way the GUI's own confirm sheet is the real gate.
    private func makeProcess(_ args: [String], input: String?,
                             env extra: [String: String],
                             executable: String? = nil) throws -> Process {
        guard let path = executable ?? binaryPath else { throw CLIError.notInstalled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var env = Foundation.ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        // Callers override last: the environment is inherited from whatever
        // launched the app, and some of Mole's switches are env-driven, so a
        // promise the UI makes has to be pinned rather than assumed.
        for (key, value) in extra { env[key] = value }
        process.environment = env

        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            let data = Data(input.utf8)
            // Written off the calling thread: the answers are a few bytes and
            // fit the pipe buffer, but writing must not block process start.
            DispatchQueue.global(qos: .userInitiated).async {
                try? stdin.fileHandleForWriting.write(contentsOf: data)
                try? stdin.fileHandleForWriting.close()
            }
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        return process
    }

    /// Removes ANSI escape sequences. NO_COLOR stops colour but not cursor
    /// control — `mo uninstall` clears the screen with `\e[2J\e[H` mid-output.
    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]",
                                  with: "",
                                  options: .regularExpression)
    }

    /// Runs to completion. Both pipes are drained concurrently — draining only
    /// stdout deadlocks as soon as stderr's 64KB buffer fills, and `mo analyze`
    /// produces megabytes.
    @discardableResult
    func run(_ args: [String], input: String? = nil,
             env: [String: String] = [:]) async throws -> Output {
        try await execute(try makeProcess(args, input: input, env: env))
    }

    /// Same plumbing — concurrent pipe draining, cancellation that kills the
    /// child — for the system tools the newer panes call (`networksetup`,
    /// `brew`, `sqlite3`, `mdfind`…). Absolute paths only: a GUI app inherits
    /// launchd's PATH, so a bare name would resolve differently from a shell.
    @discardableResult
    func tool(_ executable: String, _ args: [String], input: String? = nil,
              env: [String: String] = [:]) async throws -> Output {
        try await execute(try makeProcess(args, input: input, env: env,
                                          executable: executable))
    }

    private func execute(_ process: Process) async throws -> Output {
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // The readability handlers run on an arbitrary queue, so the buffers
        // live behind a lock in a reference box rather than being captured vars.
        let sink = OutputSink()

        // Cancelling the Task must actually kill the child: `mo analyze` walks
        // the whole disk and will happily keep going for minutes after the view
        // that asked for it is gone.
        // `isRunning` is false both before launch and after exit, so guarding on
        // it alone made cancellation a no-op when the task was cancelled while
        // still suspended before `run()` — leaving a full-disk `mo analyze`
        // orphaned. The sink records the intent so launch can honour it.
        return try await withTaskCancellationHandler {
            try await launch(process, sink: sink)
        } onCancel: {
            sink.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    private func launch(_ process: Process, sink: OutputSink) async throws -> Output {
        guard let outPipe = process.standardOutput as? Pipe,
              let errPipe = process.standardError as? Pipe else {
            throw CLIError.notInstalled
        }
        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading

        return try await withCheckedThrowingContinuation { continuation in
            // Completion is when both pipes have reported EOF *and* the process
            // has exited — tracked in the sink, which resumes exactly once.
            //
            // The previous version called readDataToEndOfFile() inside the
            // termination handler. That raced the readability handlers still
            // running on another queue (reproduced: interleaved appends
            // corrupting output); reading only through the handlers fixes it.
            //
            // It does NOT fix the other half, and an earlier version of this
            // comment wrongly claimed it did. EOF arrives only once every
            // descendant holding the write end has closed it, so a helper `mo`
            // spawned that inherits the pipe and outlives it delays the resume
            // exactly as readDataToEndOfFile() did, and one that never exits
            // strands the continuation — there is no deadline here.
            //
            // Left as is because mole 1.50.0 has no such helper: its disowned
            // jobs redirect both descriptors to /dev/null, and its parallel
            // scans are waited for and bounded by run_with_timeout. Revisit with
            // a post-exit drain deadline if that stops holding.
            sink.onComplete = { out, err, status in
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                continuation.resume(returning: Output(
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self),
                    exitCode: status,
                    stdoutData: out
                ))
            }

            outHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { sink.markStdoutEOF() } else { sink.appendStdout(chunk) }
            }
            errHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { sink.markStderrEOF() } else { sink.appendStderr(chunk) }
            }

            process.terminationHandler = { proc in
                sink.markExited(status: proc.terminationStatus)
            }

            do {
                try process.run()
                // Cancelled while suspended, before the process existed.
                if sink.isCancelled { process.terminate() }
            } catch {
                // Without this the pipes' dispatch sources and the retained
                // closures leak on every failed launch — e.g. once Homebrew
                // upgrades `mo` out from under the cached path.
                outHandle.readabilityHandler = nil
                errHandle.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// `mo status` and `mo uninstall --list` switch to JSON on their own when
    /// stdout is not a TTY (a Pipe never is), but the flags are passed
    /// explicitly so the intent survives a future change upstream.
    func runJSON<T: Decodable>(_ type: T.Type, _ args: [String]) async throws -> T {
        let output = try await run(args)
        guard !output.stdoutData.isEmpty else {
            throw CLIError.failed(command: args.joined(separator: " "),
                                  exitCode: output.exitCode,
                                  stderr: output.stderr)
        }
        return try MoleCLI.decodeJSON(T.self, output.stdout,
                                      command: args.joined(separator: " "))
    }

    /// Split out of `runJSON` so a pane restoring cached text gets the identical
    /// diagnosis. A bare DecodingError says only "the data is missing"; this
    /// names the command and shows the head of what actually came back.
    static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String,
                                         command: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: Data(text.utf8))
        } catch {
            throw CLIError.decode(command: command, underlying: error,
                                  sample: String(text.prefix(400)))
        }
    }

    /// Lock-guarded accumulator for the two pipes, and the completion latch.
    ///
    /// Completion needs three things to have happened — stdout EOF, stderr EOF,
    /// and process exit — arriving on different queues in any order. Tracking
    /// them here keeps the resume single-shot; resuming a continuation twice is
    /// a crash, and never resuming it hangs the caller forever.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data()
        private var err = Data()
        private var outEOF = false
        private var errEOF = false
        private var exitStatus: Int32?
        private var finished = false
        private var cancelled = false

        /// Set before the handlers are installed; called at most once.
        var onComplete: ((Data, Data, Int32) -> Void)?

        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        func appendStdout(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); out.append(data); lock.unlock()
        }

        func appendStderr(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); err.append(data); lock.unlock()
        }

        func markStdoutEOF() { lock.lock(); outEOF = true; lock.unlock(); finishIfReady() }
        func markStderrEOF() { lock.lock(); errEOF = true; lock.unlock(); finishIfReady() }

        func markExited(status: Int32) {
            lock.lock(); exitStatus = status; lock.unlock(); finishIfReady()
        }

        private func finishIfReady() {
            lock.lock()
            guard !finished, outEOF, errEOF, let status = exitStatus else {
                lock.unlock(); return
            }
            finished = true
            let (o, e, handler) = (out, err, onComplete)
            onComplete = nil
            lock.unlock()
            handler?(o, e, status)
        }
    }

    // MARK: - NDJSON streaming

    /// A running `mo status --watch`. Holding the process lets the view kill it
    /// on disappear rather than leaking a collector for the app's lifetime.
    final class Stream: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let handle: FileHandle
        private var stopped = false

        init(process: Process, handle: FileHandle) {
            self.process = process
            self.handle = handle
        }

        /// Clearing the readability handler is the part that matters, and it was
        /// missing. A dispatch read source stays permanently signalled once the
        /// far end hits EOF, so a handler left installed is re-entered as fast
        /// as the queue can dispatch — measured at ~1.9 million empty callbacks
        /// in two seconds, a pegged core. Terminating the process is not enough;
        /// terminating it is precisely what causes the EOF.
        /// Returns true only for the call that actually performed the teardown.
        /// EOF and process exit both signal the end and arrive independently, so
        /// callers use this to notify exactly once — reporting on both spawned
        /// two replacement collectors for every one that died.
        @discardableResult
        func stop() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return false }
            stopped = true
            handle.readabilityHandler = nil
            if process.isRunning { process.terminate() }
            return true
        }

        deinit { stop() }
    }

    /// Splits an incoming byte stream into complete newline-terminated lines.
    /// A snapshot is ~8KB and reliably straddles read boundaries, so a partial
    /// tail is held back until the rest of it arrives.
    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        func take(_ chunk: Data) -> [Data] {
            guard !chunk.isEmpty else { return [] }
            lock.lock(); defer { lock.unlock() }

            pending.append(chunk)
            var lines: [Data] = []
            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                if !line.isEmpty { lines.append(Data(line)) }
                pending = Data(pending[pending.index(after: newline)...])
            }
            return lines
        }
    }

    /// Streams one decoded snapshot per NDJSON line.
    func streamStatus(intervalSeconds: Int = 2,
                      onSnapshot: @escaping @Sendable (StatusSnapshot) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) -> Stream? {
        let args = ["status", "--watch", "--interval", "\(intervalSeconds)s"]
        let process: Process
        do {
            process = try makeProcess(args, input: nil, env: [:])
        } catch {
            onError(error)
            return nil
        }

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let buffer = LineBuffer()
        let decoder = JSONDecoder()
        let stream = Stream(process: process, handle: outPipe.fileHandleForReading)

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // Empty data means EOF. Tear down here too, so a collector that dies
            // on its own — crash, pkill, an upstream bug — stops the spin
            // immediately instead of waiting for someone to call stop().
            guard !chunk.isEmpty else {
                if stream.stop() { onError(CLIError.streamEnded) }
                return
            }
            for line in buffer.take(chunk) {
                if let snapshot = try? decoder.decode(StatusSnapshot.self, from: line) {
                    onSnapshot(snapshot)
                }
            }
        }

        // Nothing detected the child dying, so the UI kept showing a green
        // "live" dot over a frozen snapshot. Report it instead.
        process.terminationHandler = { _ in
            if stream.stop() { onError(CLIError.streamEnded) }
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            onError(error)
            return nil
        }
        return stream
    }

    // MARK: - Typed commands

    func status() async throws -> StatusSnapshot {
        try await runJSON(StatusSnapshot.self, ["status", "--json"])
    }

    /// `analyze` and `uninstall --list` deliberately have no wrapper here: both
    /// panes cache the raw JSON they fetched, so they call `run` and hand the
    /// text to `decodeJSON` themselves.

    func history() async throws -> HistoryLog {
        try await runJSON(HistoryLog.self, ["history", "--json"])
    }
}
