import AppKit
import Combine

/// 接口配置列表、当前接口和目标语言。API Key 只存 Keychain。
@MainActor
final class TranslateSettingsStore: ObservableObject {
    @Published private(set) var settings: TranslateSettings
    @Published var storageError: String?
    let keychain = TranslateKeychain()
    private let defaults: UserDefaults
    private static let storageKey = "translate.settings.v1"
    /// 当前接口或模型真正变化前调用，翻译页借此作废进行中的请求。
    var willChangeProfile: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 第一次运行时沿用独立版 HTranslate 已保存的配置。
        let data = defaults.data(forKey: Self.storageKey)
            ?? UserDefaults(suiteName: "com.mino.HTranslate")?.data(forKey: "HTranslate.settings.v1")
        if let data {
            do {
                settings = try JSONDecoder().decode(TranslateSettings.self, from: data)
            } catch {
                settings = TranslateSettings()
                storageError = "无法读取已存的翻译配置，原始数据未覆盖。请检查配置后重新保存。"
            }
        } else {
            settings = TranslateSettings()
        }
        settings.repairSelection()
    }

    var activeProfile: TranslationProfile? { settings.profiles.first { $0.id == settings.activeProfileID } }

    func save(_ profile: TranslationProfile, apiKey: String) throws {
        let profile = profile.normalized
        try profile.validate()
        var next = settings
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
            next.profiles[index] = profile
        } else {
            next.profiles.append(profile)
        }
        if next.activeProfileID == nil { next.activeProfileID = profile.id }
        // 先编码，失败时还没碰 Keychain。
        let data = try JSONEncoder().encode(next)
        try keychain.write(apiKey, for: profile.id)
        if settings.activeProfileID == profile.id || settings.activeProfileID == nil { willChangeProfile?() }
        commit(next, data: data)
    }

    func delete(_ id: UUID) throws {
        guard let index = settings.profiles.firstIndex(where: { $0.id == id }) else { return }
        var next = settings
        next.profiles.remove(at: index)
        if next.activeProfileID == id {
            next.activeProfileID = next.profiles.isEmpty ? nil : next.profiles[min(index, next.profiles.count - 1)].id
        }
        let data = try JSONEncoder().encode(next)
        if settings.activeProfileID == id { willChangeProfile?() }
        try keychain.delete(id)
        commit(next, data: data)
    }

    func select(_ id: UUID?) {
        guard id != settings.activeProfileID, settings.profiles.contains(where: { $0.id == id }) else { return }
        var next = settings
        next.activeProfileID = id
        update(next)
    }

    func selectModel(_ model: String) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == settings.activeProfileID }),
              settings.profiles[index].model != model,
              settings.profiles[index].availableModelIDs.contains(model) else { return }
        var next = settings
        next.profiles[index].model = model
        update(next)
    }

    func setTargetLanguage(_ language: TargetLanguage) {
        guard settings.targetLanguage != language else { return }
        var next = settings
        next.targetLanguage = language
        update(next)
    }

    private func update(_ next: TranslateSettings) {
        do {
            let data = try JSONEncoder().encode(next)
            willChangeProfile?()
            commit(next, data: data)
        } catch {
            storageError = translateErrorMessage(error)
        }
    }

    private func commit(_ next: TranslateSettings, data: Data) {
        defaults.set(data, forKey: Self.storageKey)
        settings = next
        storageError = nil
    }
}

/// 翻译页的状态：原文、译文与进行中的识别 / 翻译任务。
/// 放在 AppModel 里，切换页面或关闭窗口时任务继续。
@MainActor
final class TranslateController: ObservableObject {
    enum State: Equatable {
        case idle, recognizing, translating, stopped
        /// 用时从点“翻译”或开始识别图片算起，含本机识别。
        case completed(duration: Duration, finishedAt: Date)
        case failed(String, partial: Bool = false)

        var isBusy: Bool { self == .recognizing || self == .translating }

        var title: String {
            switch self {
            case .idle: return ""
            case .recognizing: return "正在本机识别文字…"
            case .translating: return "正在翻译…"
            case .completed(let duration, let finishedAt):
                let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
                let time = finishedAt.formatted(date: .omitted, time: .standard)
                return "翻译完成 · 用时 \(String(format: "%.1f", seconds)) 秒 · \(time)"
            case .stopped: return "已停止，现有译文可能不完整"
            case .failed(let message, _): return message
            }
        }
    }

    @Published private(set) var source = ""
    @Published private(set) var translation = ""
    @Published private(set) var state: State = .idle
    @Published var toastMessage: String?
    let store = TranslateSettingsStore()
    private let client = TranslateClient()
    private let recognizer = TextRecognizer()
    private var task: Task<Void, Never>?
    /// 每次发起或作废任务都加一，旧任务的回调据此丢弃。
    private var generation: UInt64 = 0
    /// 本次请求的开始时刻，用来计算完成用时。
    private var startedAt = ContinuousClock.now

    init() {
        store.willChangeProfile = { [weak self] in self?.invalidate(clearTranslation: true) }
    }

    var hasText: Bool { !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// 编辑原文只作废旧译文，不逐字请求。
    func editSource(_ text: String) {
        guard source != text else { return }
        invalidate(clearTranslation: true)
        source = text
    }

    func clear() {
        invalidate(clearTranslation: true)
        source = ""
    }

    func stop() {
        let busy = state.isBusy
        invalidate(clearTranslation: false)
        if busy { state = .stopped }
    }

    func translate() {
        guard hasText else { return }
        invalidate(clearTranslation: true)
        let id = generation
        startedAt = .now
        task = Task { await translateCurrent(id: id) }
    }

    /// 截图选区或剪贴板图片：本机识别后填入原文，再自动翻译一次。
    func recognize(_ image: CGImage) {
        invalidate(clearTranslation: false)
        let id = generation
        state = .recognizing
        startedAt = .now
        task = Task {
            do {
                let text = try await recognizer.recognize(image)
                guard isCurrent(id) else { return }
                source = text
                translation = ""
                await translateCurrent(id: id)
            } catch {
                guard isCurrent(id) else { return }
                fail(error)
            }
        }
    }

    func pasteImage() {
        guard let image = NSImage(pasteboard: .general),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            invalidate(clearTranslation: false)
            state = .failed("剪贴板中没有图片。请先复制图片，再点击“粘贴图片”。")
            return
        }
        recognize(cgImage)
    }

    func copyTranslation() {
        guard !translation.isEmpty, Pasteboard.copy(translation) else { return }
        toastMessage = "译文已复制"
    }

    private func translateCurrent(id: UInt64) async {
        guard isCurrent(id) else { return }
        guard let profile = store.activeProfile else {
            state = .failed("原文已保留。请先添加接口配置，再点击翻译。")
            return
        }
        do {
            let snapshot = try TranslationRequest(
                profile: profile, apiKey: store.keychain.read(profile.id),
                targetLanguage: store.settings.targetLanguage, text: source
            )
            state = .translating
            let result = try await client.translate(snapshot) { [weak self] text in
                guard let self, self.isCurrent(id) else { return }
                self.translation = text
            }
            guard isCurrent(id) else { return }
            translation = result
            state = .completed(duration: startedAt.duration(to: .now), finishedAt: .now)
            task = nil
        } catch {
            guard isCurrent(id) else { return }
            fail(error)
            task = nil
        }
    }

    private func isCurrent(_ id: UInt64) -> Bool { generation == id && !Task.isCancelled }

    private func invalidate(clearTranslation: Bool) {
        generation &+= 1
        task?.cancel()
        task = nil
        if clearTranslation { translation = "" }
        state = .idle
    }

    private func fail(_ error: any Error) {
        if error is CancellationError { state = .stopped; return }
        state = .failed(translateErrorMessage(error), partial: state == .translating && !translation.isEmpty)
    }
}
