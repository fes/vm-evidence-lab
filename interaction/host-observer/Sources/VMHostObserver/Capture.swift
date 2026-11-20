import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

let pinnedBundleIdentifier = "org.vm-evidence-lab.host-observer"

enum Capture {
    static func screenRecordingAllowed() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func capabilities() -> [String: Any] {
        [
            "ok": true,
            "bundleId": pinnedBundleIdentifier,
            "platform": "macos",
            "windowEnumeration": ["api": "CoreGraphics", "contentAccess": false],
            "screenRecording": [
                "status": screenRecordingAllowed() ? "authorized" : "not-authorized",
                "preflightOnly": true,
                "requestPerformed": false,
            ],
            "capture": [
                "api": "ScreenCaptureKit",
                "png": true,
                "windowScoped": true,
                "maximumFps": 30,
                "sha256": true,
            ],
            "limits": [
                "maximumDurationSeconds": 300,
                "maximumBytes": 1_073_741_824,
            ],
            "selfTestCaptures": false,
        ]
    }

    static func selected(_ config: SelectionConfig) throws -> WindowIdentity {
        guard screenRecordingAllowed() else {
            throw ObserverError.permissionDenied(
                "Screen Recording is not authorized for \(pinnedBundleIdentifier); " +
                "grant it explicitly in System Settings and relaunch"
            )
        }
        return try WindowCatalog.select(config, from: WindowCatalog.all())
    }

    static func png(config: SelectionConfig, paths: ArtifactPaths) async throws -> [String: Any] {
        let window = try selected(config)
        try paths.prepare()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let source = content.windows.first(where: { $0.windowID == window.windowID }),
                  source.owningApplication?.processID == window.pid
            else {
                throw ObserverError.unsafe(
                    "selected CoreGraphics window is no longer the exact ScreenCaptureKit window"
                )
            }
            let filter = SCContentFilter(desktopIndependentWindow: source)
            let captureConfig = SCStreamConfiguration()
            captureConfig.width = max(1, Int(window.bounds.width.rounded()))
            captureConfig.height = max(1, Int(window.bounds.height.rounded()))
            captureConfig.pixelFormat = kCVPixelFormatType_32BGRA
            captureConfig.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: captureConfig
            )
            guard let destination = CGImageDestinationCreateWithURL(
                paths.output as CFURL, UTType.png.identifier as CFString, 1, nil
            ) else {
                throw ObserverError.io("cannot create PNG destination")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw ObserverError.io("cannot finalize PNG")
            }
            let size = try fileSize(at: paths.output)
            return [
                "ok": true,
                "kind": "png",
                "path": paths.output.path,
                "artifactRoot": paths.root.path,
                "bytes": size,
                "sha256": try sha256(at: paths.output),
                "window": window.json,
                "screenRecording": "authorized",
                "selection": "exact",
            ]
        } catch {
            paths.removePartial()
            throw error
        }
    }
}
