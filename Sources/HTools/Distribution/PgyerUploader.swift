import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 蒲公英上传状态与历史记录管理。
@MainActor
final class PgyerUploader: ObservableObject {
    enum Phase: Equatable {
        case idle
        case uploading(PgyerUploadProgress)
        case publishing
    }

    @Published private(set) var hasAPIKey = PgyerKeychain.load() != nil
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastBuild: PgyerBuild?
    @Published private(set) var recentBuilds: [PgyerBuild] = []
    @Published var fileURL: URL?
    @Published var errorMessage: String?
    @Published var toastMessage: String?

    private var uploadTask: Task<Void, Never>?
    private let recentBuildsKey = "HTools.pgyer.recentBuilds"
    private let maxRecentCount = 15

    var isUploading: Bool { phase != .idle }

    init() {
        loadRecentBuilds()
    }

    // MARK: - API Key

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

    func removeAPIKey() {
        if PgyerKeychain.delete() {
            hasAPIKey = false
            toastMessage = "API Key 已清除"
        } else {
            hasAPIKey = PgyerKeychain.load() != nil
        }
    }

    // MARK: - 上传

    func upload(options: PgyerService.Options) {
        guard !isUploading, let fileURL else { return }
        guard let apiKey = PgyerKeychain.load() else {
            hasAPIKey = false
            return
        }

        phase = .uploading(.init(fraction: 0, bytesSent: 0, totalBytes: 0))
        uploadTask = Task {
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            do {
                let build = try await PgyerService.upload(fileURL: fileURL, apiKey: apiKey, options: options) { progress in
                    Task { @MainActor [weak self] in self?.updateProgress(progress) }
                }

                var finalBuild = build
                finalBuild.uploadedAt = Date()
                finalBuild.localInstallType = options.installType.rawValue
                finalBuild.localPassword = options.installType == .password ? options.password : nil
                finalBuild.localUpdateDescription = options.updateDescription
                finalBuild.localFileName = fileURL.lastPathComponent
                finalBuild.localFileSizeBytes = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

                self.lastBuild = finalBuild
                self.recordRecentBuild(finalBuild)
                self.fileURL = nil
                self.toastMessage = "发布成功"
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
        phase = .idle
    }

    // MARK: - 分享与辅助操作

    func copyLink(for target: PgyerBuild? = nil) {
        guard let url = (target ?? lastBuild)?.downloadURL else { return }
        if Pasteboard.copy(url.absoluteString) {
            toastMessage = "固定长链接已复制"
        }
    }

    func copyShortcutLink(for target: PgyerBuild? = nil) {
        guard let url = (target ?? lastBuild)?.shortcutURL else { return }
        if Pasteboard.copy(url.absoluteString) {
            toastMessage = "短链接已复制"
        }
    }

    func openLink(for target: PgyerBuild? = nil) {
        guard let url = (target ?? lastBuild)?.downloadURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyShareText(for target: PgyerBuild? = nil) {
        guard let b = target ?? lastBuild else { return }
        var lines: [String] = []
        let appTitle = b.buildName ?? "应用"
        lines.append("【\(appTitle)】最新测试版本已发布")

        var versionParts: [String] = []
        if let v = b.buildVersion, !v.isEmpty { versionParts.append("v\(v)") }
        if let no = b.buildVersionNo, !no.isEmpty { versionParts.append("Build \(no)") }
        if !versionParts.isEmpty {
            lines.append("版本：\(versionParts.joined(separator: " "))")
        }

        if let url = b.downloadURL {
            lines.append("下载链接：\(url.absoluteString)")
        }

        if let pwd = b.localPassword, !pwd.isEmpty {
            lines.append("安装密码：\(pwd)")
        } else if let it = b.localInstallType, it == PgyerInstallType.invite.rawValue {
            lines.append("安装方式：邀请安装（需管理员授权）")
        }

        if let desc = b.localUpdateDescription, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("更新说明：\n\(desc)")
        }

        let text = lines.joined(separator: "\n")
        if Pasteboard.copy(text) {
            toastMessage = "分享文案已复制"
        }
    }

    func copyQRCodeImage(for target: PgyerBuild? = nil) {
        guard let b = target ?? lastBuild, let url = b.qrCodeURL else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = NSImage(data: data) else {
                    errorMessage = "无法解析二维码图片"
                    return
                }
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setData(data, forType: .png)
                pasteboard.writeObjects([image])
                toastMessage = "二维码图片已复制"
            } catch {
                errorMessage = "下载二维码失败：\(error.localizedDescription)"
            }
        }
    }

    func saveQRCodeImage(for target: PgyerBuild? = nil) {
        guard let b = target ?? lastBuild, let url = b.qrCodeURL else { return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [UTType.png]
                let safeName = (b.buildName ?? "Pgyer").replacingOccurrences(of: "/", with: "-")
                panel.nameFieldStringValue = "\(safeName)_二维码.png"
                panel.prompt = "保存"
                if panel.runModal() == .OK, let destinationURL = panel.url {
                    try data.write(to: destinationURL)
                    toastMessage = "二维码已保存至文件"
                }
            } catch {
                errorMessage = "保存二维码失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 历史记录

    func deleteRecentBuild(id: String) {
        recentBuilds.removeAll { $0.id == id }
        if lastBuild?.id == id {
            lastBuild = recentBuilds.first
        }
        persistRecentBuilds()
    }

    func clearRecentBuilds() {
        recentBuilds.removeAll()
        persistRecentBuilds()
    }

    private func recordRecentBuild(_ build: PgyerBuild) {
        recentBuilds.removeAll { $0.id == build.id }
        recentBuilds.insert(build, at: 0)
        if recentBuilds.count > maxRecentCount {
            recentBuilds = Array(recentBuilds.prefix(maxRecentCount))
        }
        persistRecentBuilds()
    }

    private func loadRecentBuilds() {
        guard let data = UserDefaults.standard.data(forKey: recentBuildsKey),
              let builds = try? JSONDecoder().decode([PgyerBuild].self, from: data) else {
            return
        }
        recentBuilds = builds
        if lastBuild == nil {
            lastBuild = builds.first
        }
    }

    private func persistRecentBuilds() {
        if let data = try? JSONEncoder().encode(recentBuilds) {
            UserDefaults.standard.set(data, forKey: recentBuildsKey)
        }
    }

    // MARK: - 进度更新

    private func updateProgress(_ progress: PgyerUploadProgress) {
        guard case .uploading(let current) = phase else { return }
        if progress.fraction >= 1 {
            phase = .publishing
        } else if (progress.fraction * 100).rounded() != (current.fraction * 100).rounded() || progress.bytesSent != current.bytesSent {
            phase = .uploading(progress)
        }
    }
}
