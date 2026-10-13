import SwiftUI
import UniformTypeIdentifiers

struct DistributionView: View {
    @ObservedObject var uploader: PgyerUploader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 发布内容保留上一次填写的，下次只需修改。
    @AppStorage("pgyerUpdateDescription") private var updateDescription = ""
    @State private var installType: PgyerInstallType = .public
    @State private var password = ""
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var isEditingAPIKey = false

    var body: some View {
        Group {
            if uploader.hasAPIKey {
                content
            } else {
                APIKeySetup { uploader.saveAPIKey($0) }
            }
        }
        .navigationTitle("蒲公英分发")
        .navigationSubtitle(subtitle)
        .toolbar {
            if uploader.hasAPIKey {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isEditingAPIKey = true
                    } label: {
                        Label("API Key", systemImage: "key")
                    }
                    .help("更换 API Key")
                    .disabled(uploader.isUploading)
                }
            }
        }
        .sheet(isPresented: $isEditingAPIKey) {
            APIKeySheet { uploader.saveAPIKey($0) }
        }
        .toast($uploader.toastMessage)
        .alert("上传失败", isPresented: Binding(get: { uploader.errorMessage != nil }, set: { if !$0 { uploader.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(uploader.errorMessage ?? "")
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: PgyerService.supportedExtensions.compactMap { UTType(filenameExtension: $0) } + [.data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                select(url)
            }
        }
    }

    private var subtitle: String {
        switch uploader.phase {
        case .uploading(let fraction): return "正在上传 \(Int(fraction * 100))%"
        case .publishing: return "上传完成，正在发布…"
        case .idle: return uploader.hasAPIKey ? "上传安装包，生成下载链接和二维码" : "需要先填写 API Key"
        }
    }

    private var canUpload: Bool {
        uploader.fileURL != nil && !uploader.isUploading && !(installType == .password && password.isEmpty)
    }

    private var content: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                uploadCard
                if let build = uploader.lastBuild {
                    ResultCard(build: build, uploader: uploader)
                        .transition(.opacity)
                }
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: uploader.lastBuild)
        }
        .overlay {
            if isDropTargeted {
                dropOverlay
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { PgyerService.supportedExtensions.contains($0.pathExtension.lowercased()) }),
                  !uploader.isUploading else {
                return false
            }
            select(url)
            return true
        } isTargeted: { targeted in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy) {
                isDropTargeted = targeted
            }
        }
    }

    private func select(_ url: URL) {
        guard PgyerService.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            uploader.errorMessage = PgyerError.unsupportedFile(url.lastPathComponent).errorDescription
            return
        }
        uploader.fileURL = url
    }

    // MARK: - 上传

    private var uploadCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("上传安装包", systemImage: "paperplane.fill")
                inputs
                Divider()
                actionRow
            }
        }
    }

    /// 上传过程中锁定输入；取消按钮在外面，保持可点。
    private var inputs: some View {
        VStack(alignment: .leading, spacing: 14) {
            fileRow

            VStack(alignment: .leading, spacing: 6) {
                Text("发布内容")
                    .font(.callout.weight(.medium))
                TextEditor(text: $updateDescription)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 96)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if updateDescription.isEmpty {
                            Text("本次更新了什么，测试人员会在下载页看到")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
            }

            DisclosureGroup("高级选项") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("安装方式", selection: $installType) {
                        ForEach(PgyerInstallType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    if installType == .password {
                        SecureField("安装密码", text: $password)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .padding(.top, 8)
            }
        }
        .disabled(uploader.isUploading)
    }

    @ViewBuilder
    private var fileRow: some View {
        if let url = uploader.fileURL {
            HStack(spacing: 12) {
                IconTile(systemImage: "shippingbox.fill", tint: .green, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(fileSize(url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("更换…") { isImporting = true }
            }
        } else {
            Button {
                isImporting = true
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("选择或拖入 APK / IPA / HAP")
                        .font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity, minHeight: 84)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            switch uploader.phase {
            case .uploading(let fraction):
                ProgressView(value: fraction)
                Text("\(Int(fraction * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            case .publishing:
                ProgressView().controlSize(.small)
                Text("正在发布，通常 1 分钟内完成…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .idle:
                Text(installType == .public ? "任何人都可以通过链接安装" : "\(installType.title)：需要\(installType == .password ? "密码" : "邀请")才能安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if uploader.isUploading {
                Button("取消", role: .cancel) { uploader.cancel() }
            } else {
                Button("上传并发布") {
                    uploader.upload(options: .init(
                        updateDescription: updateDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                        installType: installType,
                        password: password
                    ))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canUpload)
            }
        }
        .frame(minHeight: 28)
    }

    private func fileSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay {
                Label("松开以选择安装包", systemImage: "square.and.arrow.up")
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .padding(10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

// MARK: - 发布结果

private struct ResultCard: View {
    let build: PgyerBuild
    @ObservedObject var uploader: PgyerUploader

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("最近发布", systemImage: "checkmark.seal.fill")
                HStack(alignment: .top, spacing: 16) {
                    AsyncImage(url: build.qrCodeURL) { image in
                        image.resizable().interpolation(.none).scaledToFit()
                    } placeholder: {
                        ProgressView().controlSize(.small)
                    }
                    .frame(width: 120, height: 120)
                    .padding(6)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(build.buildName ?? "应用")
                            .font(.title3.weight(.semibold))
                        if let version = build.buildVersion {
                            Text(build.buildVersionNo.map { "版本 \(version)（\($0)）" } ?? "版本 \(version)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let url = build.shortcutURL {
                            Text(url.absoluteString)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        HStack(spacing: 8) {
                            Button("复制链接") { uploader.copyLink() }
                            Button("在浏览器打开") { uploader.openLink() }
                        }
                    }
                }
                Text("用手机扫码即可下载安装")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - API Key

private struct APIKeySetup: View {
    let onSave: (String) -> Void
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 18) {
            IconTile(systemImage: "key.fill", tint: .blue, size: 52)
            VStack(spacing: 6) {
                Text("连接蒲公英")
                    .font(.title2.weight(.semibold))
                Text("填写一次 API Key 即可，它会保存在这台 Mac 的钥匙串中。")
                    .foregroundStyle(.secondary)
            }
            HStack {
                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onSave(apiKey) }
                Button("保存") { onSave(apiKey) }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 380)
            Link("在蒲公英后台获取 API Key", destination: PgyerService.apiKeyPageURL)
                .font(.callout)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct APIKeySheet: View {
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("更换 API Key")
                .font(.title2.weight(.semibold))
            Text("新的 Key 会替换钥匙串中保存的旧 Key。")
                .foregroundStyle(.secondary)
            SecureField("API Key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            HStack {
                Link("在蒲公英后台获取", destination: PgyerService.apiKeyPageURL)
                    .font(.callout)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(apiKey)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
