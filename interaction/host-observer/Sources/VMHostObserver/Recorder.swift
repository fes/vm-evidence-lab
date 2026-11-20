import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

private struct MarkerEvent {
    let elapsedMilliseconds: Int
    let name: String
    let label: String
}

private final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: RecordOptions
    private let window: WindowIdentity
    private let queue = DispatchQueue(label: "org.vm-evidence-lab.host-observer.frames")
    private let controlQueue = DispatchQueue(label: "org.vm-evidence-lab.host-observer.control")
    private let stateLock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private var stream: SCStream?
    private var writerStarted = false
    private var finishing = false
    private var timer: DispatchSourceTimer?
    private var emittedMarkers: Set<Int> = []
    private var events: [MarkerEvent]
    private var continuation: CheckedContinuation<RecordResult, Error>?

    init(
        options: RecordOptions, window: WindowIdentity, contentWindow: SCWindow
    ) throws {
        self.options = options
        self.window = window
        self.writer = try AVAssetWriter(url: options.paths.output, fileType: .mov)
        let width = max(2, Int(window.bounds.width.rounded()))
        let height = max(2, Int(window.bounds.height.rounded()))
        let evenWidth = width - (width % 2)
        let evenHeight = height - (height % 2)
        self.videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: evenWidth,
                AVVideoHeightKey: evenHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 8_000_000,
                    AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2,
                ],
            ]
        )
        self.videoInput.expectsMediaDataInRealTime = true
        self.events = [MarkerEvent(elapsedMilliseconds: 0, name: "recording", label: "started")]
        guard self.writer.canAdd(self.videoInput) else {
            throw ObserverError.capture("AVAssetWriter rejected the bounded video input")
        }
        self.writer.add(self.videoInput)
        guard self.writer.startWriting() else {
            throw ObserverError.capture(
                self.writer.error?.localizedDescription ?? "AVAssetWriter failed to start"
            )
        }
        super.init()

        let configuration = SCStreamConfiguration()
        configuration.width = evenWidth
        configuration.height = evenHeight
        configuration.minimumFrameInterval = CMTime(
            value: 1, timescale: CMTimeScale(options.framesPerSecond)
        )
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(desktopIndependentWindow: contentWindow)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func run() async throws -> RecordResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            startTimer()
            Task {
                do {
                    try await self.stream?.startCapture()
                } catch {
                    self.finish(with: error)
                }
            }
        }
    }

    private func startTimer() {
        let source = DispatchSource.makeTimerSource(queue: controlQueue)
        source.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        let elapsed = elapsedMilliseconds()
        stateLock.lock()
        if finishing {
            stateLock.unlock()
            return
        }
        for (index, marker) in options.markers.enumerated()
        where elapsed >= marker.elapsedMilliseconds && !emittedMarkers.contains(index) {
            emittedMarkers.insert(index)
            events.append(MarkerEvent(
                elapsedMilliseconds: elapsed, name: "action", label: marker.label
            ))
        }
        stateLock.unlock()
        if Double(elapsed) >= options.maxDurationSeconds * 1_000 {
            finish(with: nil)
            return
        }
        if currentFileSize() > options.maxBytes {
            finish(with: ObserverError.capture("recording exceeded --max-bytes"))
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        stateLock.lock()
        guard !finishing else {
            stateLock.unlock()
            return
        }
        if !writerStarted, CMSampleBufferIsValid(sampleBuffer) {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            writerStarted = true
        }
        let appended = videoInput.isReadyForMoreMediaData ? videoInput.append(sampleBuffer) : true
        stateLock.unlock()
        if !appended {
            finish(with: writer.error ?? ObserverError.capture("AVAssetWriter rejected a video frame"))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(with: error)
    }

    private func elapsedMilliseconds() -> Int {
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
    }

    private func currentFileSize() -> Int64 {
        ((try? fileSize(at: options.paths.output)) ?? 0)
    }

    private func finish(with error: Error?) {
        stateLock.lock()
        guard !finishing else {
            stateLock.unlock()
            return
        }
        finishing = true
        timer?.cancel()
        stateLock.unlock()

        Task { [self] in
            do {
                if error == nil {
                    try await stream?.stopCapture()
                } else {
                    try? await stream?.stopCapture()
                }
                let hasFrames = hasCapturedFrames()
                if hasFrames {
                    videoInput.markAsFinished()
                    await writer.finishWriting()
                } else {
                    writer.cancelWriting()
                }
                if let error {
                    throw error
                }
                if !hasFrames {
                    throw ObserverError.capture("recording ended without any captured frames")
                }
                if writer.status == .failed {
                    throw writer.error ?? ObserverError.capture("AVAssetWriter failed")
                }
                let bytes = try fileSize(at: options.paths.output)
                guard bytes <= options.maxBytes else {
                    throw ObserverError.capture(
                        "final recording is \(bytes) bytes; limit is \(options.maxBytes)"
                    )
                }
                appendEvent(MarkerEvent(
                    elapsedMilliseconds: elapsedMilliseconds(), name: "recording", label: "stopped"
                ))
                try writeMarkers()
                complete(.success(RecordResult(
                    bytes: bytes, durationMilliseconds: elapsedMilliseconds(),
                    sha256: try sha256(at: options.paths.output),
                    markerCount: events.count
                )))
            } catch {
                options.paths.removePartial()
                complete(.failure(error))
            }
        }
    }

    private func writeMarkers() throws {
        stateLock.lock()
        let snapshot = events
        stateLock.unlock()
        let markerJSON: [[String: Any]] = snapshot.map {
            ["elapsedMilliseconds": $0.elapsedMilliseconds, "name": $0.name, "label": $0.label]
        }
        try writeJSON([
            "schema": "vm-evidence-lab/host-observer-marker-sidecar-v1",
            "bundleId": pinnedBundleIdentifier,
            "artifact": options.paths.output.lastPathComponent,
            "window": window.json,
            "markers": markerJSON,
        ], to: options.paths.markers)
    }

    private func hasCapturedFrames() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return writerStarted
    }

    private func appendEvent(_ event: MarkerEvent) {
        stateLock.lock()
        events.append(event)
        stateLock.unlock()
    }

    private func complete(_ result: Result<RecordResult, Error>) {
        stateLock.lock()
        let continuation = self.continuation
        self.continuation = nil
        stateLock.unlock()
        continuation?.resume(with: result)
    }
}

private struct RecordResult {
    let bytes: Int64
    let durationMilliseconds: Int
    let sha256: String
    let markerCount: Int
}

enum Recorder {
    static func run(config: SelectionConfig, options: RecordOptions) async throws -> [String: Any] {
        let window = try Capture.selected(config)
        try options.paths.prepare()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let source = content.windows.first(where: { $0.windowID == window.windowID }),
                  source.owningApplication?.processID == window.pid
            else {
                throw ObserverError.unsafe(
                    "selected CoreGraphics window is no longer the exact ScreenCaptureKit window"
                )
            }
            let session = try RecordingSession(options: options, window: window, contentWindow: source)
            let result = try await session.run()
            return [
                "ok": true,
                "kind": "mov",
                "path": options.paths.output.path,
                "markerSidecar": options.paths.markers.path,
                "artifactRoot": options.paths.root.path,
                "bytes": result.bytes,
                "sha256": result.sha256,
                "durationMilliseconds": result.durationMilliseconds,
                "framesPerSecondMaximum": options.framesPerSecond,
                "markerCount": result.markerCount,
                "window": window.json,
                "screenRecording": "authorized",
                "selection": "exact",
            ]
        } catch {
            options.paths.removePartial()
            throw error
        }
    }
}
