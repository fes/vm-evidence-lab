import CryptoKit
import Foundation

enum ObserverError: Error, CustomStringConvertible {
    case usage(String)
    case permissionDenied(String)
    case notFound(String)
    case ambiguous(String)
    case invalid(String)
    case unsafe(String)
    case capture(String)
    case io(String)
    case testFailure(String)

    var description: String {
        switch self {
        case .usage(let message), .permissionDenied(let message),
             .notFound(let message), .ambiguous(let message),
             .invalid(let message), .unsafe(let message),
             .capture(let message), .io(let message),
             .testFailure(let message):
            return message
        }
    }

    var code: String {
        switch self {
        case .usage: return "usage"
        case .permissionDenied: return "screen-recording-denied"
        case .notFound: return "not-found"
        case .ambiguous: return "ambiguous-selection"
        case .invalid: return "invalid-argument"
        case .unsafe: return "unsafe-window-or-path"
        case .capture: return "capture-failed"
        case .io: return "io-failed"
        case .testFailure: return "self-test-failed"
        }
    }
}

func jsonBytes(_ value: Any) throws -> Data {
    guard JSONSerialization.isValidJSONObject(value) else {
        throw ObserverError.invalid("value cannot be encoded as JSON")
    }
    return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
}

func writeJSON(_ value: Any, to url: URL) throws {
    var data = try jsonBytes(value)
    data.append(0x0a)
    try data.write(to: url, options: .atomic)
}

func emitJSON(_ value: Any) throws {
    let data = try jsonBytes(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0a]))
}

func emitFailure(_ error: Error) {
    let observerError = error as? ObserverError
    let message = observerError?.description ?? error.localizedDescription
    let object: [String: Any] = [
        "ok": false,
        "error": [
            "code": observerError?.code ?? "internal",
            "message": message,
        ],
    ]
    if let data = try? jsonBytes(object) {
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data([0x0a]))
    }
}

func sha256(at url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let data = try handle.read(upToCount: 1 << 20) ?? Data()
        if data.isEmpty { break }
        hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func fileSize(at url: URL) throws -> Int64 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let number = attributes[.size] as? NSNumber else {
        throw ObserverError.io("could not obtain output size: \(url.path)")
    }
    return number.int64Value
}

struct ArtifactPaths: Sendable {
    let root: URL
    let output: URL
    let markers: URL

    init(root argumentRoot: String, output argumentOutput: String) throws {
        let rootURL = URL(fileURLWithPath: argumentRoot, isDirectory: true).standardizedFileURL
        let candidate = URL(fileURLWithPath: argumentOutput, relativeTo: rootURL).standardizedFileURL
        guard !argumentOutput.hasPrefix("/") else {
            throw ObserverError.unsafe("output must be relative to artifact root")
        }
        let components = argumentOutput.split(separator: "/", omittingEmptySubsequences: false)
        if argumentOutput.isEmpty || components.contains("..") || components.contains(".") {
            throw ObserverError.unsafe("output must be a non-empty path below artifact root")
        }
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true, attributes: nil
        )
        let realRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let parent = candidate.deletingLastPathComponent()
        guard parent.path == realRoot.path || parent.path.hasPrefix(realRoot.path + "/") else {
            throw ObserverError.unsafe("output escapes artifact root")
        }
        var inspectedParent = realRoot
        for component in candidate
            .deletingLastPathComponent().path
            .dropFirst(realRoot.path.count).split(separator: "/")
        {
            inspectedParent.appendPathComponent(String(component))
            let values = try? inspectedParent.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw ObserverError.unsafe("output parent contains a symbolic link")
            }
            if !FileManager.default.fileExists(atPath: inspectedParent.path) {
                try FileManager.default.createDirectory(
                    at: inspectedParent, withIntermediateDirectories: false, attributes: nil
                )
            }
            let resolved = inspectedParent.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == realRoot.path || resolved.path.hasPrefix(realRoot.path + "/") else {
                throw ObserverError.unsafe("output parent resolves outside artifact root")
            }
        }
        let realParent = parent.resolvingSymlinksInPath().standardizedFileURL
        guard realParent.path == realRoot.path || realParent.path.hasPrefix(realRoot.path + "/") else {
            throw ObserverError.unsafe("output parent resolves outside artifact root")
        }
        let resolvedOutput = realParent.appendingPathComponent(candidate.lastPathComponent)
        let values = try? resolvedOutput.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true {
            throw ObserverError.unsafe("output path is a symbolic link")
        }
        root = realRoot
        output = resolvedOutput
        markers = URL(fileURLWithPath: resolvedOutput.path + ".markers.json")
    }

    func prepare() throws {
        for item in [output, markers] {
            if FileManager.default.fileExists(atPath: item.path) {
                throw ObserverError.io("refusing to overwrite existing artifact: \(item.path)")
            }
        }
    }

    func removePartial() {
        try? FileManager.default.removeItem(at: output)
        try? FileManager.default.removeItem(at: markers)
    }
}
