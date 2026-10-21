import SwiftUI

/// 翻译页：截图或粘贴图片在本机识别文字，再用自己配置的接口翻译。
struct TranslateView: View {
    @ObservedObject var translator: TranslateController
    @ObservedObject var store: TranslateSettingsStore
    @ObservedObject var snip: SnipController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingSettings = false
    @FocusState private var sourceFocused: Bool

    init(translator: TranslateController, snip: SnipController) {
        self.translator = translator
        self.store = translator.store
        self.snip = snip
    }

    var body: some View {
        VStack(spacing: 16) {
            header
            HStack(alignment: .top, spacing: 16) {
                sourceCard
                resultCard
            }
            .frame(maxHeight: .infinity)
        }
        .padding(20)
        .frame(maxWidth: 1100, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .navigationTitle("翻译")
        .navigationSubtitle(subtitle)
        .toast($translator.toastMessage)
        .sheet(isPresented: $showingSettings) {
            TranslateSettingsView(store: store)
        }
        .onAppear { sourceFocused = true }
    }

    private var subtitle: String {
        guard let profile = store.activeProfile else { return "尚未配置翻译接口" }
        return "\(profile.name) · \(profile.model)"
    }

    // MARK: - 顶部

    private var header: some View {
        Card(padding: 16) {
            HStack(spacing: 16) {
                IconTile(systemImage: "translate", tint: .indigo, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("截图翻译")
                        .font(.title3.weight(.bold))
                    Text("文字在本机识别，只有识别出的文字会发送到所选接口。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    ActionTile(
                        title: "截图翻译",
                        subtitle: snip.hotKeyPreset.translateLabel,
                        systemImage: "text.viewfinder",
                        tint: .indigo
                    ) {
                        snip.captureHidingApp(primaryAction: .translate)
                    }
                    .frame(width: 110)
                    .disabled(snip.isCapturing)

                    ActionTile(
                        title: "粘贴图片",
                        subtitle: "⇧⌘V",
                        systemImage: "photo.on.rectangle",
                        tint: .teal,
                        action: translator.pasteImage
                    )
                    .frame(width: 110)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                }
            }
        }
    }

    // MARK: - 原文

    private var sourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("原文", systemImage: "text.alignleft") {
                    Button("清空", action: translator.clear)
                        .buttonStyle(.borderless)
                        .disabled(translator.source.isEmpty && translator.translation.isEmpty && !translator.state.isBusy)
                }

                TextEditor(text: Binding(get: { translator.source }, set: { translator.editSource($0) }))
                    .font(.system(size: 15))
                    .scrollContentBackground(.hidden)
                    .focused($sourceFocused)
                    .overlay(alignment: .topLeading) {
                        if translator.source.isEmpty {
                            Text("输入或粘贴文字，也可以截图识别。自动识别语言。")
                                .font(.system(size: 15))
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxHeight: .infinity)

                Divider()

                HStack(spacing: 8) {
                    languagePickers
                    Spacer(minLength: 0)
                    Button(action: translator.translate) {
                        Label("翻译", systemImage: "arrow.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!translator.hasText)
                    .help("翻译  ⌘↩")
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 280, maxHeight: .infinity)
    }

    /// 常用的接口 / 模型 / 目标语言放在翻译按钮旁边，接口的增删改放到下一层的设置表单里。
    private var languagePickers: some View {
        HStack(spacing: 8) {
            Picker("翻译为", selection: Binding(get: { store.settings.targetLanguage }, set: { store.setTargetLanguage($0) })) {
                ForEach(TargetLanguage.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("目标语言")

            if let profile = store.activeProfile {
                Menu {
                    Picker("接口", selection: Binding(get: { store.settings.activeProfileID }, set: { store.select($0) })) {
                        ForEach(store.settings.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("模型", selection: Binding(get: { profile.model }, set: { store.selectModel($0) })) {
                        ForEach(profile.availableModelIDs, id: \.self) { Text($0).tag($0) }
                    }
                    Divider()
                    Button("接口设置…") { showingSettings = true }
                } label: {
                    Text(profile.model)
                }
                .fixedSize()
                .help("切换接口与模型")
            } else {
                Button("添加接口…") { showingSettings = true }
            }
        }
    }

    // MARK: - 译文

    private var resultCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("译文", systemImage: "character.bubble") {
                    Button(action: translator.copyTranslation) {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .disabled(translator.translation.isEmpty)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("复制译文  ⇧⌘C")
                }

                ScrollView {
                    Text(translator.translation.isEmpty ? "译文将在这里显示。" : translator.translation)
                        .font(.system(size: 15))
                        .lineSpacing(5)
                        .foregroundStyle(translator.translation.isEmpty ? .tertiary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)

                Divider()

                statusBar
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 280, maxHeight: .infinity)
    }

    /// 状态行：进行中显示进度和“停止”，失败显示原因和“重试”。
    private var statusBar: some View {
        HStack(spacing: 8) {
            switch translator.state {
            case .recognizing, .translating:
                if reduceMotion {
                    Image(systemName: "hourglass").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .stopped:
                Image(systemName: "stop.circle").foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 2) {
                if let error = store.storageError {
                    Text(error).foregroundStyle(.red)
                } else if translator.state == .idle {
                    Text(store.activeProfile == nil ? "尚未配置翻译接口。" : "⌘↩ 翻译，⇧⌘C 复制译文。")
                        .foregroundStyle(.secondary)
                } else {
                    Text(translator.state.title)
                }
                if case .failed(_, partial: true) = translator.state {
                    Text("已保留部分译文，内容不完整。").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .textSelection(.enabled)
            .lineLimit(3)

            Spacer(minLength: 8)

            if translator.state.isBusy {
                Button("停止", action: translator.stop)
                    .keyboardShortcut(.escape, modifiers: [])
            } else if case .failed = translator.state, store.activeProfile == nil {
                Button("添加接口…") { showingSettings = true }
            } else if translator.state != .idle {
                Button("重试", action: translator.translate)
                    .disabled(!translator.hasText)
            }
        }
        .frame(minHeight: 22)
    }
}
