import Foundation

struct MarkerSpec: Sendable, Equatable {
    let elapsedMilliseconds: Int
    let label: String
}

enum Command {
    case capabilities
    case list
    case capture(CaptureOptions)
    case record(RecordOptions)
    case selfTest
}

struct CaptureOptions {
    let configPath: String
    let paths: ArtifactPaths
}

struct RecordOptions {
    let configPath: String
    let paths: ArtifactPaths
    let framesPerSecond: Int
    let maxDurationSeconds: Double
    let maxBytes: Int64
    let markers: [MarkerSpec]
}

enum CLI {
    static let usage = """
    Usage:
      vm-host-observer capabilities
      vm-host-observer list [--json]
      vm-host-observer capture --config FILE --artifact-root DIR --output RELATIVE.png
      vm-host-observer record --config FILE --artifact-root DIR --output RELATIVE.mov
        [--fps 1..30] [--max-duration-seconds 1..300]
        [--max-bytes 1..1073741824] [--marker MILLISECONDS:LABEL]...
      vm-host-observer --self-test

    list and capabilities only inspect metadata and never request TCC. Capture and
    record fail unless Screen Recording is already granted to the stable app bundle.
    """

    static func parse(_ arguments: [String]) throws -> Command {
        let args = Array(arguments.dropFirst())
        if args == ["--self-test"] { return .selfTest }
        guard let subcommand = args.first else { throw ObserverError.usage(usage) }
        switch subcommand {
        case "capabilities":
            guard args.count == 1 else { throw ObserverError.usage(usage) }
            return .capabilities
        case "list":
            guard args.count == 1 || args == ["list", "--json"] else {
                throw ObserverError.usage(usage)
            }
            return .list
        case "capture":
            let parsed = try parseOptions(Array(args.dropFirst()), markersAllowed: false)
            let paths = try requiredPaths(parsed)
            guard paths.output.pathExtension.lowercased() == "png" else {
                throw ObserverError.invalid("capture output must have a .png extension")
            }
            return .capture(CaptureOptions(
                configPath: try required("--config", in: parsed), paths: paths
            ))
        case "record":
            let parsed = try parseOptions(Array(args.dropFirst()), markersAllowed: true)
            let paths = try requiredPaths(parsed)
            guard paths.output.pathExtension.lowercased() == "mov" else {
                throw ObserverError.invalid("record output must have a .mov extension")
            }
            let fps = try integer("--fps", in: parsed, default: 15)
            guard (1...30).contains(fps) else {
                throw ObserverError.invalid("--fps must be in the range 1...30")
            }
            let duration = try number("--max-duration-seconds", in: parsed, default: 30)
            guard duration > 0, duration <= 300 else {
                throw ObserverError.invalid("--max-duration-seconds must be in the range (0, 300]")
            }
            let maxBytes = try int64("--max-bytes", in: parsed, default: 500 * 1024 * 1024)
            guard maxBytes > 0, maxBytes <= 1_073_741_824 else {
                throw ObserverError.invalid("--max-bytes must be in the range (0, 1073741824]")
            }
            let markers = try (parsed.values["--marker"] ?? []).map(parseMarker)
            guard markers.count <= 1_000 else {
                throw ObserverError.invalid("no more than 1000 markers are allowed")
            }
            return .record(RecordOptions(
                configPath: try required("--config", in: parsed), paths: paths,
                framesPerSecond: fps, maxDurationSeconds: duration,
                maxBytes: maxBytes, markers: markers
            ))
        default:
            throw ObserverError.usage(usage)
        }
    }

    private struct Options {
        var values: [String: [String]] = [:]
    }

    private static func parseOptions(_ arguments: [String], markersAllowed: Bool) throws -> Options {
        let repeated: Set<String> = markersAllowed ? ["--marker"] : []
        let allowed: Set<String> = markersAllowed
            ? ["--config", "--artifact-root", "--output", "--fps", "--max-duration-seconds",
               "--max-bytes", "--marker"]
            : ["--config", "--artifact-root", "--output"]
        var result = Options()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), index + 1 < arguments.count else {
                throw ObserverError.usage("unknown or incomplete option '\(key)'.\n\(usage)")
            }
            result.values[key, default: []].append(arguments[index + 1])
            if !repeated.contains(key), result.values[key, default: []].count > 1 {
                throw ObserverError.invalid("option \(key) may only be supplied once")
            }
            index += 2
        }
        return result
    }

    private static func requiredPaths(_ options: Options) throws -> ArtifactPaths {
        try ArtifactPaths(
            root: required("--artifact-root", in: options),
            output: required("--output", in: options)
        )
    }

    private static func required(_ key: String, in options: Options) throws -> String {
        guard let value = options.values[key]?.first else {
            throw ObserverError.usage("missing required option \(key)")
        }
        return value
    }

    private static func integer(_ key: String, in options: Options, default fallback: Int) throws -> Int {
        guard let raw = options.values[key]?.first else { return fallback }
        guard let value = Int(raw) else { throw ObserverError.invalid("\(key) requires an integer") }
        return value
    }

    private static func int64(_ key: String, in options: Options, default fallback: Int64) throws -> Int64 {
        guard let raw = options.values[key]?.first else { return fallback }
        guard let value = Int64(raw) else { throw ObserverError.invalid("\(key) requires an integer") }
        return value
    }

    private static func number(_ key: String, in options: Options, default fallback: Double) throws -> Double {
        guard let raw = options.values[key]?.first else { return fallback }
        guard let value = Double(raw), value.isFinite else {
            throw ObserverError.invalid("\(key) requires a finite number")
        }
        return value
    }

    private static func parseMarker(_ raw: String) throws -> MarkerSpec {
        guard let colon = raw.firstIndex(of: ":") else {
            throw ObserverError.invalid("--marker must be MILLISECONDS:LABEL")
        }
        let time = String(raw[..<colon])
        let label = String(raw[raw.index(after: colon)...])
        guard let milliseconds = Int(time), milliseconds >= 0,
              !label.isEmpty, label.utf8.count <= 512 else {
            throw ObserverError.invalid("--marker requires a nonnegative integer and 1..512 byte label")
        }
        return MarkerSpec(elapsedMilliseconds: milliseconds, label: label)
    }
}
