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
        var tempScript: URL?
        defer {
            if let tempScript {
                try? FileManager.default.removeItem(at: tempScript)
            }
        }

        let launch = try resolveLaunch(language: language, code: code, tempScript: &tempScript)
        let process = Process()
        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
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

    private struct Launch {
        var executableURL: URL
        var arguments: [String]
    }

    private func resolveLaunch(language: String, code: String, tempScript: inout URL?) throws -> Launch {
        if ShellInvocationParser.isShell(language) {
            if !code.contains("\n"), let invocation = ShellInvocationParser.parse(line: code) {
                return Launch(executableURL: invocation.executableURL, arguments: invocation.arguments)
            }

            let scriptURL = try writeTempShellScript(language: language, code: code)
            tempScript = scriptURL
            return Launch(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                arguments: [scriptURL.path]
            )
        }

        return Launch(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [language, "-c", code]
        )
    }

    private func writeTempShellScript(language: String, code: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("showless-\(UUID().uuidString).sh")

        let contents: String
        if code.contains("\n") {
            contents = code.hasSuffix("\n") ? code : code + "\n"
        } else {
            let escaped = code.replacingOccurrences(of: "'", with: "'\\''")
            contents = "#!/usr/bin/env \(language)\nset -euo pipefail\neval '\(escaped)'\n"
        }

        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
