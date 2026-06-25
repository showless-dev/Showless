import Foundation
import Testing
@testable import ShowlessCore

@Suite struct ShellInvocationTests {
    @Test func tokenizeRespectsQuotes() {
        let tokens = ShellInvocationParser.tokenize(#"echo 'hello world' "foo bar""#)
        #expect(tokens == ["echo", "hello world", "foo bar"])
    }

    @Test func parseMergesExecutablePathWithSpaces() throws {
        let directory = try temporaryDirectory()
        let script = directory.appendingPathComponent("Peer Islands")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        let executable = script.appendingPathComponent("tool.sh")
        try "#!/bin/bash\necho hi\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let line = "\(executable.path) --flag value"
        let invocation = ShellInvocationParser.parse(line: line)
        #expect(invocation?.executableURL.path == "/bin/bash")
        #expect(invocation?.arguments == [executable.path, "--flag", "value"])
    }

    @Test func runnerExecutesPathWithSpaces() throws {
        let directory = try temporaryDirectory()
        let script = directory.appendingPathComponent("Peer Islands")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        let executable = script.appendingPathComponent("tool.sh")
        try "#!/bin/bash\necho spaced-ok\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try ProcessRunner().run(language: "bash", code: "\(executable.path)")
        #expect(result.output == "spaced-ok\n")
        #expect(result.exitCode == 0)
    }

    @Test func runnerEvaluatesRedirectionWithSpaces() throws {
        let directory = try temporaryDirectory()
        let script = directory.appendingPathComponent("Peer Islands")
        try FileManager.default.createDirectory(at: script, withIntermediateDirectories: true)
        let executable = script.appendingPathComponent("tool.sh")
        try "#!/bin/bash\necho redirected\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let output = directory.appendingPathComponent("out.txt")
        let result = try ProcessRunner().run(
            language: "bash",
            code: "\(executable.path) > \(output.path)",
            workdir: directory.path
        )
        #expect(result.exitCode == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == "redirected\n")
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("showless-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
