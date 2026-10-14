import SwiftUI
import AppKit

struct CloudClipboardView: View {
    @ObservedObject var store: CloudClipboardStore
    @State private var showingConnection = false
    @State private var deleting: CloudClip?
    @State private var clearingPending = false
    @State private var address = ""
    @State private var key = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        IconTile(systemImage: "doc.on.clipboard", tint: .blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("跨设备粘贴板").font(.headline)
                            Text(store.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Toggle("自动同步", isOn: $store.enabled).toggleStyle(.switch)
                            .disabled(store.token.isEmpty)
                    }
                    Text("Mac 复制的文本和图片会上传到阿里云，Android 可复制或下载。云端只保留最新 50 条\(store.retentionDays > 0 ? "，超过 \(store.retentionDays) 天也会删除" : "，超出的旧记录及图片自动删除")。")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    HStack {
                        Button("连接设置", systemImage: "gearshape") { address = store.endpoint; key = store.token; showingConnection = true }
                        Button("复制 Android 配对信息", systemImage: "link") { store.copyPairing() }.disabled(store.token.isEmpty)
                        Spacer()
                        if store.pendingCount > 0 {
                            Text("待同步 \(store.pendingCount) 条").font(.caption).foregroundStyle(.secondary)
                            if !store.enabled {
                                Button("清空待同步") { clearingPending = true }
                            }
                        }
                        Button("刷新", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                            .disabled(store.isRefreshing || store.token.isEmpty)
                    }
                    }
                }
                if store.items.isEmpty {
                    ContentUnavailableView("暂无云端记录", systemImage: "doc.on.clipboard",
                        description: Text("连接服务器并开启自动同步后，在 Mac 上复制一段文本或一张图片。"))
                }
                ForEach(store.items) { item in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            if let text = item.text {
                                Text(text).lineLimit(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                CloudImagePreview(store: store, item: item)
                            }
                            VStack {
                                Button("复制", systemImage: "doc.on.doc") { Task { await store.copy(item) } }
                                Button("下载", systemImage: "arrow.down.to.line") { download(item) }
                                Button("删除", systemImage: "trash", role: .destructive) { deleting = item }
                            }
                        }
                        HStack {
                            Text(item.kind == "image" ? "图片" : "文本")
                            Text(item.date, format: .dateTime.month().day().hour().minute())
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file))
                        }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(24)
        }
        .navigationTitle("跨设备粘贴板")
        .toast($store.toastMessage)
        .task { if !store.token.isEmpty { await store.refresh() } }
        .sheet(isPresented: $showingConnection) {
            VStack(alignment: .leading, spacing: 16) {
                Text("服务器连接").font(.title2.bold())
                TextField("HTTPS 服务器地址", text: $address)
                SecureField("连接密钥", text: $key)
                Text("密钥保存在 macOS 钥匙串中。保存后，复制配对信息并在 Android 中粘贴一次。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("关闭") { showingConnection = false }
                    Button("保存连接") { store.errorMessage = nil; store.saveConnection(address: address.trimmingCharacters(in: .whitespacesAndNewlines), key: key.trimmingCharacters(in: .whitespacesAndNewlines)); if store.errorMessage == nil { showingConnection = false } }
                        .buttonStyle(.borderedProminent)
                }
            }.textFieldStyle(.roundedBorder).padding(24).frame(width: 500)
        }
        .confirmationDialog("删除这条云端记录？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) { if let item = deleting { Task { await store.delete(item) } }; deleting = nil }
        }
        .confirmationDialog("清空尚未上传的记录？", isPresented: $clearingPending) {
            Button("清空待同步", role: .destructive) { store.clearPending() }
        }
        .alert("操作失败", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("好", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func download(_ item: CloudClip) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clipboard-\(item.id.prefix(8)).\(item.kind == "image" ? "png" : "txt")"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let data: Data
                    if let text = item.text { data = Data(text.utf8) }
                    else { data = try await store.imageData(item) }
                    try data.write(to: url, options: .atomic)
                    store.toastMessage = "已下载"
                } catch { store.errorMessage = error.localizedDescription }
            }
        }
    }
}

private struct CloudImagePreview: View {
    @ObservedObject var store: CloudClipboardStore
    let item: CloudClip
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 200)
            } else if failed { Label("图片加载失败，请刷新", systemImage: "photo") }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, minHeight: 80)
        .task(id: item.id) {
            do { image = NSImage(data: try await store.imageData(item)); failed = image == nil }
            catch { failed = true }
        }
    }
}
