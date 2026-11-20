import Foundation

struct SessionDocument: Decodable {
    let schema_version: Int
    let session_id: String
    let platform: String
    let run_id: String
    let target: SessionTarget
    let grants: [String]
    let limits: SessionLimits
}

struct SessionTarget: Decodable {
    let pid: Int
    let window_index: Int?
}

struct SessionLimits: Decodable {
    let maximum_commands: Int
    let command_timeout_ms: Int
    let maximum_artifact_bytes: Int
    let maximum_video_seconds: Int
}

struct CommandDocument: Decodable {
    let schema_version: Int
    let session_id: String
    let sequence: Int
    let operation: String
    let key: KeyRequest?
    let text: TextRequest?
    let point: PointRequest?
    let destination: PointRequest?
    let button: String?
    let duration_ms: Int?
    let scroll: ScrollRequest?
    let wait: WaitRequest?
    let artifact: ArtifactRequest?
    let clipboard: ClipboardRequest?
    let video: VideoRequest?
}

struct KeyRequest: Decodable {
    let name: String
    let character: String?
    let modifiers: [String]?
    let phase: String?
}

struct TextRequest: Decodable {
    let value: String
    let sensitive: Bool?
}

struct PointRequest: Decodable {
    let x: Double
    let y: Double
    let coordinate_space: String?
}

struct ScrollRequest: Decodable {
    let delta_x: Double
    let delta_y: Double
    let unit: String
}

struct WaitRequest: Decodable {
    let condition: String
    let timeout_ms: Int
    let stable_for_ms: Int?
}

struct ArtifactRequest: Decodable {
    let name: String
    let scope: String?
}

struct ClipboardRequest: Decodable {
    let value: String
    let verify: Bool?
}

struct VideoRequest: Decodable {
    let artifact_name: String
    let maximum_seconds: Int
    let frames_per_second: Int?
}

struct TargetResult: Encodable {
    var pid: Int
    var window_found: Bool
    var foreground: Bool
    var visible: Bool
    var window_id: String?
    var geometry: GeometryResult?
}

struct GeometryResult: Encodable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var scale_factor: Double
}

struct TCCResult: Encodable {
    var accessibility: Bool
    var screen_recording: Bool
}

struct DiagnosticsResult: Encodable {
    var driver = "macos-gui-driver/1"
    var platform = "macos"
    var target: TargetResult
    var message: String
    var native_error: String? = nil
    var host_guest_clock_skew_ms: Double? = nil
    var tcc: TCCResult?
    var metrics: [String: JSONPrimitive]? = nil
}

struct ArtifactResult: Encodable {
    let name: String
    let path: String
    let size: Int
    let sha256: String
}

struct InteractionResult: Encodable {
    let schema_version = 1
    let session_id: String
    let sequence: Int
    let status: String
    let operation: String
    let started_at: String
    let completed_at: String
    let duration_ms: Int
    let diagnostics: DiagnosticsResult
    let observation: AnyEncodableDictionary?
    let artifacts: [ArtifactResult]
}

indirect enum JSONPrimitive: Encodable {
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

struct AnyEncodableDictionary: Encodable {
    let values: [String: JSONValue]

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: DynamicKey(stringValue: key)!)
        }
    }
}

struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

indirect enum JSONValue: Encodable {
    case null
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        if case .object(let values) = self {
            var container = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in values {
                try container.encode(value, forKey: DynamicKey(stringValue: key)!)
            }
            return
        }
        if case .array(let values) = self {
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
            return
        }
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array, .object: fatalError("handled above")
        }
    }
}

enum DriverError: Error {
    case invalid(String)
    case denied(String)
    case unsupported(String)
    case native(String)

    var status: String {
        if case .unsupported = self { return "unsupported" }
        return "fail"
    }

    var message: String {
        switch self {
        case .invalid(let value), .denied(let value),
             .unsupported(let value), .native(let value):
            return value
        }
    }
}

enum StrictJSON {
    static let sessionKeys = Set(["schema_version", "session_id", "platform", "run_id",
                                  "target", "grants", "limits"])
    static let targetKeys = Set(["pid", "window_index"])
    static let limitKeys = Set(["maximum_commands", "command_timeout_ms",
                                "maximum_artifact_bytes", "maximum_video_seconds"])
    static let commandKeys = Set(["schema_version", "session_id", "sequence", "operation",
                                  "key", "text", "point", "destination", "button",
                                  "duration_ms", "scroll", "wait", "artifact",
                                  "clipboard", "video"])

    static func checkObject(_ value: Any, keys: Set<String>, path: String) throws {
        guard let object = value as? [String: Any] else {
            throw DriverError.invalid("\(path) must be an object")
        }
        let unknown = Set(object.keys).subtracting(keys)
        if !unknown.isEmpty {
            throw DriverError.invalid("\(path) contains an unknown field")
        }
    }

    static func session(_ data: Data) throws -> SessionDocument {
        let raw = try parse(data)
        try checkObject(raw, keys: sessionKeys, path: "session")
        let object = raw as! [String: Any]
        try checkObject(object["target"] as Any, keys: targetKeys, path: "session.target")
        try checkObject(object["limits"] as Any, keys: limitKeys, path: "session.limits")
        do {
            let value = try JSONDecoder().decode(SessionDocument.self, from: data)
            try validate(value)
            return value
        } catch let error as DriverError { throw error }
        catch { throw DriverError.invalid("session does not match interaction-session-v1") }
    }

    static func command(_ data: Data) throws -> CommandDocument {
        let raw = try parse(data)
        let allowed = commandKeys
        try checkObject(raw, keys: allowed, path: "command")
        let object = raw as! [String: Any]
        if let value = object["key"] {
            try checkObject(value, keys: ["name", "character", "modifiers", "phase"], path: "command.key")
        }
        if let value = object["text"] {
            try checkObject(value, keys: ["value", "sensitive"], path: "command.text")
        }
        for field in ["point", "destination"] {
            if let value = object[field] {
                try checkObject(value, keys: ["x", "y", "coordinate_space"], path: "command.\(field)")
            }
        }
        if let value = object["scroll"] {
            try checkObject(value, keys: ["delta_x", "delta_y", "unit"], path: "command.scroll")
        }
        if let value = object["wait"] {
            try checkObject(value, keys: ["condition", "timeout_ms", "stable_for_ms"], path: "command.wait")
        }
        if let value = object["artifact"] {
            try checkObject(value, keys: ["name", "scope"], path: "command.artifact")
        }
        if let value = object["clipboard"] {
            try checkObject(value, keys: ["value", "verify"], path: "command.clipboard")
        }
        if let value = object["video"] {
            try checkObject(value, keys: ["artifact_name", "maximum_seconds", "frames_per_second"],
                            path: "command.video")
        }
        do {
            let value = try JSONDecoder().decode(CommandDocument.self, from: data)
            try validate(value)
            return value
        } catch let error as DriverError { throw error }
        catch { throw DriverError.invalid("command does not match interaction-command-v1") }
    }

    private static func parse(_ data: Data) throws -> Any {
        guard data.count <= 131_072 else { throw DriverError.invalid("JSON input exceeds 131072 bytes") }
        do {
            try DuplicateKeyChecker(data).validate()
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }
        catch { throw DriverError.invalid("malformed JSON") }
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func validate(_ value: SessionDocument) throws {
        guard value.schema_version == 1, value.platform == "macos" else {
            throw DriverError.invalid("session version or platform is unsupported")
        }
        guard matches(value.session_id, pattern: #"^[A-Za-z0-9._-]{1,128}$"#),
              matches(value.run_id, pattern: #"^[A-Za-z0-9._-]{1,128}$"#) else {
            throw DriverError.invalid("session or run identifier is invalid")
        }
        guard value.target.pid > 0,
              (value.target.window_index ?? 0) >= 0,
              (value.target.window_index ?? 0) <= 31 else {
            throw DriverError.invalid("target pid or window index is invalid")
        }
        let legalGrants = Set(["observe", "keyboard", "pointer", "wheel", "accessibility",
                               "screenshot", "video", "clipboard-sentinel", "fixture-files"])
        guard Set(value.grants).isSubset(of: legalGrants),
              Set(value.grants).count == value.grants.count else {
            throw DriverError.invalid("session grants are invalid")
        }
        guard (1...10_000).contains(value.limits.maximum_commands),
              (100...120_000).contains(value.limits.command_timeout_ms),
              (1...1_073_741_824).contains(value.limits.maximum_artifact_bytes),
              (1...300).contains(value.limits.maximum_video_seconds) else {
            throw DriverError.invalid("session limits are outside protocol bounds")
        }
    }

    private final class DuplicateKeyChecker {
        private let bytes: [UInt8]
        private var index = 0

        init(_ data: Data) { bytes = Array(data) }

        func validate() throws {
            try value()
            skipWhitespace()
            guard index == bytes.count else { throw DriverError.invalid("Malformed JSON") }
        }

        private func value() throws {
            skipWhitespace()
            guard index < bytes.count else { throw DriverError.invalid("Malformed JSON") }
            switch bytes[index] {
            case 0x7b: try object()
            case 0x5b: try array()
            case 0x22: _ = try string()
            default:
                while index < bytes.count && ![0x20, 0x09, 0x0a, 0x0d, 0x2c, 0x5d, 0x7d].contains(bytes[index]) {
                    index += 1
                }
            }
        }

        private func object() throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if take(0x7d) { return }
            while true {
                skipWhitespace()
                let key = try string()
                guard keys.insert(key).inserted else {
                    throw DriverError.invalid("JSON object contains a duplicate field")
                }
                skipWhitespace()
                guard take(0x3a) else { throw DriverError.invalid("Malformed JSON object") }
                try value()
                skipWhitespace()
                if take(0x7d) { return }
                guard take(0x2c) else { throw DriverError.invalid("Malformed JSON object") }
            }
        }

        private func array() throws {
            index += 1
            skipWhitespace()
            if take(0x5d) { return }
            while true {
                try value()
                skipWhitespace()
                if take(0x5d) { return }
                guard take(0x2c) else { throw DriverError.invalid("Malformed JSON array") }
            }
        }

        private func string() throws -> String {
            guard take(0x22) else { throw DriverError.invalid("Malformed JSON string") }
            let start = index - 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 0x5c {
                    escaped = true
                } else if byte == 0x22 {
                    let data = Data(bytes[start..<index])
                    guard let result = try? JSONSerialization.jsonObject(
                        with: data, options: [.fragmentsAllowed]) as? String else {
                        throw DriverError.invalid("Malformed JSON string")
                    }
                    return result
                }
            }
            throw DriverError.invalid("Unterminated JSON string")
        }

        private func skipWhitespace() {
            while index < bytes.count && [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }

        private func take(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            takeCount()
            return true
        }

        private func takeCount() { index += 1 }
    }

    private static func validate(_ value: CommandDocument) throws {
        guard value.schema_version == 1,
              value.sequence >= 1,
              matches(value.session_id, pattern: #"^[A-Za-z0-9._-]{1,128}$"#) else {
            throw DriverError.invalid("command version, sequence, or session identifier is invalid")
        }
        let operations = Set(["capabilities", "observe", "focus", "key", "text", "move",
                              "click", "double-click", "drag", "scroll", "wait", "screenshot",
                              "clipboard-set-sentinel", "video-start", "video-stop"])
        guard operations.contains(value.operation) else {
            throw DriverError.invalid("operation is not supported by the protocol")
        }
        if let point = value.point { try validatePoint(point) }
        if let point = value.destination { try validatePoint(point) }
        if let duration = value.duration_ms, !(0...120_000).contains(duration) {
            throw DriverError.invalid("duration_ms is outside protocol bounds")
        }
        if let request = value.scroll,
           !(-100_000...100_000).contains(request.delta_x) ||
           !(-100_000...100_000).contains(request.delta_y) ||
           !["line", "pixel"].contains(request.unit) {
            throw DriverError.invalid("scroll values are outside protocol bounds")
        }
        if let request = value.text, request.value.count > 4096 {
            throw DriverError.invalid("text value is too long")
        }
        if let request = value.clipboard, request.value.count > 4096 {
            throw DriverError.invalid("clipboard value is too long")
        }
        if let request = value.key {
            let names = Set(["escape", "tab", "return", "space", "backspace", "delete",
                             "home", "end", "page-up", "page-down", "up", "down", "left",
                             "right", "a-z", "0-9"])
            guard names.contains(request.name),
                  request.character == nil || request.character!.count == 1,
                  Set(request.modifiers ?? []).isSubset(of: ["shift", "control", "alt",
                                                             "command", "meta"]),
                  Set(request.modifiers ?? []).count == (request.modifiers ?? []).count,
                  request.phase == nil || ["press", "down", "up"].contains(request.phase!) else {
                throw DriverError.invalid("key request is invalid")
            }
        }
        if let request = value.wait {
            guard ["foreground-target", "target-visible", "target-geometry-stable",
                   "frame-stable"].contains(request.condition),
                  (1...120_000).contains(request.timeout_ms),
                  request.stable_for_ms == nil || (0...30_000).contains(request.stable_for_ms!) else {
                throw DriverError.invalid("wait request is invalid")
            }
        }
        if let request = value.artifact {
            try validateArtifactName(request.name)
            guard request.scope == nil || ["target-window", "guest-display"].contains(request.scope!) else {
                throw DriverError.invalid("artifact scope is invalid")
            }
        }
        if let request = value.video {
            try validateArtifactName(request.artifact_name)
            guard (1...300).contains(request.maximum_seconds),
                  request.frames_per_second == nil ||
                    (1...30).contains(request.frames_per_second!) else {
                throw DriverError.invalid("video request is invalid")
            }
        }
        if let button = value.button, !["primary", "secondary"].contains(button) {
            throw DriverError.invalid("button is invalid")
        }
    }

    private static func validatePoint(_ point: PointRequest) throws {
        guard (0...100_000).contains(point.x), (0...100_000).contains(point.y),
              point.coordinate_space == nil ||
                ["physical-screen", "target-relative"].contains(point.coordinate_space!) else {
            throw DriverError.invalid("point is outside protocol bounds")
        }
    }

    static func validateArtifactName(_ name: String) throws {
        guard matches(name, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#),
              !name.contains("/") else {
            throw DriverError.invalid("artifact name is invalid")
        }
    }
}
