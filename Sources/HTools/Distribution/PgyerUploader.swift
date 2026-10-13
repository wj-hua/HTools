import AppKit
import Combine

/// 蒲公英上传状态。放在 AppModel 里，切换页面时上传不会中断。
@MainActor
final class PgyerUploader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading(Double)
        case publishing
    }

    @Published private(set) var hasAPIKey = PgyerKeychain.load() != nil
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastBuild: PgyerBuild?
    @Published var fileURL: URL?
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    private var uploadTask: Task<Void, Never>?

    var isUploading: Bool { phase != .idle }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if PgyerKeychain.save(trimmed) {
            hasAPIKey = true
            toastMessage = "API Key 已保存"
        } else {
            errorMessage = "无法写入钥匙串，API Key 未保存。"
        }
    }

    func upload(options: PgyerService.Options) {
        guard !isUploading, let fileURL else { return }
        guard let apiKey = PgyerKeychain.load() else {
            hasAPIKey = false
            return
        }
        phase = .uploading(0)
        lastBuild = nil
        uploadTask = Task {
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let build = try await PgyerService.upload(fileURL: fileURL, apiKey: apiKey, options: options) { fraction in
                    Task { @MainActor [weak self] in self?.updateProgress(fraction) }
                }
                lastBuild = build
                self.fileURL = nil
                toastMessage = "发布成功"
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
            uploadTask = nil
        }
    }

    func cancel() {
        uploadTask?.cancel()
    }

    func copyLink() {
        guard let url = lastBuild?.shortcutURL else { return }
        if Pasteboard.copy(url.absoluteString) {
            toastMessage = "下载链接已复制"
        }
    }

    func openLink() {
        guard let url = lastBuild?.shortcutURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// 进度回调很密集，按 1% 取整后再刷新界面；上传完进入“发布中”。
    private func updateProgress(_ fraction: Double) {
        guard case .uploading(let current) = phase else { return }
        if fraction >= 1 {
            phase = .publishing
        } else if (fraction * 100).rounded() != (current * 100).rounded() {
            phase = .uploading(fraction)
        }
    }
}
