import SwiftUI

/// Google 账号页：管理 antigravity CLI（agy）的多个 Gemini 账号。
///
/// 凭据存在登录钥匙串里且只有一格，所以“切号”就是把某个快照整份写回钥匙串。
/// 切换是本地操作，不需要重新走浏览器登录。
struct AccountsView: View {
    @ObservedObject var store: AntigravityAccountStore
    @State private var pendingDeletion: AntigravityAccount?

    private var statusBinding: Binding<String?> {
        Binding(get: { store.statusMessage }, set: { store.statusMessage = $0 })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                currentCard
                listCard
                saveCard
                notesCard
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await store.refresh() }
        .toast(statusBinding)
        .alert("操作失败", isPresented: errorBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "删除账号快照？",
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

    private var currentCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("当前账号", systemImage: "person.crop.circle") {
                    Button {
                        Task { await store.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("重新读取钥匙串中的登录状态")
                }

                if let email = store.currentEmail {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(email)
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .textSelection(.enabled)
                        Text(expiryDescription(store.currentExpiry))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("钥匙串里没有 agy 的登录凭据，请先在终端运行 agy 完成登录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var listCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("已保存账号", systemImage: "person.2.badge.gearshape")

                if store.accounts.isEmpty {
                    Text("还没有快照。先登录一个账号，再在下方保存它。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.accounts) { account in
                        accountRow(account)
                        if account.id != store.accounts.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ account: AntigravityAccount) -> some View {
        let isCurrent = account.email == store.currentEmail
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(.callout.weight(.semibold))
                    if isCurrent {
                        Text("正在使用")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(account.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(expiryDescription(account.expiry))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("切换") {
                Task { await store.switchAccount(to: account.name) }
            }
            .disabled(store.isBusy || isCurrent)
            Button {
                pendingDeletion = account
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除快照")
        }
        .frame(minHeight: 36)
    }

    private var saveCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("保存当前账号", systemImage: "square.and.arrow.down")
                HStack(spacing: 8) {
                    Button("保存当前账号") {
                        Task { await store.saveCurrent() }
                    }
                    .disabled(store.isBusy || store.currentEmail == nil)
                    if store.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                Text("快照名自动取邮箱前缀（例如 example）；同一邮箱再次保存会更新已有快照，不会多出一条。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader("使用说明")
                Text("切换账号是本地操作，写入 macOS 登录钥匙串，不经过浏览器。第一次操作时系统可能询问是否允许 security 访问该钥匙串条目，选择「始终允许」后不再提示。")
                Text("已经打开的 agy 会话不会热切号（凭据在进程内缓存），切换后重开一个会话即可。")
                Text("快照保存在 ~/.agy/accounts，与命令行工具 agy-acct 共用；两边可以互相切换账号。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func expiryDescription(_ date: Date?) -> String {
        guard let date else { return "有效期未知" }
        let text = date.formatted(date: .abbreviated, time: .shortened)
        return date < Date() ? "access_token 已于 \(text) 过期（会自动续期）" : "access_token 有效至 \(text)"
    }
}
