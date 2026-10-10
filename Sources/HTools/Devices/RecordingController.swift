import Foundation

@MainActor
final class RecordingController {
    private let adb: ADBService
    private var process: Process?
    private var serial: String?
    private var remotePath: String?

    private(set) var isRecording = false

    init(adb: ADBService) {
        self.adb = adb
    }

    func start() async throws {
        guard !isRecording else { return }
        let context = try await adb.androidRecordingContext()
        let serial = context.serial
        let remotePath = "/sdcard/adbbar-recording-\(Int(Date().timeIntervalSince1970)).mp4"
        let process = Process()
        process.executableURL = context.executable
        process.arguments = [
            "-s", serial, "shell", "screenrecord", "--bit-rate", "8000000", remotePath
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        self.process = process
        self.serial = serial
        self.remotePath = remotePath
        isRecording = true
    }

    func stopAndSave(format: RecordingFormat) async throws -> URL {
        guard isRecording, let serial, let remotePath else {
            throw ADBBarError.recordingNotRunning
        }

        let interrupt = await adb.runADB(["-s", serial, "shell", "pkill", "-2", "screenrecord"])
        if interrupt.status != 0 {
            _ = await adb.runADB(["-s", serial, "shell", "killall", "-2", "screenrecord"])
        }
        try? await Task.sleep(for: .milliseconds(700))
        process?.interrupt()

        defer {
            process = nil
            self.serial = nil
            self.remotePath = nil
            isRecording = false
        }

        let fileName = "ADB录屏-\(timestamp())"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")

        switch format {
        case .mp4:
            let destination = uniqueURL(in: downloads, name: fileName, extension: "mp4")
            try await pull(remotePath: remotePath, serial: serial, destination: destination)
            _ = await adb.runADB(["-s", serial, "shell", "rm", remotePath])
            return destination
        case .gif:
            guard let ffmpeg = ToolLocator.ffmpeg() else {
                let destination = uniqueURL(in: downloads, name: fileName, extension: "mp4")
                try await pull(remotePath: remotePath, serial: serial, destination: destination)
                _ = await adb.runADB(["-s", serial, "shell", "rm", remotePath])
                return destination
            }
            let temporaryMP4 = FileManager.default.temporaryDirectory
                .appendingPathComponent("adbbar-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temporaryMP4) }
            try await pull(remotePath: remotePath, serial: serial, destination: temporaryMP4)
            _ = await adb.runADB(["-s", serial, "shell", "rm", remotePath])

            let destination = uniqueURL(in: downloads, name: fileName, extension: "gif")
            let conversion = await CommandRunner.run(
                executable: ffmpeg,
                arguments: [
                    "-y", "-i", temporaryMP4.path,
                    "-vf", "fps=12,scale='min(1080,iw)':-1:flags=lanczos",
                    destination.path
                ]
            )
            guard conversion.status == 0 else {
                throw ADBBarError.commandFailed(conversion.combinedText)
            }
            return destination
        }
    }

    private func pull(remotePath: String, serial: String, destination: URL) async throws {
        let result = await adb.runADB(["-s", serial, "pull", remotePath, destination.path])
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw ADBBarError.commandFailed(result.combinedText)
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func uniqueURL(in directory: URL, name: String, extension fileExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name)-\(suffix)").appendingPathExtension(fileExtension)
            suffix += 1
        }
        return candidate
    }
}
