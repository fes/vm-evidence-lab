import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Foundation

struct WindowSnapshot {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect
    let visible: Bool
    let layer: Int

    var screenPointScale: Double {
        Double(NSScreen.screens.filter { $0.frame.intersects(bounds) }
            .map(\.backingScaleFactor).max() ?? 1)
    }
}

final class InteractionDriver {
    let session: SessionDocument
    let artifactRoot: URL
    private var commandCount = 0
    private var highestSequence = 0
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(session: SessionDocument, artifactRoot: URL) throws {
        self.session = session
        self.artifactRoot = artifactRoot
        guard FileManager.default.fileExists(atPath: artifactRoot.path) else {
            throw DriverError.invalid("artifact root does not exist")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: artifactRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DriverError.invalid("artifact root is not a directory")
        }
        let standardized = artifactRoot.standardizedFileURL
        let resolved = artifactRoot.resolvingSymlinksInPath()
        guard artifactRoot.path.hasPrefix("/"), standardized == artifactRoot,
              resolved == standardized,
              artifactRoot.lastPathComponent != "." else {
            throw DriverError.invalid("artifact root must be an absolute canonical non-symlink path")
        }
    }

    func handle(_ command: CommandDocument) -> InteractionResult {
        let started = Date()
        var status = "pass"
        var message = "Command completed"
        var observation: AnyEncodableDictionary?
        var artifacts: [ArtifactResult] = []
        var nativeError: String?

        defer {
            // Flags are applied directly to input events, so no modifier keys are left down.
        }

        do {
            guard command.session_id == session.session_id else {
                throw DriverError.denied("Command session identifier does not match the session")
            }
            commandCount += 1
            guard commandCount <= session.limits.maximum_commands else {
                throw DriverError.denied("Session maximum command count has been reached")
            }
            guard command.sequence > highestSequence else {
                throw DriverError.denied("Command sequence must increase")
            }
            highestSequence = command.sequence
            let deadline = Deadline(milliseconds: min(session.limits.command_timeout_ms, 120_000))
            try validateOperationFields(command)
            try requireGrant(for: command)
            let repeatedInput = command.operation == "double-click" ? 2 : 1
            let clickGap = command.operation == "double-click" ? 80 : 0
            guard (command.duration_ms ?? 0) * repeatedInput + clickGap <=
                    session.limits.command_timeout_ms else {
                throw DriverError.denied("Input duration exceeds the command timeout")
            }

            switch command.operation {
            case "capabilities":
                observation = capabilityObservation()
                message = "Capabilities reported"
            case "observe":
                observation = observationForTarget()
                message = "Target observed"
            case "focus":
                try focus()
                message = "Target window focused"
            case "key":
                try sendKey(command.key!)
                message = "Key input posted"
            case "text":
                try sendText(command.text!, deadline: deadline)
                message = "Bounded text input posted"
            case "move":
                try move(to: command.point!)
                message = "Pointer moved"
            case "click":
                try click(at: command.point!, button: command.button ?? "primary", count: 1,
                          duration: command.duration_ms ?? 0, deadline: deadline)
                message = "Click posted"
            case "double-click":
                try click(at: command.point!, button: command.button ?? "primary", count: 2,
                          duration: command.duration_ms ?? 0, deadline: deadline)
                message = "Double-click posted"
            case "drag":
                try drag(from: command.point!, to: command.destination!,
                         button: command.button ?? "primary", duration: command.duration_ms ?? 0,
                         deadline: deadline)
                message = "Drag posted"
            case "scroll":
                try scroll(command.scroll!, point: command.point)
                message = "Scrolling event posted"
            case "wait":
                try wait(command.wait!, deadline: deadline)
                message = "Wait condition satisfied"
            case "screenshot":
                artifacts = [try screenshot(command.artifact!, deadline: deadline)]
                message = "Screenshot captured"
            case "clipboard-set-sentinel":
                try setClipboardSentinel(command.clipboard!)
                message = "Clipboard sentinel set"
            case "video-start", "video-stop":
                throw DriverError.unsupported(
                    "Video recording is unsupported by this driver; screenshot evidence remains available"
                )
            default:
                throw DriverError.invalid("Unknown operation")
            }
        } catch let error as DriverError {
            status = error.status
            message = error.message
            if case .native(let detail) = error { nativeError = detail }
        } catch {
            status = "fail"
            message = "Unexpected native failure"
            nativeError = String(describing: error)
        }

        let finished = Date()
        let target = targetResult()
        return InteractionResult(
            session_id: session.session_id,
            sequence: command.sequence,
            status: status,
            operation: command.operation,
            started_at: Self.dateFormatter.string(from: started),
            completed_at: Self.dateFormatter.string(from: finished),
            duration_ms: max(0, Int(finished.timeIntervalSince(started) * 1000)),
            diagnostics: DiagnosticsResult(
                target: target,
                message: message,
                native_error: nativeError,
                tcc: TCCResult(accessibility: AXIsProcessTrusted(),
                               screen_recording: CGPreflightScreenCaptureAccess())
            ),
            observation: observation,
            artifacts: artifacts
        )
    }

    func failureResult(sequence: Int, operation: String, message: String) -> InteractionResult {
        let now = Date()
        return InteractionResult(
            session_id: session.session_id,
            sequence: max(1, sequence),
            status: "fail",
            operation: operation.isEmpty ? "invalid" : operation,
            started_at: Self.dateFormatter.string(from: now),
            completed_at: Self.dateFormatter.string(from: now),
            duration_ms: 0,
            diagnostics: DiagnosticsResult(
                target: targetResult(),
                message: message,
                tcc: TCCResult(accessibility: AXIsProcessTrusted(),
                               screen_recording: CGPreflightScreenCaptureAccess())
            ),
            observation: nil,
            artifacts: []
        )
    }

    func selfTest() throws -> [String: Any] {
        let sessionJSON = """
        {"schema_version":1,"session_id":"self-test","platform":"macos","run_id":"self-test","target":{"pid":1},"grants":[],"limits":{"maximum_commands":1,"command_timeout_ms":100,"maximum_artifact_bytes":1,"maximum_video_seconds":1}}
        """.data(using: .utf8)!
        let commandJSON = """
        {"schema_version":1,"session_id":"self-test","sequence":1,"operation":"capabilities"}
        """.data(using: .utf8)!
        _ = try StrictJSON.session(sessionJSON)
        _ = try StrictJSON.command(commandJSON)
        do {
            _ = try StrictJSON.command(Data("""
            {"schema_version":1,"session_id":"self-test","session_id":"duplicate","sequence":1,"operation":"capabilities"}
            """.utf8))
            throw DriverError.native("duplicate JSON field was accepted")
        } catch DriverError.invalid { }
        let allowed: [String: Any] = ["schema_version": 1]
        try StrictJSON.checkObject(allowed, keys: ["schema_version"], path: "self-test")
        guard keyCode("a-z", character: "q") == 12,
              keyCode("0-9", character: "7") == 26,
              sha256(Data("sentinel".utf8)).count == 64 else {
            throw DriverError.native("self-test assertion failed")
        }
        return ["driver": "macos-gui-driver/1", "status": "pass", "posted_input": false,
                "inspected_applications": false]
    }

    private func validateOperationFields(_ command: CommandDocument) throws {
        let required: [String: [String]] = [
            "key": ["key"], "text": ["text"], "move": ["point"], "click": ["point"],
            "double-click": ["point"], "drag": ["point", "destination"],
            "scroll": ["scroll"], "wait": ["wait"], "screenshot": ["artifact"],
            "clipboard-set-sentinel": ["clipboard"]
        ]
        for field in required[command.operation] ?? [] {
            let present: Bool
            switch field {
            case "key": present = command.key != nil
            case "text": present = command.text != nil
            case "point": present = command.point != nil
            case "destination": present = command.destination != nil
            case "scroll": present = command.scroll != nil
            case "wait": present = command.wait != nil
            case "artifact": present = command.artifact != nil
            case "clipboard": present = command.clipboard != nil
            case "video": present = command.video != nil
            default: present = false
            }
            guard present else { throw DriverError.invalid("Operation is missing \(field)") }
        }
        var allowed = Set(required[command.operation] ?? [])
        if command.operation == "scroll" { allowed.insert("point") }
        if ["video-start", "video-stop"].contains(command.operation) { allowed.insert("video") }
        if ["click", "double-click", "drag"].contains(command.operation) {
            allowed.formUnion(["button", "duration_ms"])
        }
        let forbidden = Set(["key", "text", "point", "destination", "button", "duration_ms",
                             "scroll", "wait", "artifact", "clipboard", "video"]).subtracting(allowed)
        if forbidden.contains("key") && command.key != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("text") && command.text != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("point") && command.point != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("destination") && command.destination != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if command.operation != "click" && command.operation != "double-click" &&
            command.operation != "drag" && command.button != nil {
            throw DriverError.invalid("button is not valid for this operation")
        }
        if command.operation != "click" && command.operation != "double-click" &&
            command.operation != "drag" && command.duration_ms != nil {
            throw DriverError.invalid("duration_ms is not valid for this operation")
        }
        if forbidden.contains("scroll") && command.scroll != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("wait") && command.wait != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("artifact") && command.artifact != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("clipboard") && command.clipboard != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if forbidden.contains("video") && command.video != nil { throw DriverError.invalid("Field is not valid for this operation") }
        if command.operation == "focus", command.point != nil { throw DriverError.invalid("focus does not accept a point") }
        if let video = command.video, video.maximum_seconds > session.limits.maximum_video_seconds {
            throw DriverError.denied("Video request exceeds maximum_video_seconds")
        }
    }

    private func requireGrant(for command: CommandDocument) throws {
        let requirement: String?
        switch command.operation {
        case "capabilities": requirement = nil
        case "observe", "wait": requirement = "observe"
        case "focus": requirement = "accessibility"
        case "key", "text": requirement = "keyboard"
        case "move", "click", "double-click", "drag": requirement = "pointer"
        case "scroll": requirement = "wheel"
        case "screenshot": requirement = "screenshot"
        case "clipboard-set-sentinel": requirement = "clipboard-sentinel"
        case "video-start", "video-stop": requirement = "video"
        default: requirement = nil
        }
        if let requirement, !session.grants.contains(requirement) {
            throw DriverError.denied("Operation requires the \(requirement) grant")
        }
        if command.operation == "wait" && command.wait?.condition == "frame-stable",
           !session.grants.contains("screenshot") {
            throw DriverError.denied("Frame stability observation requires the screenshot grant")
        }
    }

    private func capabilityObservation() -> AnyEncodableDictionary {
        let ops: [JSONValue] = [
            "capabilities", "observe", "focus", "key", "text", "move", "click",
            "double-click", "drag", "scroll", "wait", "screenshot", "clipboard-set-sentinel"
        ].map(JSONValue.string)
        return AnyEncodableDictionary(values: [
            "operations": .array(ops),
            "video": .object([
                "status": .string("unsupported"),
                "reason": .string("The macOS guest driver does not record video")
            ]),
            "grants": .array(session.grants.map(JSONValue.string)),
            "clipboard_policy": .string("write-and-optionally-verify-sentinel-only"),
            "driver_bundle_identifier": .string("com.fes.FesTermVMEvidenceInteraction")
        ])
    }

    private func observationForTarget() -> AnyEncodableDictionary {
        let target = targetSnapshot()
        return AnyEncodableDictionary(values: [
            "pid": .integer(session.target.pid),
            "window_found": .bool(target != nil),
            "foreground": .bool(isForeground()),
            "visible": .bool(target?.visible ?? false),
            "window_id": target.map { .string(String($0.id)) } ?? .null,
            "geometry": target.map {
                .object(["x": .double($0.bounds.origin.x), "y": .double($0.bounds.origin.y),
                         "width": .double($0.bounds.width), "height": .double($0.bounds.height)])
            } ?? .null
        ])
    }

    private func targetResult() -> TargetResult {
        let snapshot = targetSnapshot()
        return TargetResult(
            pid: session.target.pid,
            window_found: snapshot != nil,
            foreground: isForeground(),
            visible: snapshot?.visible ?? false,
            window_id: snapshot.map { String($0.id) },
            geometry: snapshot.map {
                GeometryResult(x: $0.bounds.origin.x, y: $0.bounds.origin.y,
                               width: $0.bounds.width, height: $0.bounds.height,
                               scale_factor: $0.screenPointScale)
            }
        )
    }

    private func targetSnapshot() -> WindowSnapshot? {
        let windows = windowSnapshots(onScreenOnly: false)
        let owned = windows.filter { $0.pid == pid_t(session.target.pid) }
        return owned.indices.contains(session.target.window_index ?? 0)
            ? owned[session.target.window_index ?? 0] : nil
    }

    private func windowSnapshots(onScreenOnly: Bool) -> [WindowSnapshot] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        if onScreenOnly { options.insert(.optionOnScreenOnly) } else {
            options.insert(.optionAll)
        }
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { item in
            guard let pidNumber = item[kCGWindowOwnerPID as String] as? NSNumber,
                  let idNumber = item[kCGWindowNumber as String] as? NSNumber,
                  let boundsDictionary = item[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
                return nil
            }
            let visible = (item[kCGWindowIsOnscreen as String] as? Bool) == true
            let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            return WindowSnapshot(id: CGWindowID(idNumber.uint64Value), pid: pid_t(pidNumber.int32Value),
                                  bounds: bounds, visible: visible, layer: layer)
        }
    }

    private func isForeground() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid_t(session.target.pid)
    }

    private func requireTarget(_ point: CGPoint? = nil) throws -> WindowSnapshot {
        guard NSRunningApplication(processIdentifier: pid_t(session.target.pid)) != nil else {
            throw DriverError.denied("Target PID is not an existing running process")
        }
        guard let target = targetSnapshot() else {
            throw DriverError.denied("Target window was not found for the PID and window index")
        }
        guard target.pid == pid_t(session.target.pid) else {
            throw DriverError.denied("Window ownership check failed")
        }
        guard target.visible else { throw DriverError.denied("Target window is not visible") }
        if let point {
            let top = windowSnapshots(onScreenOnly: true).first {
                $0.layer == 0 && $0.bounds.contains(point)
            }
            guard let top, top.id == target.id, top.pid == pid_t(session.target.pid) else {
                throw DriverError.denied("Point is not owned by the selected visible target window")
            }
            guard target.bounds.contains(point) else {
                throw DriverError.denied("Point is outside the selected target window")
            }
        }
        return target
    }

    private func ensureAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw DriverError.denied("Accessibility TCC permission is required for the interaction bundle")
        }
    }

    private func globalPoint(_ point: PointRequest) throws -> CGPoint {
        let target = try requireTarget()
        if point.coordinate_space == "target-relative" {
            let global = CGPoint(x: target.bounds.origin.x + point.x,
                                 y: target.bounds.origin.y + point.y)
            return global
        }
        return CGPoint(x: point.x, y: point.y)
    }

    private func post(_ event: CGEvent) {
        event.post(tap: .cghidEventTap)
    }

    private func focus() throws {
        try ensureAccessibility()
        let target = try requireTarget()
        guard let application = NSRunningApplication(processIdentifier: target.pid) else {
            throw DriverError.denied("Target application is not running")
        }
        application.activate(options: [])
        let appElement = AXUIElementCreateApplication(target.pid)
        var windowsObject: CFTypeRef?
        let copied = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard copied == .success, let windows = windowsObject as? [AXUIElement] else {
            throw DriverError.native("Could not enumerate target windows through Accessibility")
        }
        let matchingWindow = windows.first { element in
            guard let bounds = accessibilityBounds(element) else { return false }
            return abs(bounds.origin.x - target.bounds.origin.x) <= 2 &&
                abs(bounds.origin.y - target.bounds.origin.y) <= 2 &&
                abs(bounds.width - target.bounds.width) <= 2 &&
                abs(bounds.height - target.bounds.height) <= 2
        }
        guard let matchingWindow else {
            throw DriverError.denied("Selected window could not be matched through Accessibility")
        }
        _ = AXUIElementPerformAction(matchingWindow, kAXRaiseAction as CFString)
        let focused = AXUIElementSetAttributeValue(
            matchingWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard focused == .success else {
            throw DriverError.native("Accessibility could not focus the selected window")
        }
        Thread.sleep(forTimeInterval: 0.05)
        guard isForeground() else {
            throw DriverError.native("Target application did not become foreground")
        }
    }

    private func accessibilityBounds(_ window: AXUIElement) -> CGRect? {
        var positionObject: CFTypeRef?
        var sizeObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString,
                                            &positionObject) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString,
                                            &sizeObject) == .success,
              let positionValue = positionObject as! AXValue?,
              let sizeValue = sizeObject as! AXValue? else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private func sendKey(_ request: KeyRequest) throws {
        try focus()
        guard let code = keyCode(request.name, character: request.character) else {
            throw DriverError.invalid("Key requires a character valid for its declared name")
        }
        let modifiers = modifierFlags(request.modifiers ?? [])
        let phase = request.phase ?? "press"
        if phase == "up" {
            postKey(code: code, down: false, flags: modifiers)
            return
        }
        postKey(code: code, down: true, flags: modifiers)
        if phase == "press" { postKey(code: code, down: false, flags: modifiers) }
    }

    private func postKey(code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) {
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    private func sendText(_ request: TextRequest, deadline: Deadline) throws {
        try focus()
        let utf16 = Array(request.value.utf16)
        guard utf16.count <= 8192 else {
            throw DriverError.invalid("Unicode text exceeds the bounded UTF-16 length")
        }
        var chunks: [[UniChar]] = [[]]
        for scalar in request.value.unicodeScalars {
            let scalarUnits = Array(String(scalar).utf16)
            if chunks[chunks.count - 1].count + scalarUnits.count > 20 {
                chunks.append([])
            }
            chunks[chunks.count - 1].append(contentsOf: scalarUnits)
        }
        for chunk in chunks where !chunk.isEmpty {
            guard !deadline.expired else {
                throw DriverError.native("Text input exceeded the command timeout")
            }
            let ownershipTarget = try requireTarget()
            guard isForeground(),
                  let selected = targetSnapshot(),
                  selected.id == ownershipTarget.id else {
                throw DriverError.denied("Target lost foreground ownership during text input")
            }
            let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                                virtualKey: 0, keyDown: true)!
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: .cghidEventTap)
            let up = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                             virtualKey: 0, keyDown: false)!
            up.post(tap: .cghidEventTap)
        }
    }

    private func move(to request: PointRequest) throws {
        try ensureAccessibility()
        let point = try globalPoint(request)
        _ = try requireTarget(point)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                  mouseCursorPosition: point, mouseButton: .left) else {
            throw DriverError.native("Could not create mouse move event")
        }
        post(event)
    }

    private func click(at request: PointRequest, button: String, count: Int, duration: Int,
                       deadline: Deadline) throws {
        try ensureAccessibility()
        let point = try globalPoint(request)
        _ = try requireTarget(point)
        let secondary = button == "secondary"
        let mouseButton: CGMouseButton = secondary ? .right : .left
        let downType: CGEventType = secondary ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = secondary ? .rightMouseUp : .leftMouseUp
        for clickIndex in 0..<count {
            let down = CGEvent(mouseEventSource: nil, mouseType: downType,
                               mouseCursorPosition: point, mouseButton: mouseButton)!
            let up = CGEvent(mouseEventSource: nil, mouseType: upType,
                             mouseCursorPosition: point, mouseButton: mouseButton)!
            let state = Int64(count == 2 ? clickIndex + 1 : 1)
            down.setIntegerValueField(.mouseEventClickState, value: state)
            up.setIntegerValueField(.mouseEventClickState, value: state)
            post(down)
            if duration > 0 {
                do { try sleep(milliseconds: duration, deadline: deadline) }
                catch {
                    post(up)
                    throw error
                }
            }
            post(up)
            if count == 2, clickIndex == 0 {
                try sleep(milliseconds: 80, deadline: deadline)
            }
        }
    }

    private func drag(from: PointRequest, to: PointRequest, button: String, duration: Int,
                      deadline: Deadline) throws {
        try ensureAccessibility()
        let source = try globalPoint(from)
        let destination = try globalPoint(to)
        _ = try requireTarget(source)
        _ = try requireTarget(destination)
        let secondary = button == "secondary"
        let mouseButton: CGMouseButton = secondary ? .right : .left
        post(CGEvent(mouseEventSource: nil, mouseType: secondary ? .rightMouseDown : .leftMouseDown,
                     mouseCursorPosition: source, mouseButton: mouseButton)!)
        post(CGEvent(mouseEventSource: nil,
                     mouseType: secondary ? .rightMouseDragged : .leftMouseDragged,
                     mouseCursorPosition: destination, mouseButton: mouseButton)!)
        if duration > 0 {
            do { try sleep(milliseconds: duration, deadline: deadline) }
            catch {
                post(CGEvent(mouseEventSource: nil,
                             mouseType: secondary ? .rightMouseUp : .leftMouseUp,
                             mouseCursorPosition: destination, mouseButton: mouseButton)!)
                throw error
            }
        }
        post(CGEvent(mouseEventSource: nil, mouseType: secondary ? .rightMouseUp : .leftMouseUp,
                     mouseCursorPosition: destination, mouseButton: mouseButton)!)
    }

    private func sleep(milliseconds: Int, deadline: Deadline) throws {
        let end = Date().addingTimeInterval(Double(milliseconds) / 1000)
        while Date() < end {
            if deadline.expired { throw DriverError.native("Input duration exceeded the command timeout") }
            Thread.sleep(forTimeInterval: min(0.02, max(0, end.timeIntervalSinceNow)))
        }
    }

    private func scroll(_ request: ScrollRequest, point pointRequest: PointRequest?) throws {
        try ensureAccessibility()
        let target = try requireTarget()
        let point: CGPoint
        if let pointRequest {
            point = try globalPoint(pointRequest)
            _ = try requireTarget(point)
        } else {
            point = CGPoint(x: target.bounds.midX, y: target.bounds.midY)
            _ = try requireTarget(point)
        }
        moveCursor(point)
        let units: CGScrollEventUnit = request.unit == "line" ? .line : .pixel
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                  wheel1: Int32(request.delta_y.rounded()),
                                  wheel2: Int32(request.delta_x.rounded()), wheel3: 0) else {
            throw DriverError.native("Could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    private func moveCursor(_ point: CGPoint) {
        if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: point, mouseButton: .left) {
            post(event)
        }
    }

    private func wait(_ request: WaitRequest, deadline: Deadline) throws {
        let requestedDeadline = min(deadline, Deadline(milliseconds: request.timeout_ms))
        let stableFor = Double(request.stable_for_ms ?? 0) / 1000
        var stableSince: Date?
        var previous: String?
        while !requestedDeadline.expired {
            let snapshot = targetSnapshot()
            let satisfied: Bool
            switch request.condition {
            case "foreground-target":
                satisfied = isForeground() && snapshot != nil
            case "target-visible":
                satisfied = snapshot?.visible == true
            case "target-geometry-stable":
                guard let snapshot else { satisfied = false; break }
                let current = "\(snapshot.bounds.origin.x),\(snapshot.bounds.origin.y)," +
                    "\(snapshot.bounds.width),\(snapshot.bounds.height)"
                if previous == current {
                    if stableSince == nil { stableSince = Date() }
                } else {
                    previous = current
                    stableSince = nil
                }
                satisfied = stableSince.map { Date().timeIntervalSince($0) >= stableFor } ?? false
            case "frame-stable":
                guard let snapshot, snapshot.visible,
                      let frameHash = windowFrameHash(snapshot.id, deadline: requestedDeadline) else {
                    satisfied = false
                    break
                }
                if previous == frameHash {
                    if stableSince == nil { stableSince = Date() }
                } else {
                    previous = frameHash
                    stableSince = nil
                }
                satisfied = stableSince.map { Date().timeIntervalSince($0) >= stableFor } ?? false
            default:
                throw DriverError.invalid("Unsupported wait condition")
            }
            if satisfied { return }
            Thread.sleep(forTimeInterval: 0.025)
        }
        throw DriverError.native("Wait condition timed out")
    }

    private func windowFrameHash(_ id: CGWindowID, deadline: Deadline) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let path = artifactRoot.appendingPathComponent(
            ".vm-interaction-frame-\(UUID().uuidString).png", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            try runProcess("/usr/sbin/screencapture",
                           arguments: ["-x", "-t", "png", "-l", String(id), path.path],
                           deadline: min(deadline, Deadline(milliseconds: 2_000)))
            return try fileSHA256(path, deadline: deadline)
        } catch {
            return nil
        }
    }

    private func screenshot(_ request: ArtifactRequest, deadline: Deadline) throws -> ArtifactResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw DriverError.denied("Screen Recording TCC permission is required for the interaction bundle")
        }
        try StrictJSON.validateArtifactName(request.name)
        let scope = request.scope ?? "target-window"
        guard ["target-window", "guest-display"].contains(scope) else {
            throw DriverError.invalid("Screenshot scope is invalid")
        }
        let output = artifactRoot.appendingPathComponent(request.name, isDirectory: false)
        guard output.deletingLastPathComponent().standardizedFileURL == artifactRoot else {
            throw DriverError.denied("Artifact path escaped the validated root")
        }
        var existingStatus = stat()
        guard lstat(output.path, &existingStatus) != 0 else {
            throw DriverError.denied("Artifact already exists; artifacts are immutable")
        }
        var arguments = ["-x", "-t", "png"]
        if scope == "target-window" {
            let target = try requireTarget()
            arguments += ["-l", String(target.id)]
        }
        arguments.append(output.path)
        try runProcess("/usr/sbin/screencapture", arguments: arguments, deadline: deadline)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw DriverError.native("screencapture did not create an artifact")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= session.limits.maximum_artifact_bytes else {
            try? FileManager.default.removeItem(at: output)
            throw DriverError.denied("Screenshot exceeds maximum_artifact_bytes")
        }
        let digest: String
        do { digest = try fileSHA256(output, deadline: deadline) }
        catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return ArtifactResult(name: request.name, path: output.path, size: size, sha256: digest)
    }

    private func runProcess(_ executable: String, arguments: [String], deadline: Deadline) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try process.run() }
        catch { throw DriverError.native("Could not execute screencapture") }
        while process.isRunning && !deadline.expired { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw DriverError.native("screencapture exceeded the command timeout")
        }
        guard process.terminationStatus == 0 else {
            throw DriverError.native("screencapture exited unsuccessfully")
        }
    }

    private func setClipboardSentinel(_ request: ClipboardRequest) throws {
        guard request.value.range(
            of: #"^vm-evidence-sentinel:[A-Za-z0-9._-]{1,256}$"#,
            options: .regularExpression
        ) != nil else {
            throw DriverError.denied("Clipboard contents must use the vm-evidence-sentinel prefix and bounded token")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(request.value, forType: .string) else {
            throw DriverError.native("Could not set clipboard sentinel")
        }
        if request.verify ?? true {
            guard pasteboard.string(forType: .string) == request.value else {
                throw DriverError.native("Clipboard sentinel verification failed")
            }
        }
    }

    private func keyCode(_ name: String, character: String?) -> CGKeyCode? {
        let fixed: [String: CGKeyCode] = [
            "escape": 53, "tab": 48, "return": 36, "space": 49, "backspace": 51,
            "delete": 117, "home": 115, "end": 119, "page-up": 116, "page-down": 121,
            "up": 126, "down": 125, "left": 123, "right": 124
        ]
        if let code = fixed[name] { return code }
        guard let character, character.count == 1 else { return nil }
        if name == "a-z", character.lowercased() >= "a", character.lowercased() <= "z" {
            let letters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
            let codes: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45,
                                      31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
            return codes[letters.firstIndex(of: Character(character.lowercased()))!]
        }
        if name == "0-9", character >= "0", character <= "9" {
            let digits: [Character] = Array("0123456789")
            let codes: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
            return codes[digits.firstIndex(of: Character(character))!]
        }
        return nil
    }

    private func modifierFlags(_ names: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for name in names {
            switch name {
            case "shift": flags.insert(.maskShift)
            case "control": flags.insert(.maskControl)
            case "alt": flags.insert(.maskAlternate)
            case "command", "meta": flags.insert(.maskCommand)
            default: break
            }
        }
        return flags
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fileSHA256(_ url: URL, deadline: Deadline) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            if deadline.expired {
                throw DriverError.native("Artifact hashing exceeded the command timeout")
            }
            let data = try handle.read(upToCount: 1 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct Deadline: Comparable {
    let end: Date
    init(milliseconds: Int) { end = Date().addingTimeInterval(Double(milliseconds) / 1000) }
    var expired: Bool { Date() >= end }
    static func < (lhs: Deadline, rhs: Deadline) -> Bool { lhs.end < rhs.end }
}
