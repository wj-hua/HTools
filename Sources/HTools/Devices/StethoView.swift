import SwiftUI

struct StethoView: View {
    @StateObject private var inspector: StethoInspector
    @Environment(\.dismiss) private var dismiss
    @State private var targetID = ""
    @State private var selectedRequestID: UUID?
    @State private var query = ""
    @State private var detailTab: DetailTab = .headers
    @State private var toastMessage: String?

    private enum DetailTab: String, CaseIterable {
        case headers = "概览与请求头"
        case request = "请求正文"
        case response = "响应正文"
    }

    init(device: ADBDevice, adb: ADBService, preferredProcess: String? = nil) {
        _inspector = StateObject(wrappedValue: StethoInspector(device: device, adb: adb))
        _targetID = State(initialValue: preferredProcess.map { "stetho_\($0)_devtools_remote" } ?? "")
    }

    private var selectedRequest: StethoRequest? {
        inspector.requests.first { $0.id == selectedRequestID }
    }

    private var filteredRequests: [StethoRequest] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return inspector.requests }
        return inspector.requests.filter {
            $0.url.localizedCaseInsensitiveContains(term)
                || $0.method.localizedCaseInsensitiveContains(term)
                || $0.statusLabel.localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            controls
            Divider()
            if inspector.targets.isEmpty && inspector.requests.isEmpty && inspector.phase == .idle {
                emptyTargets
            } else {
                captureContent
            }
            Divider()
            footer
        }
        .background(.background)
        .frame(minWidth: 840, idealWidth: 1080, minHeight: 560, idealHeight: 720)
        .toast($toastMessage)
        .alert("抓包失败", isPresented: Binding(
            get: { inspector.errorMessage != nil },
            set: { if !$0 { inspector.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(inspector.errorMessage ?? "")
        }
        .onAppear { inspector.discover() }
        .onDisappear { inspector.close() }
        .onChange(of: inspector.targets) { _, targets in
            if !targets.contains(where: { $0.id == targetID }) { targetID = targets.first?.id ?? "" }
        }
        .onChange(of: inspector.requests.first?.id) { _, _ in
            if let selectedRequestID, !inspector.requests.contains(where: { $0.id == selectedRequestID }) {
                self.selectedRequestID = nil
            }
        }
        .task(id: bodyLoadKey) {
            if let request = selectedRequest, detailTab == .response { inspector.loadBody(for: request.id) }
        }
    }

    private var bodyLoadKey: String {
        "\(selectedRequestID?.uuidString ?? ""):\(selectedRequest?.isFinished ?? false):\(detailTab.rawValue):\(inspector.phase)"
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "network", tint: .blue, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text("网络抓包 · Stetho").font(.title2.weight(.semibold))
                Text(inspector.device.displayName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .background(.bar)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("应用 / 进程", selection: $targetID) {
                if inspector.targets.isEmpty { Text("未发现应用").tag("") }
                ForEach(inspector.targets) { target in
                    Text(target.processName).tag(target.id)
                }
            }
            .frame(maxWidth: 480)
            .disabled(inspector.phase != .idle || inspector.isDiscovering)

            Button {
                inspector.discover()
            } label: {
                Label("刷新应用", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .help("重新查找正在运行的 Stetho 应用")
            .disabled(inspector.isDiscovering || inspector.phase != .idle)

            if inspector.phase == .idle {
                Button("开始抓包", systemImage: "record.circle") {
                    guard let target = inspector.targets.first(where: { $0.id == targetID }) else { return }
                    selectedRequestID = nil
                    inspector.start(target)
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetID.isEmpty || inspector.isDiscovering)
            } else {
                Button(inspector.phase == .connecting ? "取消连接" : "停止抓包", systemImage: "stop.fill") {
                    inspector.stop()
                }
            }
            Spacer(minLength: 0)
            Button("清空", systemImage: "trash") {
                selectedRequestID = nil
                inspector.clear()
            }
            .disabled(inspector.requests.isEmpty)
        }
        .padding(16)
    }

    private var emptyTargets: some View {
        ContentUnavailableView {
            Label(inspector.isDiscovering ? "正在查找应用…" : "未发现 Stetho 应用", systemImage: "network")
        } description: {
            Text("在手机上打开已集成并初始化 Stetho 的应用，然后点击“刷新应用”。\n网络请求还需接入 Stetho 网络拦截器。支持 USB 和无线 ADB 连接。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captureContent: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("筛选 URL、方法或状态码", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除筛选")
                    }
                    Spacer()
                    Text("\(filteredRequests.count) 条请求").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                requestTable
            }
            .frame(minHeight: 160, idealHeight: 280)

            requestDetail
                .frame(minHeight: 180, idealHeight: 280)
        }
    }

    private var requestTable: some View {
        Table(filteredRequests, selection: $selectedRequestID) {
            TableColumn("时间") { request in
                Text(request.startedAt, format: .dateTime.hour().minute().second())
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .width(72)
            TableColumn("方法", value: \.method).width(64)
            TableColumn("状态") { request in
                Text(request.statusLabel)
                    .monospacedDigit()
                    .foregroundStyle(statusColor(request))
            }
            .width(52)
            TableColumn("域名", value: \.host).width(min: 120, ideal: 170)
            TableColumn("路径") { request in
                Text(request.path).lineLimit(1).help(request.url)
            }
            TableColumn("耗时", value: \.durationText).width(72)
        }
        .overlay {
            if filteredRequests.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "等待网络请求" : "没有匹配的请求", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(query.isEmpty ? (inspector.phase == .capturing ? "操作手机上的应用，新请求会出现在这里。" : "点击“开始抓包”，然后操作手机上的应用。") : "尝试其他 URL、方法或状态码。")
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var requestDetail: some View {
        VStack(spacing: 0) {
            if let request = selectedRequest {
                HStack(spacing: 12) {
                    Picker("详情", selection: $detailTab) {
                        ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 400)
                    Spacer()
                    Button("复制 URL") { copy(request.url, message: "URL 已复制") }
                    Button("复制 cURL") { copy(request.curl, message: "cURL 已复制") }
                }
                .padding(12)
                Divider()
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        detailContent(request)
                            .padding(16)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView("选择请求查看详情", systemImage: "cursorarrow.click")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func detailContent(_ request: StethoRequest) -> some View {
        switch detailTab {
        case .headers:
            VStack(alignment: .leading, spacing: 16) {
                textSection("请求", text: "\(request.method) \(request.url)")
                textSection("状态", text: "\(request.statusLabel) \(request.statusText)\n耗时：\(request.durationText)\n类型：\(request.mimeType.isEmpty ? "—" : request.mimeType)")
                if let failure = request.failure { textSection("错误", text: failure) }
                textSection("请求头", text: headerText(request.requestHeaders))
                textSection("响应头", text: headerText(request.responseHeaders))
            }
        case .request:
            bodyText(request.postData.map(StethoRequest.formattedBody) ?? "此请求没有正文，或 Stetho 未提供正文。")
        case .response:
            switch request.body {
            case .notLoaded:
                bodyText(request.failure ?? (request.isFinished ? "正文尚未读取，请在抓包连接期间查看。" : "等待请求完成…"))
            case .loading:
                ProgressView("正在读取响应正文…")
            case .text(let text):
                VStack(alignment: .leading, spacing: 12) {
                    Button("复制响应正文") { copy(text, message: "响应正文已复制") }
                    bodyText(text.isEmpty ? "（空响应）" : StethoRequest.formattedBody(text))
                }
            case .base64(let text):
                VStack(alignment: .leading, spacing: 12) {
                    Text("二进制响应 · Base64").font(.headline)
                    Button("复制 Base64") { copy(text, message: "Base64 已复制") }
                    bodyText(text)
                }
            case .unavailable(let message):
                bodyText(message)
            }
        }
    }

    private func textSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            bodyText(text)
        }
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func headerText(_ headers: [String: String]) -> String {
        headers.isEmpty ? "—" : headers.keys.sorted().map { "\($0): \(headers[$0] ?? "")" }.joined(separator: "\n")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if inspector.phase == .connecting || inspector.isDiscovering {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(inspector.phase == .capturing ? Color.green : Color.secondary).frame(width: 7, height: 7)
            }
            Text(statusText).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text("仅记录开始后的请求 · 最多保留 \(StethoInspector.requestLimit) 条")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusText: String {
        switch inspector.phase {
        case .idle: return inspector.isDiscovering ? "正在查找应用…" : "已停止"
        case .connecting: return "正在连接 Stetho…"
        case .capturing: return "抓包中 · \(inspector.appTitle ?? inspector.connectedTarget?.processName ?? "")"
        }
    }

    private func statusColor(_ request: StethoRequest) -> Color {
        if request.failure != nil || (request.status ?? 0) >= 400 { return .red }
        if let status = request.status, (200..<300).contains(status) { return .green }
        return .secondary
    }

    private func copy(_ value: String, message: String) {
        if Pasteboard.copy(value) { toastMessage = message }
    }
}
