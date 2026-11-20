import Foundation

enum SelfTest {
    static func run() throws {
        var config: SelectionConfig {
            SelectionConfig(
                owner: "prl_client_app", title: "Evidence VM", pid: 42, windowID: 100
            )
        }
        let plain = WindowIdentity(
            owner: "prl_client_app", pid: 42, title: "Evidence VM", windowID: 100,
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            onScreen: true, layer: 0, obscuredBy: []
        )
        try config.validated()
        guard try WindowCatalog.select(config, from: [plain]) == plain else {
            throw ObserverError.testFailure("exact selection failed")
        }
        do {
            _ = try WindowCatalog.select(config, from: [plain, plain])
            throw ObserverError.testFailure("ambiguous selection was accepted")
        } catch ObserverError.ambiguous {}
        var hidden = plain
        hidden.obscuredBy = [99]
        do {
            _ = try WindowCatalog.select(config, from: [hidden])
            throw ObserverError.testFailure("occluded selection was accepted")
        } catch ObserverError.unsafe {}

        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".self-test-artifacts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = try ArtifactPaths(root: root.path, output: "evidence/output.png")
        guard inside.output.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw ObserverError.testFailure("artifact root containment failed")
        }
        do {
            _ = try ArtifactPaths(root: root.path, output: "../escaped.png")
            throw ObserverError.testFailure("escaping output was accepted")
        } catch ObserverError.unsafe {}
        let outside = root.deletingLastPathComponent().appendingPathComponent(".self-test-outside")
        let link = root.appendingPathComponent("linked-outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try ArtifactPaths(root: root.path, output: "linked-outside/output.png")
            throw ObserverError.testFailure("symlink-escaping output was accepted")
        } catch ObserverError.unsafe {}

        let arguments = [
            "vm-host-observer", "record", "--config", "target.json",
            "--artifact-root", root.path, "--output", "bounded.mov",
            "--fps", "60",
        ]
        do {
            _ = try CLI.parse(arguments)
            throw ObserverError.testFailure("frame rate above 30 was accepted")
        } catch ObserverError.invalid {}
        emitSelfTestResult()
    }

    private static func emitSelfTestResult() {
        let value: [String: Any] = [
            "ok": true,
            "selfTest": true,
            "screenCapturePerformed": false,
            "tccRequired": false,
            "checks": [
                "exact-selection", "ambiguity", "occlusion", "path-containment",
                "symlink-containment", "fps-limit",
            ],
        ]
        if let data = try? jsonBytes(value) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }
}
