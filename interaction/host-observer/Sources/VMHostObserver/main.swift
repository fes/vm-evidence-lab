import Foundation

@main
struct VMHostObserverMain {
    static func main() async {
        do {
            switch try CLI.parse(CommandLine.arguments) {
            case .capabilities:
                try emitJSON(Capture.capabilities())
            case .list:
                try emitJSON([
                    "ok": true,
                    "source": "CoreGraphics metadata only",
                    "contentAccess": false,
                    "screenRecording": Capture.screenRecordingAllowed() ? "authorized" : "not-authorized",
                    "windows": try WindowCatalog.all().map(\.json),
                ])
            case .capture(let options):
                let config = try SelectionConfig.load(path: options.configPath)
                try emitJSON(await Capture.png(config: config, paths: options.paths))
            case .record(let options):
                let config = try SelectionConfig.load(path: options.configPath)
                try emitJSON(await Recorder.run(config: config, options: options))
            case .selfTest:
                try SelfTest.run()
            }
        } catch {
            emitFailure(error)
            Foundation.exit(1)
        }
    }
}
