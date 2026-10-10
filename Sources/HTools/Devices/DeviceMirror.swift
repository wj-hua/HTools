import AppKit
import AVFoundation
import SwiftUI

/// 页面内嵌的手机投屏。
///
/// - Android：`adb exec-out screenrecord` 输出 H.264 字节流，用系统硬解直接显示（实时），
///   并支持点击 / 拖动 / 返回 / 主页 / 最近任务；
/// - HarmonyOS：HDC 没有视频流，只能连续截图，所以是只读预览。
@MainActor
final class DeviceMirror: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var deviceSize: CGSize?
    @Published private(set) var hdcImage: NSImage?
    private(set) var device: ADBDevice?

    let displayLayer = AVSampleBufferDisplayLayer()

    private weak var adb: ADBService?
    private var task: Task<Void, Never>?
    private var process: Process?
    private var decoder: H264Decoder?

    private static let remotePIDFile = "/data/local/tmp/htools-mirror.pid"

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    var isActive: Bool { phase != .idle }
    var isControllable: Bool { device?.bridge == .adb }

    // MARK: - 启停

    func start(device: ADBDevice, adb: ADBService) {
        stop()
        self.device = device
        self.adb = adb
        phase = .connecting
        deviceSize = nil
        hdcImage = nil

        if device.bridge == .adb {
            decoder = H264Decoder(layer: displayLayer) { [weak self] in
                Task { @MainActor in
                    guard let self, self.phase == .connecting else { return }
                    self.phase = .streaming
                }
            }
            task = Task { [weak self] in await self?.streamAndroid(device: device, adb: adb) }
        } else {
            task = Task { [weak self] in await self?.pollHarmony(device: device, adb: adb) }
        }
    }

    func stop() {
        let wasAndroidStreaming = device?.bridge == .adb && isActive
        let serial = device?.serial
        task?.cancel()
        task = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        decoder?.reset()
        decoder = nil
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        hdcImage = nil
        phase = .idle
        device = nil

        // 静止画面时 screenrecord 不会因为管道关闭而退出，需要主动结束，
        // 否则它会一直占着设备的编码器（影响之后的录屏）。
        if wasAndroidStreaming, let serial, let adb {
            let pidFile = Self.remotePIDFile
            Task {
                _ = await adb.runADB(["-s", serial, "shell", "kill -2 $(cat \(pidFile)) 2>/dev/null; rm -f \(pidFile)"])
            }
        }
    }

    private func fail(_ message: String) {
        guard isActive else { return }
        phase = .failed(message)
    }

    // MARK: - Android

    private func streamAndroid(device: ADBDevice, adb: ADBService) async {
        guard let adbURL = adb.adbExecutable else {
            fail("未找到 adb。")
            return
        }
        let sizeOutput = await adb.runADB(["-s", device.serial, "shell", "wm", "size"]).stdoutText
        let nativeSize = Self.parseSize(sizeOutput) ?? CGSize(width: 1080, height: 1920)
        deviceSize = nativeSize
        let encodeSize = Self.encodeSize(for: nativeSize)

        // screenrecord 单次最长 3 分钟，到点会自行退出，这里无缝重启。
        while !Task.isCancelled {
            let startedAt = Date()
            decoder?.reset()
            let errorOutput = await runStream(adbURL: adbURL, serial: device.serial, size: encodeSize)
            if Task.isCancelled { return }
            if Date().timeIntervalSince(startedAt) < 2 {
                let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                fail(detail.isEmpty ? "投屏已中断，请确认手机已解锁并允许 USB 调试。" : detail)
                return
            }
        }
    }

    private func runStream(adbURL: URL, serial: String, size: CGSize) async -> String {
        let process = Process()
        process.executableURL = adbURL
        // 先把 shell 自己的 PID 写到设备上再 exec，停止时才能精确结束这一路 screenrecord，
        // 而不会误伤用户正在进行的录屏。
        let remoteCommand = "echo $$ > \(Self.remotePIDFile); exec screenrecord --output-format=h264 "
            + "--size=\(Int(size.width))x\(Int(size.height)) --bit-rate=8000000 -"
        process.arguments = ["-s", serial, "exec-out", remoteCommand]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let decoder = self.decoder
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                decoder?.feed(data)
            }
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    output.fileHandleForReading.readabilityHandler = nil
                    let message = String(
                        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
                        as: UTF8.self
                    )
                    continuation.resume(returning: message)
                }
                do {
                    try process.run()
                    self.process = process
                } catch {
                    continuation.resume(returning: error.localizedDescription)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// 编码尺寸：长边不超过 1600，宽高取 8 的倍数（多数硬件编码器的对齐要求）。
    private static func encodeSize(for native: CGSize) -> CGSize {
        let scale = min(1, 1600 / max(native.width, native.height))
        func aligned(_ value: CGFloat) -> CGFloat { max(8, (value * scale / 8).rounded() * 8) }
        return CGSize(width: aligned(native.width), height: aligned(native.height))
    }

    private static func parseSize(_ output: String) -> CGSize? {
        // 有 Override size 时以它为准（用户改过分辨率）。
        for key in ["Override size:", "Physical size:"] {
            guard let line = output.split(separator: "\n").first(where: { $0.contains(key) }),
                  let value = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { continue }
            let parts = value.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return CGSize(width: parts[0], height: parts[1]) }
        }
        return nil
    }

    // MARK: - HarmonyOS

    private func pollHarmony(device: ADBDevice, adb: ADBService) async {
        var failures = 0
        while !Task.isCancelled {
            do {
                let data = try await adb.screenshot(for: device)
                try Task.checkCancellation()
                guard let image = NSImage(data: data) else {
                    throw ADBBarError.commandFailed("鸿蒙设备返回了无法识别的画面。")
                }
                hdcImage = image
                if deviceSize != image.size { deviceSize = image.size }
                phase = .streaming
                failures = 0
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                if failures >= 3 {
                    fail(error.localizedDescription)
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: - Android 控制

    /// `point` 是在画面内的归一化坐标（0...1）。
    func tap(at point: CGPoint) {
        guard let (serial, x, y) = devicePoint(point) else { return }
        runInput(serial, ["tap", "\(x)", "\(y)"])
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        guard let (serial, x1, y1) = devicePoint(start), let (_, x2, y2) = devicePoint(end) else { return }
        let milliseconds = Int(min(max(duration, 0.08), 1.0) * 1000)
        runInput(serial, ["swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "\(milliseconds)"])
    }

    func pressKey(_ keyCode: Int) {
        guard let serial = device?.serial, isControllable else { return }
        runInput(serial, ["keyevent", "\(keyCode)"])
    }

    private func devicePoint(_ point: CGPoint) -> (String, Int, Int)? {
        guard isControllable, let serial = device?.serial, let size = deviceSize else { return nil }
        let x = Int((min(max(point.x, 0), 1) * size.width).rounded())
        let y = Int((min(max(point.y, 0), 1) * size.height).rounded())
        return (serial, x, y)
    }

    private func runInput(_ serial: String, _ arguments: [String]) {
        guard let adb else { return }
        Task { _ = await adb.runADB(["-s", serial, "shell", "input"] + arguments) }
    }
}

/// 把共享的 `AVSampleBufferDisplayLayer` 放进 SwiftUI。
struct MirrorSurface: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> LayerHostView {
        LayerHostView(videoLayer: layer)
    }

    func updateNSView(_ nsView: LayerHostView, context: Context) {}

    final class LayerHostView: NSView {
        private let videoLayer: AVSampleBufferDisplayLayer

        init(videoLayer: AVSampleBufferDisplayLayer) {
            self.videoLayer = videoLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.addSublayer(videoLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            videoLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
