import SwiftUI

/// 截图页：开始截图 / 贴图、权限、快捷键设置，以及当前所有贴图。
struct SnipView: View {
    @ObservedObject var snip: SnipController
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingCloseAll = false

    private var animation: Animation { reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !snip.hasScreenCapturePermission {
                    permissionCard
                        .transition(.opacity)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    settingsCard
                    shortcutsCard
                }
                pinsCard
            }
            .padding(20)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .animation(animation, value: snip.hasScreenCapturePermission)
            .animation(animation, value: snip.pins.map(\.id))
        }
        .navigationTitle("截图")
        .navigationSubtitle(subtitle)
        .toast($snip.toastMessage)
        .alert("操作失败", isPresented: Binding(get: { snip.errorMessage != nil }, set: { if !$0 { snip.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(snip.errorMessage ?? "")
        }
        .confirmationDialog("关闭全部 \(snip.pins.count) 张贴图？", isPresented: $confirmingCloseAll) {
            Button("全部关闭", role: .destructive) { snip.closeAllPins() }
        } message: {
            Text("贴图没有单独保存，关闭后无法恢复。")
        }
        .onAppear {
            snip.refreshPermission()
            model.refreshAccessibilityStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            snip.refreshPermission()
        }
    }

    private var subtitle: String {
        if !snip.hasScreenCapturePermission { return "需要屏幕录制权限" }
        if snip.pins.isEmpty { return "\(snip.hotKeyPreset.captureLabel) 截图 · \(snip.hotKeyPreset.pinLabel) 贴图" }
        return "\(snip.pins.count) 张贴图" + (snip.pinsHidden ? "（已隐藏）" : "")
    }

    // MARK: - 顶部

    private var header: some View {
        Card(padding: 16) {
            HStack(spacing: 16) {
                IconTile(systemImage: "camera.viewfinder", tint: .blue, size: 46)

                VStack(alignment: .leading, spacing: 4) {
                    Text("截图与贴图")
                        .font(.title3.weight(.bold))
                    Text("框选、标注后复制、保存，或钉在屏幕上对照。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    ActionTile(
                        title: "截图",
                        subtitle: snip.hotKeyPreset.captureLabel,
                        systemImage: "viewfinder",
                        tint: .blue
                    ) {
                        snip.captureHidingApp()
                    }
                    .frame(width: 110)
                    .disabled(snip.isCapturing)

                    ActionTile(
                        title: "贴剪贴板",
                        subtitle: snip.hotKeyPreset.pinLabel,
                        systemImage: "pin",
                        tint: .orange
                    ) {
                        snip.pinClipboard()
                    }
                    .frame(width: 110)
                }
            }
        }
    }

    private var permissionCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("需要“屏幕录制”权限")
                        .font(.headline)
                    Text("授权后 macOS 可能要求重新打开 HTools 才会生效。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("去授权") { snip.requestPermission() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - 设置

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("设置", systemImage: "gearshape")

                SettingRow("快捷键") {
                    Picker("", selection: $snip.hotKeyPreset) {
                        ForEach(SnipHotKeyPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                if !snip.hotKeysRegistered {
                    Label("快捷键被其他 App 占用，请换一组。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if snip.hotKeyPreset == .functionKeys {
                    Text("MacBook 键盘需按住 fn，或在系统设置 › 键盘中把 F1、F2 等键用作标准功能键。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                SettingRow("识别窗口内的界面元素") {
                    Toggle("", isOn: $snip.detectsElements)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!model.isAccessibilityTrusted)
                }

                Group {
                    if model.isAccessibilityTrusted {
                        Text("开启后可以直接点选按钮、输入框等区域；滚轮切换到所在窗口或整块屏幕。")
                    } else {
                        HStack(spacing: 4) {
                            Text("需要“辅助功能”权限，未授权时只识别整个窗口。")
                            Button("去授权") { model.requestAccessibilityPermission() }
                                .buttonStyle(.link)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var shortcutsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("截图时的操作", systemImage: "keyboard")

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    shortcut("↩ / 双击", "复制选区")
                    shortcut("⌘S", "保存为 PNG")
                    shortcut("⌘T 或 \(snip.hotKeyPreset.pinLabel)", "贴到屏幕原处")
                    shortcut("⌘E", "识别文字并翻译（\(snip.hotKeyPreset.translateLabel) 截图翻译时为 ↩）")
                    shortcut("R E A P M X T N", "矩形 · 椭圆 · 箭头 · 画笔 · 记号笔 · 马赛克 · 文字 · 序号")
                    shortcut("⌘Z / ⇧⌘Z", "撤销 / 重做")
                    shortcut("方向键", "微调选区，按住 ⇧ 一次 10 点")
                    shortcut("C / ⇧", "复制颜色 / 切换 HEX、RGB")
                    shortcut("右键 / Esc", "重新框选 / 退出")
                }
                .font(.callout)
            }
        }
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        GridRow {
            Text(keys)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(action)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 贴图

    private var pinsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("贴图", systemImage: "pin") {
                    if !snip.pins.isEmpty {
                        Button(snip.pinsHidden ? "全部显示" : "全部隐藏") {
                            snip.setPinsHidden(!snip.pinsHidden)
                        }
                        Button("全部关闭", role: .destructive) { confirmingCloseAll = true }
                    }
                }

                if snip.pins.isEmpty {
                    Text("截图后按 ⌘T，或按 \(snip.hotKeyPreset.pinLabel) 把剪贴板里的图片、文字钉到屏幕上。贴图上滚轮缩放，⌥ 滚轮调透明度，右键查看更多操作，双击或 Esc 关闭。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        ForEach(snip.pins) { pin in
                            PinThumbnail(pin: pin, isHidden: snip.pinsHidden) {
                                snip.focus(pin)
                            } onClose: {
                                pin.close()
                            }
                            .transition(.opacity)
                        }
                    }
                }
            }
        }
    }
}

private struct PinThumbnail: View {
    @ObservedObject var pin: PinWindowController
    let isHidden: Bool
    let onFocus: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onFocus) {
                Image(decorative: pin.image, scale: pin.pixelsPerPoint)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 96)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(isHidden ? 0.5 : 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableButtonStyle())
            .help("显示这张贴图")
            .overlay(alignment: .topTrailing) {
                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .font(.title3)
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.88))
                    .help("关闭")
                    .padding(4)
                    .transition(.opacity)
                }
            }

            Text("\(pin.image.width) × \(pin.image.height)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .onHover { isHovered = $0 }
        .animation(Motion.snappy, value: isHovered)
    }
}
