import AppKit
import SwiftUI

/// Google 账号页：管理 antigravity CLI（agy）的多个 Gemini 账号。
///
/// 凭据存在登录钥匙串里且只有一格，所以“切号”就是把某个快照整份写回钥匙串。
/// 切换是本地操作，不需要重新走浏览器登录。
struct AccountsView: View {
    @ObservedObject var store: AntigravityAccountStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pendingDeletion: AntigravityAccount?

    private var statusBinding: Binding<String?> {
        Binding(get: { store.statusMessage }, set: { store.statusMessage = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    private var navigationSubtitle: String {
        let countText = "共 \(store.accounts.count) 个快照"
        if let name = store.currentAccountName {
            return "当前使用 \(name) · \(countText)"
        }
        if let email = store.currentEmail {
            return "当前登录 \(email)（未保存）· \(countText)"
        }
        return "未检测到登录凭据 · \(countText)"
    }

    private var isSaving: Bool {
        store.busyAction == .saving
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                currentCard
                listCard
                notesCard
            }
            .padding(20)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .adaptiveAnimation(Motion.standard, value: store.accounts, reduceMotion: reduceMotion)
            .adaptiveAnimation(Motion.standard, value: store.currentEmail, reduceMotion: reduceMotion)
        }
        .navigationTitle("Google 账号")
        .navigationSubtitle(navigationSubtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                        .symbolEffect(.rotate, options: .repeating, isActive: store.isRefreshing)
                }
                .disabled(store.isRefreshing)
                .help("重新读取钥匙串中的登录状态")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .task { await store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !store.isBusy else { return }
            Task { await store.refresh() }
        }
        .toast(statusBinding)
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "删除账号快照「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("删除", role: .destructive) {
                if let account = pendingDeletion { store.delete(name: account.name) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("只删除本机保存的快照，不会影响 Google 账号本身。")
        }
    }

    // MARK: - 当前登录账号

    private var currentCard: some View {
        Card(padding: 20) {
            if let email = store.currentEmail {
                let isSaved = store.currentAccountName != nil
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .center, spacing: 14) {
                        AccountAvatar(email: email, size: 44, showOnlineDot: true)

                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(email)
                                    .font(.system(.title3, design: .rounded).weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)

                                if let name = store.currentAccountName {
                                    StatusPill(text: "已保存 · \(name)", tint: .green)
                                } else {
                                    StatusPill(text: "未保存快照", tint: .orange)
                                }
                            }

                            tokenStatusRow(expiry: store.currentExpiry, hasRefreshToken: store.currentHasRefreshToken)
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            Button {
                                if Pasteboard.copy(email) {
                                    store.statusMessage = "已复制邮箱"
                                }
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableButtonStyle())
                            .help("复制当前邮箱")

                            saveCurrentButton(isSaved: isSaved)
                        }
                    }

                    if !isSaved {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text("当前账号尚未存为快照，保存后可随时免浏览器一键切回（默认以邮箱前缀命名）。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.orange.opacity(0.08))
                        )
                    }
                }
            } else {
                HStack(spacing: 14) {
                    IconTile(
                        systemImage: "person.crop.circle.badge.questionmark",
                        tint: .secondary,
                        size: 44,
                        isActive: false
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text("尚未检测到 agy 登录凭据")
                            .font(.headline)
                        Text("请先在终端运行 agy 完成 Google 登录，完成后点击刷新即可保存快照。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                }
            }
        }
    }

    @ViewBuilder
    private func saveCurrentButton(isSaved: Bool) -> some View {
        let label = HStack(spacing: 6) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text("保存中…")
            } else {
                Image(systemName: isSaved ? "arrow.triangle.2.circlepath" : "square.and.arrow.down")
                Text(isSaved ? "更新快照" : "保存快照")
            }
        }

        if isSaved {
            Button {
                Task { await store.saveCurrent() }
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .disabled(store.isBusy)
            .help("用钥匙串中的最新凭据覆盖已有快照")
        } else {
            Button {
                Task { await store.saveCurrent() }
            } label: {
                label
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isBusy)
            .help("将当前账号保存为本机快照")
        }
    }

    private func tokenStatusRow(expiry: Date?, hasRefreshToken: Bool) -> some View {
        let isExpired = expiry.map { $0 < Date() } ?? false
        let icon: String
        let tint: Color
        let text: String

        if isExpired && !hasRefreshToken {
            icon = "exclamationmark.triangle.fill"
            tint = .orange
            text = "凭据已过期且缺少续期令牌，请在 agy 中重新登录"
        } else if isExpired {
            icon = "checkmark.circle.fill"
            tint = .green
            text = "凭据有效 · 下次使用 agy 时自动续期"
        } else if let expiry {
            let formatted = expiry.formatted(date: .abbreviated, time: .shortened)
            icon = "checkmark.circle.fill"
            tint = .green
            text = "凭据有效 · 短期令牌有效至 \(formatted)"
        } else {
            icon = "checkmark.circle.fill"
            tint = hasRefreshToken ? .green : .secondary
            text = hasRefreshToken ? "凭据有效（支持自动续期）" : "凭据有效期未知"
        }

        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(isExpired && !hasRefreshToken ? .orange : .secondary)
                .lineLimit(1)
        }
    }

    // MARK: - 已保存账号

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("已保存账号", systemImage: "person.2.badge.gearshape") {
                    HStack(spacing: 10) {
                        if !store.accounts.isEmpty {
                            Text("\(store.accounts.count) 个")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }

                        if FileManager.default.fileExists(atPath: AntigravityAccountStore.storeURL.path) {
                            Button {
                                NSWorkspace.shared.open(AntigravityAccountStore.storeURL)
                            } label: {
                                Label("打开目录", systemImage: "folder")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(PressableButtonStyle())
                            .help("在 Finder 中打开 ~/.agy/accounts")
                        }
                    }
                }

                if store.accounts.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 26))
                            .foregroundStyle(.tertiary)
                        Text("还没有保存的账号快照")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text("在终端登录 Google 账号后，点击上方「保存快照」即可在此一键切换。")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.accounts) { account in
                            AccountRow(
                                account: account,
                                isCurrent: account.email == store.currentEmail,
                                isSwitching: store.busyAction == .switching(account.name),
                                isBusy: store.isBusy,
                                onSwitch: { Task { await store.switchAccount(to: account.name) } },
                                onCopyEmail: {
                                    if Pasteboard.copy(account.email) {
                                        store.statusMessage = "已复制邮箱"
                                    }
                                },
                                onDelete: { pendingDeletion = account }
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - 使用说明

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("使用说明", systemImage: "info.circle")

                VStack(alignment: .leading, spacing: 10) {
                    noteItem(
                        icon: "key.fill",
                        tint: .blue,
                        title: "本地钥匙串切换",
                        detail: "直接写入 macOS 登录钥匙串，无需经过浏览器。首次操作若系统询问 security 访问权限，选择「始终允许」后不再提示。"
                    )
                    noteItem(
                        icon: "arrow.clockwise.circle",
                        tint: .indigo,
                        title: "重开会话生效",
                        detail: "已打开的 agy 会话会在进程内缓存凭据，切号后新开一个会话即使用新账号。"
                    )
                    noteItem(
                        icon: "terminal",
                        tint: .teal,
                        title: "与命令行互通",
                        detail: "快照存放于 ~/.agy/accounts，与命令行工具 agy-acct 共用；同一邮箱再次保存会自动更新已有快照。"
                    )
                }
            }
        }
    }

    private func noteItem(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            IconTile(systemImage: icon, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 账号行

private struct AccountRow: View {
    let account: AntigravityAccount
    let isCurrent: Bool
    let isSwitching: Bool
    let isBusy: Bool
    let onSwitch: () -> Void
    let onCopyEmail: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var isTrashHovered = false

    private var expirySummary: String {
        if account.needsRelogin {
            return "凭据已过期，需重新登录"
        }
        if account.isExpired {
            return "待自动续期"
        }
        guard let expiry = account.expiry else {
            return account.hasRefreshToken ? "可自动续期" : "有效期未知"
        }
        return "有效至 \(expiry.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        HStack(spacing: 12) {
            AccountAvatar(email: account.email, size: 34, showOnlineDot: false)

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(account.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.quaternary)

                    Text(expirySummary)
                        .font(.caption)
                        .foregroundStyle(account.needsRelogin ? Color.orange : Color.secondary.opacity(0.75))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            HStack(spacing: 6) {
                Button(action: onCopyEmail) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .opacity(isHovered ? 1 : 0)
                .help("复制邮箱")

                if isCurrent {
                    Label("使用中", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.green.opacity(0.12)))
                } else {
                    Button(action: onSwitch) {
                        HStack(spacing: 5) {
                            if isSwitching {
                                ProgressView()
                                    .controlSize(.small)
                                Text("切换中")
                            } else {
                                Image(systemName: "arrow.left.arrow.right")
                                    .font(.caption2.weight(.semibold))
                                Text("切换")
                            }
                        }
                        .frame(minWidth: 56)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(isTrashHovered ? .red : .secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .onHover { isTrashHovered = $0 }
                .disabled(isBusy)
                .help("删除快照")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isCurrent
                        ? Color.accentColor.opacity(0.08)
                        : Color.secondary.opacity(isHovered ? 0.09 : 0.04)
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isCurrent
                        ? Color.accentColor.opacity(0.32)
                        : Color(nsColor: .separatorColor).opacity(isHovered ? 0.45 : 0.2),
                    lineWidth: 0.5
                )
        }
        .onHover { isHovered = $0 }
        .animation(Motion.snappy, value: isHovered)
        .animation(Motion.snappy, value: isCurrent)
    }
}

// MARK: - 视觉辅助组件

private struct AccountAvatar: View {
    let email: String
    var size: CGFloat = 36
    var showOnlineDot = false

    private static let palette: [Color] = [.blue, .indigo, .teal, .purple, .orange, .pink]

    private var tint: Color {
        let sum = email.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return Self.palette[abs(sum) % Self.palette.count]
    }

    private var initial: String {
        let first = email.first.map { String($0).uppercased() } ?? "G"
        return first
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: size, height: size)
                .overlay {
                    Text(initial)
                        .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                        .foregroundStyle(tint)
                }

            if showOnlineDot {
                Circle()
                    .fill(.green)
                    .frame(width: 11, height: 11)
                    .overlay {
                        Circle()
                            .stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2)
                    }
                    .offset(x: 1, y: 1)
            }
        }
    }
}

private struct StatusPill: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .lineLimit(1)
    }
}
