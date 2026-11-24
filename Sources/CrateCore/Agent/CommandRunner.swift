import Foundation

/// Runs a child process and collects its output, with a timeout.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        /// stdout and stderr interleaved, as a terminal would show them.
        public var output: String
        public var timedOut: Bool
        public var truncated: Bool
    }

    public static func run(
        executable: String, arguments: [String], workingDirectory: String? = nil, timeout: TimeInterval,
        outputLimit: Int = 1_000_000
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let collector = Collector(limit: outputLimit)
            let reader = pipe.fileHandleForReading
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    collector.reachedEnd()
                } else {
                    collector.append(chunk)
                }
            }
            process.terminationHandler = { process in
                DispatchQueue.global(qos: .userInitiated).async {
                    // Normally end-of-file follows at once. A background child the command
                    // left running can hold the pipe open, so do not wait for it for long.
                    collector.waitForEnd(seconds: 1)
                    reader.readabilityHandler = nil
                    continuation.resume(returning: Result(
                        exitCode: process.terminationStatus, output: collector.text,
                        timedOut: collector.timedOut, truncated: collector.truncated))
                }
            }

            do {
                try process.run()
            } catch {
                reader.readabilityHandler = nil
                process.terminationHandler = nil
                continuation.resume(throwing: ToolError("Could not start \(executable): \(error.localizedDescription)"))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                collector.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
        }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let end = DispatchSemaphore(value: 0)
        private let limit: Int
        private var data = Data()
        private var wasTruncated = false
        private var didTimeOut = false

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            let room = limit - data.count
            if chunk.count > room { wasTruncated = true }
            if room > 0 { data.append(chunk.prefix(room)) }
        }

        func reachedEnd() { end.signal() }
        func waitForEnd(seconds: Double) { _ = end.wait(timeout: .now() + seconds) }

        func markTimedOut() {
            lock.lock()
            didTimeOut = true
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return wasTruncated
        }
        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didTimeOut
        }
    }
}

/// A shell command the agent wants to run. Nothing runs until the user approves it.
public struct CommandRequest: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var command: String
    public var workingDirectory: String
    /// The agent's stated reason, shown to the user next to the command.
    public var reason: String
}

public enum CommandTool {
    public static let timeout: TimeInterval = 60
    static let outputCharacters = 12_000

    /// - Parameter approve: asks the user. Returning false means the command is not run.
    public static func register(
        into registry: ToolRegistry, approve: @escaping @Sendable (CommandRequest) async -> Bool
    ) {
        registry.register(AgentTool(
            name: "run_command",
            description: """
                Run a shell command on the user's Mac (zsh), for example ffprobe, ffmpeg, fpcalc or a script. The \
                user is shown the exact command and your reason, and it runs only if they approve, so give a clear \
                reason and prefer one command per call. Stops after \(Int(timeout)) seconds. Prefer the library, \
                crate and file-finding tools when they can do the job.
                """,
            properties: [
                "command": Schema.string("The command line, exactly as it should run."),
                "reason": Schema.string("One sentence for the user on why this command is needed."),
                "working_directory": Schema.string("Folder to run in. Default: the user's home folder."),
            ],
            required: ["command", "reason"]
        ) { args in
            let command = try args.requiredString("command")
            let directory = ((args.optionalString("working_directory") ?? "~") as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ToolError("The working directory \(directory) does not exist.")
            }
            let request = CommandRequest(
                command: command, workingDirectory: directory, reason: try args.requiredString("reason"))
            guard await approve(request) else {
                throw ToolError("The user declined to run this command. Do not retry it; ask what they would prefer.")
            }
            // A login shell, so Homebrew and nvm tools are on the PATH as they are in Terminal.
            let result = try await ProcessRunner.run(
                executable: "/bin/zsh", arguments: ["-lc", command], workingDirectory: directory, timeout: timeout)
            var output = result.output
            var clipped = result.truncated
            if output.count > outputCharacters {
                output = String(output.prefix(outputCharacters / 2)) + "\n…\n" + String(output.suffix(outputCharacters / 2))
                clipped = true
            }
            var response: [String: JSON] = ["exit_code": .number(Double(result.exitCode)), "output": .string(output)]
            if result.timedOut { response["timed_out"] = .string("Stopped after \(Int(timeout)) seconds.") }
            if clipped { response["output_truncated"] = true }
            return .object(response)
        })
    }
}
