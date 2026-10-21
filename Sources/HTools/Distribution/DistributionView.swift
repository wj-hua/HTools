import SwiftUI
import UniformTypeIdentifiers

struct DistributionView: View {
    @ObservedObject var uploader: PgyerUploader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 发布内容保留上一次填写的，方便下次连续发版时微调。
    @AppStorage("pgyerUpdateDescription") private var updateDescription = ""
    @State private var installType: PgyerInstallType = .public
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isImporting = false
    @State private var isDropTargeted = false
    @State private var isHoveringFileZone = false
    @State private var isEditingAPIKey = false
    @State private var isConfirmingClearHistory = false
    @State private var popoverQRBuildID: String?

    var body: some View {
        Group {
            if uploader.hasAPIKey {
                mainContent
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
                        HStack(spacing: 5) {
                            Image(systemName: "key.fill")
                                .foregroundStyle(.blue)
                            Text("API Key")
                        }
                    }
                    .help("更换或清除蒲公英 API Key")
                    .disabled(uploader.isUploading)
                }
            }
        }
        .sheet(isPresented: $isEditingAPIKey) {
            APIKeySheet(
                onSave: { uploader.saveAPIKey($0) },
                onRemove: { uploader.removeAPIKey() }
            )
        }
        .toast($uploader.toastMessage)
        .alert("上传失败", isPresented: Binding(get: { uploader.errorMessage != nil }, set: { if !$0 { uploader.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(uploader.errorMessage ?? "")
        }
        .confirmationDialog("确定清空全部历史发布记录？", isPresented: $isConfirmingClearHistory) {
            Button("清空历史记录", role: .destructive) {
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard) {
                    uploader.clearRecentBuilds()
                }
            }
        } message: {
            Text("历史记录仅保存在本机，清空后不会影响蒲公英后台已发布的应用。")
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
        case .uploading(let progress):
            return "正在上传 \(progress.formattedSent) / \(progress.formattedTotal) (\(Int(progress.fraction * 100))%)"
        case .publishing:
            return "上传完成，蒲公英正在云端解析与发布…"
        case .idle:
            return uploader.hasAPIKey ? "支持 APK、IPA、HAP 安装包快速托管与多端扫码安装" : "需要先填写 API Key"
        }
    }

    private var canUpload: Bool {
        uploader.fileURL != nil && !uploader.isUploading && !(installType == .password && password.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    // MARK: - 主内容视图

    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                uploadCard

                if let build = uploader.lastBuild {
                    LatestBuildCard(
                        build: build,
                        uploader: uploader
                    )
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }

                if !uploader.recentBuilds.isEmpty {
                    RecentBuildsCard(
                        builds: uploader.recentBuilds,
                        popoverBuildID: $popoverQRBuildID,
                        uploader: uploader,
                        onClear: { isConfirmingClearHistory = true }
                    )
                }
            }
            .padding(20)
            .frame(maxWidth: 960)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: uploader.lastBuild)
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard, value: uploader.recentBuilds.count)
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
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy) {
            uploader.fileURL = url
        }
    }

    // MARK: - 上传卡片

    private var uploadCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader("上传安装包", systemImage: "paperplane.fill") {
                    HStack(spacing: 5) {
                        FormatPill(title: "APK", color: .green)
                        FormatPill(title: "IPA", color: .blue)
                        FormatPill(title: "HAP", color: .orange)
                    }
                }

                fileSelectionSection

                Divider()

                updateDescriptionSection

                Divider()

                installSettingsSection

                Divider()

                actionSection
            }
        }
    }

    // MARK: - 安装包选择区

    @ViewBuilder
    private var fileSelectionSection: some View {
        if let url = uploader.fileURL {
            let platform = AppPlatform.from(pathExtension: url.pathExtension)
            HStack(spacing: 14) {
                IconTile(systemImage: platform.systemImage, tint: platform.badgeColor, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(url.lastPathComponent)
                            .font(.system(.headline, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(platform.title)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(platform.badgeColor.opacity(0.14), in: Capsule())
                            .foregroundStyle(platform.badgeColor)
                    }

                    HStack(spacing: 8) {
                        Text(fileSize(url))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        Text("·")
                            .foregroundStyle(.tertiary)

                        Text(url.deletingLastPathComponent().path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    Button("更换…") { isImporting = true }
                        .buttonStyle(.bordered)
                        .disabled(uploader.isUploading)

                    Button {
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy) {
                            uploader.fileURL = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("取消选择此文件")
                    .disabled(uploader.isUploading)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
        } else {
            Button {
                isImporting = true
            } label: {
                VStack(spacing: 10) {
                    IconTile(systemImage: "arrow.up.doc.fill", tint: .accentColor, size: 44)

                    VStack(spacing: 4) {
                        Text("点击选择或将安装包拖拽至此处")
                            .font(.headline)
                        Text("支持 Android (.apk)、iOS (.ipa)、鸿蒙 (.hap)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("浏览文件…") { isImporting = true }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isHoveringFileZone ? Color.accentColor.opacity(0.04) : Color.secondary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            isHoveringFileZone ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle(scale: 0.99))
            .onHover { isHoveringFileZone = $0 }
        }
    }

    // MARK: - 发布说明区

    private var updateDescriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("更新说明", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                if !updateDescription.isEmpty {
                    Button("清空") {
                        updateDescription = ""
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .disabled(uploader.isUploading)
                }

                Text("\(updateDescription.count) 字")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            ZStack(alignment: .topLeading) {
                if updateDescription.isEmpty {
                    Text("记录本次版本的更新功能或 Bug 修复（测试人员将在下载页面查阅）…")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $updateDescription)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 80)
                    .padding(6)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
            )
            .disabled(uploader.isUploading)
        }
    }

    // MARK: - 安装选项区

    private var installSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("安装方式", systemImage: "lock.shield")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Picker("", selection: $installType) {
                    ForEach(PgyerInstallType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(uploader.isUploading)
            }

            if installType == .password {
                HStack(spacing: 8) {
                    HStack {
                        if isPasswordVisible {
                            TextField("设置安装密码 (4-16 位)", text: $password)
                                .textFieldStyle(.plain)
                        } else {
                            SecureField("设置安装密码 (4-16 位)", text: $password)
                                .textFieldStyle(.plain)
                        }

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isPasswordVisible ? "隐藏密码" : "显示密码")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                    )

                    Button("随机 6 位 PIN") {
                        password = String(format: "%06d", Int.random(in: 100000...999999))
                    }
                    .buttonStyle(.bordered)
                    .help("生成 6 位易于输入的纯数字密码")

                    if !password.isEmpty {
                        Button {
                            password = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .disabled(uploader.isUploading)

                Text("测试人员扫码后必须输入此密码才能下载与安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installType == .public {
                Text("任何人扫描二维码或访问链接均可直接下载安装。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if installType == .invite {
                Text("只有已被管理员邀请加入项目的团队成员方可下载。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.snappy, value: installType)
    }

    // MARK: - 动作与进度区

    @ViewBuilder
    private var actionSection: some View {
        switch uploader.phase {
        case .uploading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("步骤 1/2：正在上传安装包…", systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)

                    Spacer()

                    Text("\(progress.formattedSent) / \(progress.formattedTotal) · \(Int(progress.fraction * 100))%")
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: progress.fraction)
                    .tint(.accentColor)

                HStack {
                    Text("直传至蒲公英云端对象存储")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("取消上传", role: .cancel) {
                        uploader.cancel()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, 4)

        case .publishing:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("步骤 2/2：上传完成，蒲公英正在云端解析与发布…")
                        .font(.headline)
                        .foregroundStyle(.orange)

                    Spacer()

                    Button("取消", role: .cancel) {
                        uploader.cancel()
                    }
                    .buttonStyle(.bordered)
                }

                Text("正在提取安装包图标、签名、版本号及生成安装描述文件，通常 10~30 秒内完成。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .idle:
            HStack(spacing: 12) {
                if uploader.fileURL == nil {
                    Text("请先选择或拖入需要分发的安装包")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if installType == .password && password.trimmingCharacters(in: .whitespaces).isEmpty {
                    Label("密码安装模式需要设置安装密码", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    Label(
                        installType == .public ? "公开安装模式" : installType.title,
                        systemImage: installType == .public ? "globe" : "lock.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    startUpload()
                } label: {
                    Label("上传并发布", systemImage: "arrow.up.circle.fill")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(!canUpload)
            }
            .frame(minHeight: 32)
        }
    }

    private func startUpload() {
        uploader.upload(options: .init(
            updateDescription: updateDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            installType: installType,
            password: password.trimmingCharacters(in: .whitespaces)
        ))
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

// MARK: - 格式徽章

private struct FormatPill: View {
    let title: String
    let color: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 最新发布卡片

private struct LatestBuildCard: View {
    let build: PgyerBuild
    @ObservedObject var uploader: PgyerUploader

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader("最新发布", systemImage: "checkmark.seal.fill") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 7, height: 7)
                        Text(relativeTime(build.uploadedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    // 二维码区域
                    VStack(spacing: 8) {
                        AsyncImage(url: build.qrCodeURL) { image in
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                        } placeholder: {
                            ProgressView().controlSize(.small)
                        }
                        .frame(width: 130, height: 130)
                        .padding(8)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                        .contextMenu {
                            Button("复制二维码图片") { uploader.copyQRCodeImage(for: build) }
                            Button("保存二维码…") { uploader.saveQRCodeImage(for: build) }
                            Divider()
                            Button("复制下载链接") { uploader.copyLink(for: build) }
                            Button("在浏览器打开") { uploader.openLink(for: build) }
                        }

                        Text("手机扫码直接安装")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // 信息与操作区
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            if let iconURL = build.iconURL {
                                AsyncImage(url: iconURL) { image in
                                    image
                                        .resizable()
                                        .scaledToFit()
                                } placeholder: {
                                    IconTile(systemImage: build.platform.systemImage, tint: build.platform.badgeColor, size: 40)
                                }
                                .frame(width: 40, height: 40)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                                )
                            } else {
                                IconTile(systemImage: build.platform.systemImage, tint: build.platform.badgeColor, size: 40)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(build.buildName ?? "未知应用")
                                    .font(.title3.weight(.bold))

                                HStack(spacing: 6) {
                                    Text(build.platform.title)
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(build.platform.badgeColor)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(build.platform.badgeColor.opacity(0.12), in: Capsule())

                                    Text(build.displayVersion)
                                        .font(.caption2.weight(.medium))
                                        .monospacedDigit()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())

                                    Text(build.installTypeDescription)
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())
                                }
                            }
                        }

                        // 下载链接行（固定长链接）
                        if let url = build.downloadURL {
                            HStack(spacing: 6) {
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(url.absoluteString)
                                    .font(.system(.callout, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                Spacer()

                                Button("复制") {
                                    uploader.copyLink(for: build)
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }

                        // 密码提示
                        if let password = build.localPassword, !password.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "key.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                Text("安装密码：\(password)")
                                    .font(.system(.callout, design: .rounded).weight(.semibold))
                                    .monospacedDigit()

                                Button("复制密码") {
                                    Pasteboard.copy(password)
                                    uploader.toastMessage = "安装密码已复制"
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }

                        Spacer(minLength: 4)

                        // 快捷操作按钮
                        HStack(spacing: 8) {
                            Button {
                                uploader.copyLink(for: build)
                            } label: {
                                Label("复制链接", systemImage: "link")
                            }
                            .buttonStyle(PressableButtonStyle())

                            Button {
                                uploader.copyShareText(for: build)
                            } label: {
                                Label("复制文案", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(PressableButtonStyle())
                            .help("生成适合直接发送到微信/飞书/钉钉的完整发布说明")

                            Button {
                                uploader.copyQRCodeImage(for: build)
                            } label: {
                                Label("复制二维码", systemImage: "qrcode")
                            }
                            .buttonStyle(PressableButtonStyle())
                            .help("将二维码图片复制到剪贴板")

                            Button {
                                uploader.openLink(for: build)
                            } label: {
                                Label("在浏览器打开", systemImage: "safari")
                            }
                            .buttonStyle(PressableButtonStyle())

                            Menu {
                                if let shortURL = build.shortcutURL {
                                    Button("复制应用短链接 (\(shortURL.lastPathComponent))") {
                                        uploader.copyShortcutLink(for: build)
                                    }
                                }
                                Button("保存二维码图片…") { uploader.saveQRCodeImage(for: build) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 24)
                        }
                    }
                }

                Divider()

                // 指标行
                HStack(spacing: 20) {
                    MetricCell(label: "安装方式", value: build.installTypeDescription, tint: build.localInstallType == 2 ? .orange : .green)
                    MetricCell(label: "安装包大小", value: build.formattedFileSize)
                    MetricCell(label: "发布时间", value: formattedDateTime(build.uploadedAt))
                }

                if let desc = build.localUpdateDescription, !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("更新内容")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)

                        Text(desc)
                            .font(.callout)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }

    private func relativeTime(_ date: Date?) -> String {
        guard let date else { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formattedDateTime(_ date: Date?) -> String {
        guard let date else { return "未知时间" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 历史发布记录卡片

private struct RecentBuildsCard: View {
    let builds: [PgyerBuild]
    @Binding var popoverBuildID: String?
    @ObservedObject var uploader: PgyerUploader
    let onClear: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("历史发布记录", systemImage: "clock.arrow.circlepath") {
                    HStack(spacing: 8) {
                        Text("\(builds.count) 个版本")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Button("清空", role: .destructive, action: onClear)
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(builds) { build in
                        RecentBuildRow(
                            build: build,
                            isPopoverPresented: Binding(
                                get: { popoverBuildID == build.id },
                                set: { if $0 { popoverBuildID = build.id } else if popoverBuildID == build.id { popoverBuildID = nil } }
                            ),
                            uploader: uploader
                        )
                    }
                }
            }
        }
    }
}

private struct RecentBuildRow: View {
    let build: PgyerBuild
    @Binding var isPopoverPresented: Bool
    @ObservedObject var uploader: PgyerUploader
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: build.platform.systemImage, tint: build.platform.badgeColor, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(build.buildName ?? "应用")
                        .font(.callout.weight(.semibold))

                    Text(build.displayVersion)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)

                    if let pwd = build.localPassword, !pwd.isEmpty {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("密码：\(pwd)")
                    }
                }

                HStack(spacing: 6) {
                    Text(timeAgo(build.uploadedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Text(build.formattedFileSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let url = build.downloadURL {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(url.absoluteString)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    isPopoverPresented = true
                } label: {
                    Image(systemName: "qrcode")
                        .font(.subheadline)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.94))
                .help("查看二维码")
                .popover(isPresented: $isPopoverPresented) {
                    PopoverQRCodeView(build: build, uploader: uploader)
                }

                Button("复制链接") {
                    uploader.copyLink(for: build)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))
                .controlSize(.small)

                Button("打开") {
                    uploader.openLink(for: build)
                }
                .buttonStyle(PressableButtonStyle(scale: 0.96))
                .controlSize(.small)

                Menu {
                    Button("复制分享文案") { uploader.copyShareText(for: build) }
                    Button("复制二维码图片") { uploader.copyQRCodeImage(for: build) }
                    Button("保存二维码…") { uploader.saveQRCodeImage(for: build) }
                    if let shortURL = build.shortcutURL {
                        Button("复制应用短链接 (\(shortURL.lastPathComponent))") {
                            uploader.copyShortcutLink(for: build)
                        }
                    }
                    Divider()
                    Button("删除记录", role: .destructive) {
                        uploader.deleteRecentBuild(id: build.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.secondary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private func timeAgo(_ date: Date?) -> String {
        guard let date else { return "未知时间" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct PopoverQRCodeView: View {
    let build: PgyerBuild
    @ObservedObject var uploader: PgyerUploader

    var body: some View {
        VStack(spacing: 12) {
            AsyncImage(url: build.qrCodeURL) { image in
                image
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } placeholder: {
                ProgressView().controlSize(.small)
            }
            .frame(width: 140, height: 140)
            .padding(6)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(spacing: 2) {
                Text(build.buildName ?? "应用")
                    .font(.headline)
                Text(build.displayVersion)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let pwd = build.localPassword, !pwd.isEmpty {
                    Text("安装密码：\(pwd)")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                Button("复制链接") { uploader.copyLink(for: build) }
                Button("复制二维码") { uploader.copyQRCodeImage(for: build) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 200)
    }
}

// MARK: - API Key 引导页与弹窗

private struct APIKeySetup: View {
    let onSave: (String) -> Void
    @State private var apiKey = ""
    @State private var isKeyVisible = false

    var body: some View {
        VStack(spacing: 20) {
            IconTile(systemImage: "key.fill", tint: .blue, size: 56)

            VStack(spacing: 6) {
                Text("连接蒲公英分发")
                    .font(.title2.weight(.bold))
                Text("输入一次 API Key 即可，它将安全存储于系统钥匙串 (Keychain) 中。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                HStack {
                    if isKeyVisible {
                        TextField("填写蒲公英 API Key", text: $apiKey)
                            .textFieldStyle(.plain)
                    } else {
                        SecureField("填写蒲公英 API Key", text: $apiKey)
                            .textFieldStyle(.plain)
                    }

                    Button {
                        isKeyVisible.toggle()
                    } label: {
                        Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
                )

                Button {
                    onSave(apiKey)
                } label: {
                    Text("保存并开始使用")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 380)

            Link("在蒲公英后台获取 API Key ↗", destination: PgyerService.apiKeyPageURL)
                .font(.callout)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct APIKeySheet: View {
    let onSave: (String) -> Void
    let onRemove: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isKeyVisible = false
    @State private var isConfirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("配置 API Key")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("新的 Key 将替换钥匙串中保存的旧凭证。")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                if isKeyVisible {
                    TextField("输入新的 API Key", text: $apiKey)
                        .textFieldStyle(.plain)
                } else {
                    SecureField("输入新的 API Key", text: $apiKey)
                        .textFieldStyle(.plain)
                }

                Button {
                    isKeyVisible.toggle()
                } label: {
                    Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.8), lineWidth: 0.5)
            )

            HStack {
                Link("在蒲公英后台获取 ↗", destination: PgyerService.apiKeyPageURL)
                    .font(.callout)

                Spacer()

                Button("清除 Key", role: .destructive) {
                    isConfirmingRemove = true
                }
                .buttonStyle(.bordered)

                Button("更新保存") {
                    onSave(apiKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .confirmationDialog("确定清除钥匙串中的 API Key？", isPresented: $isConfirmingRemove) {
            Button("清除并退出登录", role: .destructive) {
                onRemove()
                dismiss()
            }
        } message: {
            Text("清除后将需要重新填写 API Key 才能上传安装包。")
        }
    }
}
