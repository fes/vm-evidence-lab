import CoreGraphics
import Foundation

struct WindowIdentity: Codable, Sendable, Equatable {
    let owner: String
    let pid: Int32
    let title: String
    let windowID: Int
    let bounds: CGRect
    let onScreen: Bool
    let layer: Int
    var obscuredBy: [Int]

    var json: [String: Any] {
        [
            "owner": owner,
            "pid": pid,
            "title": title,
            "windowId": windowID,
            "bounds": [
                "x": bounds.origin.x,
                "y": bounds.origin.y,
                "width": bounds.width,
                "height": bounds.height,
            ],
            "onscreen": onScreen,
            "layer": layer,
            "occlusion": [
                "detectable": !obscuredBy.isEmpty,
                "windowIdsAbove": obscuredBy,
            ],
        ]
    }
}

struct SelectionConfig: Codable, Sendable, Equatable {
    let owner: String
    let title: String
    let pid: Int32?
    let windowID: Int?

    enum CodingKeys: String, CodingKey {
        case owner, title, pid
        case windowID = "windowId"
    }

    func validated() throws {
        guard owner == "Parallels Desktop" || owner == "prl_client_app" else {
            throw ObserverError.invalid(
                "owner must exactly be 'Parallels Desktop' or 'prl_client_app'"
            )
        }
        guard !title.isEmpty else {
            throw ObserverError.invalid("config title must not be empty")
        }
        if let pid, pid <= 0 {
            throw ObserverError.invalid("config pid must be positive")
        }
        if let windowID, windowID <= 0 {
            throw ObserverError.invalid("config windowId must be positive")
        }
    }

    static func load(path: String) throws -> SelectionConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config = try JSONDecoder().decode(SelectionConfig.self, from: data)
        try config.validated()
        return config
    }
}

enum WindowCatalog {
    static func all() throws -> [WindowIdentity] {
        guard let records = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else {
            throw ObserverError.capture("CoreGraphics did not return a window list")
        }

        let identities = records.compactMap(parse)
        let onScreenOrder = identities.filter(\.onScreen)
        return identities.enumerated().map { _, window in
            var copy = window
            if let position = onScreenOrder.firstIndex(where: { $0.windowID == window.windowID }) {
                copy.obscuredBy = onScreenOrder[..<position].filter {
                    $0.windowID != window.windowID && $0.layer >= 0 && intersects($0.bounds, window.bounds)
                }.map(\.windowID)
            }
            return copy
        }
    }

    static func parse(_ record: [String: Any]) -> WindowIdentity? {
        guard let owner = record[kCGWindowOwnerName as String] as? String,
              let pid = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let id = (record[kCGWindowNumber as String] as? NSNumber)?.intValue,
              let layer = (record[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDictionary = record[kCGWindowBounds as String] as? [String: NSNumber],
              let x = boundsDictionary["X"]?.doubleValue,
              let y = boundsDictionary["Y"]?.doubleValue,
              let width = boundsDictionary["Width"]?.doubleValue,
              let height = boundsDictionary["Height"]?.doubleValue
        else { return nil }
        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let title = record[kCGWindowName as String] as? String ?? ""
        let onScreen = (record[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        return WindowIdentity(
            owner: owner, pid: pid, title: title, windowID: id, bounds: bounds,
            onScreen: onScreen, layer: layer, obscuredBy: []
        )
    }

    static func intersects(_ first: CGRect, _ second: CGRect) -> Bool {
        !first.intersection(second).isNull && !first.intersection(second).isEmpty
    }

    static func select(_ config: SelectionConfig, from windows: [WindowIdentity]) throws -> WindowIdentity {
        let matches = windows.filter {
            $0.owner == config.owner &&
            $0.title == config.title &&
            (config.pid == nil || $0.pid == config.pid) &&
            (config.windowID == nil || $0.windowID == config.windowID)
        }
        guard !matches.isEmpty else {
            throw ObserverError.notFound(
                "no Parallels window exactly matches owner/title/pid/windowId configuration"
            )
        }
        guard matches.count == 1 else {
            throw ObserverError.ambiguous(
                "selection is ambiguous (\(matches.count) windows); pin exact pid and windowId"
            )
        }
        let selected = matches[0]
        guard selected.layer == 0 else {
            throw ObserverError.unsafe("selected Parallels window is not a normal layer-0 window")
        }
        guard selected.onScreen else {
            throw ObserverError.unsafe("selected Parallels window is minimized or off-screen")
        }
        guard selected.obscuredBy.isEmpty else {
            throw ObserverError.unsafe(
                "selected Parallels window is detectably occluded by window IDs \(selected.obscuredBy)"
            )
        }
        guard selected.bounds.width > 0, selected.bounds.height > 0 else {
            throw ObserverError.unsafe("selected Parallels window has empty bounds")
        }
        return selected
    }
}
