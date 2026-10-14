import SwiftUI
import AppKit

struct CloudClipboardView: View {
    @ObservedObject var store: CloudClipboardStore
    @State private var showingConnection = false
    @State private var deleting: CloudClip?
    @State private var clearingPending = false
    @State private var address = ""
    @State private var key = ""
    @State private var addingDevice = false
    @State private var deviceName = ""
    @State private var revoking: CloudDevice?

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
                        Button("添加 Android 设备…", systemImage: "plus") { deviceName = ""; addingDevice = true }.disabled(store.token.isEmpty)
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
                if !store.devices.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Android 设备").font(.headline)
                            ForEach(store.devices) { device in
                                HStack {
                                    IconTile(systemImage: "iphone", tint: .green)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                        Group {
                                            if let date = device.lastSeenDate {
                                                Text("最近连接 \(date.formatted(.dateTime.month().day().hour().minute()))")
                                            } else { Text("尚未连接") }
                                        }.font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("撤销", role: .destructive) { revoking = device }
                                }
                            }
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
        .task { if !store.token.isEmpty { await store.refresh(); await store.refreshDevices() } }
        .sheet(isPresented: $showingConnection) {
            VStack(alignment: .leading, spacing: 16) {
                Text("服务器连接").font(.title2.bold())
                TextField("HTTPS 服务器地址", text: $address)
                SecureField("连接密钥", text: $key)
                Text("这是 Mac 的主密钥，保存在 macOS 钥匙串中，不要复制到其他设备。Android 设备请用“添加 Android 设备”获取独立密钥。")
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
        .alert("添加 Android 设备", isPresented: $addingDevice) {
            TextField("设备名称", text: $deviceName)
            Button("取消", role: .cancel) {}
            Button("生成配对信息") {
                let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await store.addDevice(name: name) }
            }.disabled(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("为这台设备生成独立密钥，配对信息会复制到剪贴板，只显示这一次。") }
        .confirmationDialog("撤销“\(revoking?.name ?? "")”？", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("撤销", role: .destructive) { if let device = revoking { Task { await store.revoke(device) } }; revoking = nil }
        } message: { Text("该设备将无法再访问云端粘贴板，需重新添加才能使用。") }
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
