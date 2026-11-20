import Foundation
import XCTest
@testable import VMHostObserver

final class VMHostObserverTests: XCTestCase {
    func testExactSelectionAndAmbiguity() throws {
        let config = SelectionConfig(
            owner: "prl_client_app", title: "Linux evidence", pid: 44, windowID: 900
        )
        let window = WindowIdentity(
            owner: "prl_client_app", pid: 44, title: "Linux evidence", windowID: 900,
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            onScreen: true, layer: 0, obscuredBy: []
        )
        XCTAssertEqual(try WindowCatalog.select(config, from: [window]), window)
        XCTAssertThrowsError(try WindowCatalog.select(config, from: [window, window])) { error in
            XCTAssertTrue(error is ObserverError)
        }
    }

    func testOccludedAndMinimizedWindowsFailClosed() {
        let config = SelectionConfig(
            owner: "prl_client_app", title: "Linux evidence", pid: nil, windowID: nil
        )
        let window = WindowIdentity(
            owner: "prl_client_app", pid: 44, title: "Linux evidence", windowID: 900,
            bounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
            onScreen: true, layer: 0, obscuredBy: [901]
        )
        XCTAssertThrowsError(try WindowCatalog.select(config, from: [window]))
        let minimized = WindowIdentity(
            owner: window.owner, pid: window.pid, title: window.title, windowID: window.windowID,
            bounds: window.bounds, onScreen: false, layer: 0, obscuredBy: []
        )
        XCTAssertThrowsError(try WindowCatalog.select(config, from: [minimized]))
    }

    func testRecordingBoundsAreParsed() throws {
        let args = [
            "vm-host-observer", "record", "--config", "target.json",
            "--artifact-root", ".build-test-artifacts", "--output", "clip.mov",
            "--fps", "30", "--max-duration-seconds", "2.5", "--max-bytes", "1024",
            "--marker", "100:click",
        ]
        guard case .record(let options) = try CLI.parse(args) else {
            return XCTFail("expected record command")
        }
        XCTAssertEqual(options.framesPerSecond, 30)
        XCTAssertEqual(options.maxBytes, 1_024)
        XCTAssertEqual(options.markers, [MarkerSpec(elapsedMilliseconds: 100, label: "click")])
        try FileManager.default.removeItem(at: options.paths.root)
    }

    func testFrameRateAboveThirtyFails() {
        let args = [
            "vm-host-observer", "record", "--config", "target.json",
            "--artifact-root", ".build-test-artifacts", "--output", "clip.mov",
            "--fps", "31",
        ]
        XCTAssertThrowsError(try CLI.parse(args))
    }
}
