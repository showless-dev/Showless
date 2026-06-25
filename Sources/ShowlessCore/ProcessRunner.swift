import Foundation

public struct ExecutionResult: Equatable, Sendable {
    public var output: String
    public var exitCode: Int32
    public var timedOut: Bool

    public init(output: String, exitCode: Int32, timedOut: Bool = false) {
        self.output = output
        self.exitCode = exitCode
        self.timedOut = timedOut
    }
}

public struct ProcessRunner {
    public init() {}

    public func run(language: String, code: String, workdir: String? = nil, timeout: TimeInterval? = nil) throws -> ExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [language, "-c", code]
        if let workdir, !workdir.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: workdir)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("showless-\(UUID().uuidString).output")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: tempURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: tempURL)
        }

        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
        } catch {
            throw ShowlessError.execution("executing \(language): \(error.localizedDescription)")
        }

        var timedOut = false
        if let timeout, timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning {
                timedOut = true
                process.terminate()
                process.waitUntilExit()
            }
        } else {
            process.waitUntilExit()
        }

        try outputHandle.synchronize()
        try outputHandle.close()
        let data = try Data(contentsOf: tempURL)
        var output = String(decoding: data, as: UTF8.self)
        if timedOut {
            output += "showless: command timed out after \(formatTimeout(timeout ?? 0))\n"
        }
        return ExecutionResult(output: output, exitCode: timedOut ? 124 : process.terminationStatus, timedOut: timedOut)
    }

    private func formatTimeout(_ timeout: TimeInterval) -> String {
        if timeout.rounded() == timeout {
            return "\(Int(timeout))s"
        }
        return "\(timeout)s"
    }
}
