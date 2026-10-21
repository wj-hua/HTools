import Combine
import SwiftUI

/// 翻译接口配置：左侧列表，右侧编辑。以表单形式从翻译页弹出。
struct TranslateSettingsView: View {
    @ObservedObject var store: TranslateSettingsStore
    @StateObject private var editor: ProfileEditor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var confirmingDiscard = false
    /// 放弃更改后要做的事：切换到另一个配置，或关闭表单。
    @State private var pendingAction: (() -> Void)?
    @State private var showAPIKey = false

    init(store: TranslateSettingsStore) {
        self.store = store
        _editor = StateObject(wrappedValue: ProfileEditor(store: store))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                profileList
                    .frame(width: 220)
                Divider()
                form
            }
            Divider()
            footer
        }
        .frame(width: 820, height: 640)
        .onAppear { editor.load(store.settings.activeProfileID) }
        .onChange(of: editor.draft.id) { _, _ in showAPIKey = false }
        .onDisappear { editor.stopValidation() }
        .confirmationDialog("删除此配置及其 API Key？", isPresented: $confirmingDelete) {
            Button("删除配置", role: .destructive, action: editor.delete)
        } message: {
            Text("此操作会移除保存在 Keychain 中的对应密钥。")
        }
        .confirmationDialog("放弃未保存的更改？", isPresented: $confirmingDiscard) {
            Button("放弃更改", role: .destructive) { pendingAction?() }
        }
    }

    // MARK: - 列表

    private var profileList: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { editor.selectedID }, set: { id in discardingChanges { editor.load(id) } })) {
                Section("接口配置") {
                    ForEach(store.settings.profiles) { profile in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(profile.name)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if profile.id == store.settings.activeProfileID {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                        .imageScale(.small)
                                        .help("当前接口")
                                }
                            }
                            Text(profile.model)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(profile.id)
                    }
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    discardingChanges { editor.load(nil) }
                } label: {
                    Image(systemName: "plus").frame(width: 20, height: 20)
                }
                .help("新增配置")
                Button {
                    confirmingDelete = true
                } label: {
                    Image(systemName: "minus").frame(width: 20, height: 20)
                }
                .disabled(editor.selectedID == nil)
                .help("删除配置")
                Spacer()
                Button("复制", action: editor.duplicate)
                    .help("复制为新配置（不复制 API Key）")
            }
            .buttonStyle(.borderless)
            .padding(10)
        }
    }

    // MARK: - 表单

    private var form: some View {
        Form {
            Section("基本信息") {
                TextField("配置名称", text: $editor.draft.name)
                Picker("地址类型", selection: $editor.draft.endpointKind) {
                    ForEach(EndpointKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                TextField("接口地址", text: $editor.draft.address, prompt: Text("https://example.com/v1"))
                    .autocorrectionDisabled()
                VStack(alignment: .leading, spacing: 4) {
                    Text("最终请求地址")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    switch Result(catching: { try editor.draft.endpointURL() }) {
                    case .success(let url):
                        Text(url.absoluteString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    case .failure(let error):
                        Text(translateErrorMessage(error))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Text("Base URL 仅追加 /chat/completions，不会自动添加 /v1。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                apiKeyInput
                modelIDsInput
                Toggle("流式输出", isOn: $editor.draft.streaming)
                Picker("推理强度", selection: $editor.draft.reasoningEffort) {
                    ForEach(ReasoningEffort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text("模型与认证")
            } footer: {
                Text("密钥按配置独立存入 Keychain；本地免认证服务可留空。同一接口的模型共用地址与 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("连接验证") {
                HStack {
                    if editor.validation == .running {
                        Button("停止验证", action: editor.stopValidation)
                        ProgressView().controlSize(.small)
                    } else {
                        Button("验证此配置", action: editor.validate)
                    }
                    Text("向正在编辑的接口发送一次短文本，可能产生费用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                switch editor.validation {
                case .idle, .running:
                    EmptyView()
                case .success(let text):
                    Label("验证成功：\(text)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var apiKeyInput: some View {
        LabeledContent("API Key") {
            HStack(spacing: 6) {
                Group {
                    if showAPIKey {
                        TextField("API Key", text: $editor.apiKey, prompt: Text("可选"))
                    } else {
                        SecureField("API Key", text: $editor.apiKey, prompt: Text("可选"))
                    }
                }
                .labelsHidden()
                .autocorrectionDisabled()
                .font(.body.monospaced())

                Button {
                    showAPIKey.toggle()
                } label: {
                    Image(systemName: showAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showAPIKey ? "隐藏 API Key" : "显示 API Key")
            }
        }
    }

    private var modelIDsInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型 ID（每行一个）")
            TextEditor(text: $editor.modelIDsText)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .frame(height: 72)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            if !editor.draft.availableModelIDs.isEmpty {
                Picker("当前模型", selection: Binding(get: { editor.draft.normalized.model }, set: { editor.draft.model = $0 })) {
                    ForEach(editor.draft.availableModelIDs, id: \.self) { Text($0).tag($0) }
                }
            }
        }
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack(spacing: 10) {
            if let message = editor.message {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            } else if editor.isDirty {
                Text("有未保存的更改")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { discardingChanges { dismiss() } }
                .keyboardShortcut(.cancelAction)
            Button("保存配置", action: editor.save)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!editor.canSave)
        }
        .font(.callout)
        .padding(14)
    }

    /// 有未保存的更改时先二次确认，再执行切换或关闭。
    private func discardingChanges(_ action: @escaping () -> Void) {
        if editor.isDirty {
            pendingAction = action
            confirmingDiscard = true
        } else {
            action()
        }
    }
}

/// 正在编辑的配置草稿。保存前不影响翻译页。
@MainActor
final class ProfileEditor: ObservableObject {
    enum Validation: Equatable { case idle, running, success(String), failure(String) }

    @Published var draft = TranslationProfile() { didSet { invalidateValidation(markDirty: true) } }
    @Published var apiKey = "" { didSet { invalidateValidation(markDirty: true) } }
    @Published private(set) var selectedID: UUID?
    @Published private(set) var validation: Validation = .idle
    @Published private(set) var message: String?
    @Published private(set) var canSave = true
    @Published private(set) var isDirty = false
    private var validationTask: Task<Void, Never>?
    private var generation = UUID()
    private var loading = false
    private let store: TranslateSettingsStore

    init(store: TranslateSettingsStore) { self.store = store }

    var modelIDsText: String {
        get { draft.modelIDs.isEmpty ? draft.model : draft.modelIDs.joined(separator: "\n") }
        set {
            var updated = draft
            updated.modelIDs = newValue.components(separatedBy: .newlines)
            if !updated.availableModelIDs.contains(updated.model) {
                updated.model = updated.availableModelIDs.first ?? ""
            }
            draft = updated
        }
    }

    func load(_ id: UUID?) {
        invalidateValidation()
        loading = true
        defer { loading = false; isDirty = false }
        selectedID = id
        draft = store.settings.profiles.first(where: { $0.id == id }) ?? TranslationProfile()
        message = nil
        canSave = true
        do {
            apiKey = try store.keychain.read(draft.id)
        } catch {
            apiKey = ""
            canSave = false
            message = translateErrorMessage(error)
        }
    }

    func duplicate() {
        let original = draft
        load(nil)
        draft = original
        draft.id = UUID()
        draft.name += " 副本"
        apiKey = ""
        message = "已复制非敏感字段。API Key 未复制，请单独填写并保存。"
        isDirty = true
    }

    func save() {
        guard canSave else { return }
        do {
            try store.save(draft, apiKey: apiKey)
            draft = draft.normalized
            selectedID = draft.id
            isDirty = false
            message = apiKey.isEmpty ? "配置已保存，未设置 API Key。" : "配置已保存，API Key 已存入 Keychain。"
        } catch {
            message = translateErrorMessage(error)
        }
    }

    func delete() {
        guard let id = selectedID else { return }
        do {
            try store.delete(id)
            load(store.settings.activeProfileID)
            message = "配置及对应的 Keychain 项目已删除。"
        } catch {
            message = translateErrorMessage(error)
        }
    }

    /// 用正在编辑的快照发送 “Hello, world!”，不要求先保存。
    func validate() {
        invalidateValidation()
        do {
            let snapshot = try TranslationRequest(
                profile: draft, apiKey: apiKey,
                targetLanguage: store.settings.targetLanguage, text: "Hello, world!"
            )
            let token = generation
            validation = .running
            validationTask = Task {
                do {
                    let result = try await TranslateClient().translate(snapshot) { _ in }
                    guard token == generation, !Task.isCancelled else { return }
                    validation = .success(String(result.prefix(300)))
                } catch {
                    guard token == generation, !Task.isCancelled else { return }
                    validation = .failure(translateErrorMessage(error))
                }
                validationTask = nil
            }
        } catch {
            validation = .failure(translateErrorMessage(error))
        }
    }

    func stopValidation() { invalidateValidation() }

    private func invalidateValidation(markDirty: Bool = false) {
        generation = UUID()
        validationTask?.cancel()
        validationTask = nil
        validation = .idle
        if markDirty, !loading {
            isDirty = true
            message = nil
        }
    }
}
