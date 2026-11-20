import Foundation

private func usage() -> Never {
    let text = "Usage: FesTermVMEvidenceInteraction --session <session.json> --artifact-root <directory>\n" +
        "       FesTermVMEvidenceInteraction --self-test\n"
    FileHandle.standardError.write(Data(text.utf8))
    exit(2)
}

private func readArgument(_ name: String, from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func emit(_ value: Any) {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    } catch {
        exit(70)
    }
}

private func emitEncodable(_ value: Encodable) {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0a]))
    } catch {
        exit(70)
    }
}

private func run() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--self-test"] {
        do {
            let synthetic = try StrictJSON.session(Data("""
            {"schema_version":1,"session_id":"self-test","platform":"macos","run_id":"self-test","target":{"pid":1},"grants":[],"limits":{"maximum_commands":1,"command_timeout_ms":100,"maximum_artifact_bytes":1,"maximum_video_seconds":1}}
            """.utf8))
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let driver = try InteractionDriver(session: synthetic, artifactRoot: root)
            emit(try driver.selfTest())
            return
        } catch {
            emit(["driver": "macos-gui-driver/1", "status": "fail",
                  "message": "self-test failed", "posted_input": false,
                  "inspected_applications": false])
            exit(1)
        }
    }
    guard arguments.count == 4,
          Set(arguments.filter { $0.hasPrefix("--") }) == Set(["--session", "--artifact-root"]),
          let sessionPath = readArgument("--session", from: arguments),
          let rootPath = readArgument("--artifact-root", from: arguments) else {
        usage()
    }
    let session: SessionDocument
    let driver: InteractionDriver
    do {
        let sessionURL = URL(fileURLWithPath: sessionPath, isDirectory: false)
        let attributes = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        guard ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 131_072 else {
            throw DriverError.invalid("session JSON exceeds the driver input bound")
        }
        let sessionData = try Data(contentsOf: sessionURL)
        session = try StrictJSON.session(sessionData)
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        driver = try InteractionDriver(session: session, artifactRoot: rootURL)
    } catch {
        FileHandle.standardError.write(Data("Invalid driver session or artifact root\n".utf8))
        exit(65)
    }

    let data = FileHandle.standardInput.readDataToEndOfFile()
    let bytes = Array(data)
    if bytes.count > 131_072 {
        emitEncodable(driver.failureResult(sequence: 1, operation: "invalid",
                                           message: "Command input exceeds 131072 bytes"))
        return
    }
    do {
        let command = try StrictJSON.command(data)
        emitEncodable(driver.handle(command))
    } catch let error as DriverError {
        let fallbackSequence = extractIntegerField("sequence", from: data) ?? 1
        let fallbackOperation = extractStringField("operation", from: data) ?? "invalid"
        emitEncodable(driver.failureResult(sequence: fallbackSequence,
                                           operation: fallbackOperation,
                                           message: error.message))
    } catch {
        emitEncodable(driver.failureResult(sequence: 1, operation: "invalid",
                                           message: "Command could not be decoded"))
    }
}

private func extractIntegerField(_ field: String, from data: Data) -> Int? {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let number = value[field] as? NSNumber else { return nil }
    return number.intValue
}

private func extractStringField(_ field: String, from data: Data) -> String? {
    guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let operations = Set(["capabilities", "observe", "focus", "key", "text", "move",
                          "click", "double-click", "drag", "scroll", "wait", "screenshot",
                          "clipboard-set-sentinel", "video-start", "video-stop"])
    guard let operation = value[field] as? String, operations.contains(operation) else { return nil }
    return operation
}

run()
