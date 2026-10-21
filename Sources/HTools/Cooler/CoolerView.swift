import SwiftUI

struct CoolerView: View {
    @ObservedObject var cooler: CoolerController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingLowTempOff = false

    private var animation: Animation { reduceMotion ? .easeInOut(duration: 0.15) : Motion.standard }

    var body: some View {
        Group {
            if case .unavailable(let reason) = cooler.phase {
                ContentUnavailableView {
                    Label("无法使用蓝牙", systemImage: "bluetooth.slash")
                } description: {
                    Text(reason)
                } actions: {
                    Button("打开系统蓝牙设置") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if cooler.isReady {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                                temperatureCard
                                coolingCard
                                lightCard
                                settingsCard
                            }
                            .transition(.opacity)
                        } else {
                            nearbyCard
                                .transition(.opacity)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .animation(animation, value: cooler.isReady)
                }
            }
        }
        .navigationTitle("散热背夹")
        .navigationSubtitle(subtitle)
        .toast($cooler.toastMessage)
        .alert("操作失败", isPresented: Binding(get: { cooler.errorMessage != nil }, set: { if !$0 { cooler.errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(cooler.errorMessage ?? "")
        }
        .confirmationDialog("关闭低温保护？", isPresented: $confirmingLowTempOff) {
            Button("仍要关闭", role: .destructive) { cooler.setLowTempProtect(false) }
        } message: {
            Text("背夹温度可能过低导致冷凝水结冰，长时间运行可能损坏设备与手机。背夹重启后会自动重新开启。")
        }
        .onAppear { cooler.pageAppeared() }
        .onDisappear { cooler.pageDisappeared() }
    }

    private var subtitle: String {
        switch cooler.phase {
        case .unavailable: return "蓝牙不可用"
        case .searching: return "正在搜索背夹…"
        case .connecting: return "正在连接…"
        case .ready: return "已连接"
        case .poweredOff: return "背夹已按定时关闭"
        }
    }

    // MARK: - 顶部设备卡片

    private var header: some View {
        Card(padding: 16) {
            HStack(spacing: 16) {
                IconTile(
                    systemImage: "fan.fill",
                    tint: headerFanTint,
                    size: 46,
                    isActive: cooler.isReady
                )
                .symbolEffect(
                    .rotate,
                    options: .repeating,
                    isActive: cooler.isReady && cooler.isCooling && !reduceMotion
                )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(cooler.deviceName.isEmpty ? "黑鲨散热背夹" : cooler.deviceName)
                            .font(.title3.weight(.bold))

                        connectionBadge
                    }

                    HStack(spacing: 8) {
                        if let firmware = cooler.firmware {
                            Text("固件 \(firmware)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }

                        Text(headerStatusText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if cooler.phase == .connecting {
                    ProgressView().controlSize(.small)
                        .transition(.opacity)
                }

                if cooler.phase == .ready || cooler.phase == .connecting {
                    Button(role: cooler.isReady ? .destructive : nil) {
                        cooler.disconnect()
                    } label: {
                        Label(cooler.isReady ? "断开" : "取消", systemImage: cooler.isReady ? "bolt.slash" : "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .animation(animation, value: cooler.phase)
            .animation(animation, value: cooler.coolingMode)
        }
    }

    private var headerFanTint: Color {
        guard cooler.isReady else { return .secondary }
        guard cooler.isCooling else { return .secondary }
        return modeTint(cooler.coolingMode ?? .smart)
    }

    @ViewBuilder
    private var connectionBadge: some View {
        switch cooler.phase {
        case .ready:
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text(cooler.isCooling ? "制冷中" : "待机中")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.green.opacity(0.12), in: Capsule())
            .foregroundStyle(.green)
        case .connecting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("连接中")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.orange.opacity(0.12), in: Capsule())
            .foregroundStyle(.orange)
        case .poweredOff:
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text("已定时关机")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
        default:
            HStack(spacing: 4) {
                Circle().fill(Color.blue).frame(width: 6, height: 6)
                Text("搜索中")
                    .font(.caption2.weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .foregroundStyle(.blue)
        }
    }

    private var headerStatusText: String {
        switch cooler.phase {
        case .ready:
            if cooler.isCooling {
                return "已连接 · \(cooler.coolingMode?.title ?? "智享")模式生效中"
            } else {
                return "已连接 · 制冷已暂停（仅灯效）"
            }
        case .connecting:
            return "背夹通电并在附近时会自动完成连接"
        case .poweredOff:
            return "背夹已整机断电，重新吸附或插电后会自动开机"
        default:
            return "背夹被手机连着时不会广播，请先在手机上断开"
        }
    }

    // MARK: - 实时温度

    private var temperatureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("实时温度", systemImage: "thermometer.medium")

                HStack(spacing: 12) {
                    temperatureCell(
                        title: "冷端 (贴机导冷面)",
                        icon: "snowflake",
                        value: cooler.coldTemperature,
                        tint: .cyan,
                        statusText: coldTempStatus(cooler.coldTemperature)
                    )

                    temperatureCell(
                        title: "散热端 (鳍片排风面)",
                        icon: "flame.fill",
                        value: cooler.hotTemperature,
                        tint: .orange,
                        statusText: hotTempStatus(cooler.hotTemperature)
                    )
                }

                if let cold = cooler.coldTemperature, let hot = cooler.hotTemperature {
                    let diff = max(0, hot - cold)
                    VStack(spacing: 6) {
                        HStack {
                            Label("制冷温差 (ΔT)", systemImage: "arrow.left.and.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(diff)°C")
                                .font(.system(.callout, design: .rounded).weight(.bold))
                                .monospacedDigit()
                            Text(diff >= 20 ? "制冷强劲" : (diff >= 10 ? "高效散热" : "均衡运转"))
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.14), in: Capsule())
                                .foregroundStyle(.cyan)
                        }

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(height: 6)

                                Capsule()
                                    .fill(LinearGradient(colors: [.cyan, .teal, .orange], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: min(geo.size.width, max(20, geo.size.width * CGFloat(min(diff, 35)) / 35.0)), height: 6)
                            }
                        }
                        .frame(height: 6)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.secondary.opacity(0.05))
                    )
                }

                Text("冷端通过 TEC 半导体紧贴手机降温，散热端经高速风扇与鳍片带走热量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func temperatureCell(title: String, icon: String, value: Int?, tint: Color, statusText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline) {
                BigNumber(text: value.map(String.init) ?? "--", unit: "°C")
                    .animation(animation, value: value)
                Spacer()
                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.12), in: Capsule())
                    .foregroundStyle(tint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.15), lineWidth: 0.5)
        )
    }

    private func coldTempStatus(_ temp: Int?) -> String {
        guard let temp else { return "等待数据" }
        switch temp {
        case ..<5: return "极冷防霜"
        case 5...12: return "冰爽强效"
        case 13...22: return "微凉舒适"
        default: return "常温待机"
        }
    }

    private func hotTempStatus(_ temp: Int?) -> String {
        guard let temp else { return "等待数据" }
        switch temp {
        case ..<35: return "温升正常"
        case 35...44: return "散热良好"
        default: return "高负载"
        }
    }

    // MARK: - 制冷控制

    private var coolingCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("制冷模式", systemImage: "snowflake") {
                    HStack(spacing: 8) {
                        if cooler.isCooling {
                            Text("运行中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.12), in: Capsule())
                        } else {
                            Text("已关闭")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }

                        Toggle("制冷", isOn: Binding(get: { cooler.isCooling }, set: { cooler.setCooling($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }

                HStack(spacing: 10) {
                    ForEach(CoolingMode.coolingModes) { mode in
                        let isSelected = cooler.isCooling && mode == cooler.coolingMode
                        ActionTile(
                            title: mode.title,
                            subtitle: modeSubtitle(mode, isSelected: isSelected),
                            systemImage: mode.systemImage,
                            tint: modeTint(mode),
                            isHighlighted: isSelected,
                            pulsesWhenHighlighted: false
                        ) {
                            cooler.setMode(mode)
                        }
                        .opacity(cooler.isCooling ? 1.0 : 0.6)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: cooler.isCooling ? (cooler.coolingMode?.systemImage ?? "snowflake") : "pause.circle.fill")
                        .font(.callout)
                        .foregroundStyle(cooler.isCooling ? modeTint(cooler.coolingMode ?? .smart) : .secondary)
                    Text(cooler.isCooling ? (cooler.coolingMode?.detail ?? "正在读取当前模式…") : "制冷已关闭（仅灯效亮起），风扇与 TEC 停止工作。轻点上方任一模式即可恢复。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
                .animation(animation, value: cooler.coolingMode)
                .animation(animation, value: cooler.isCooling)
            }
        }
    }

    private func modeSubtitle(_ mode: CoolingMode, isSelected: Bool) -> String {
        if isSelected { return "当前生效" }
        switch mode {
        case .smart: return "智能控温"
        case .silent: return "轻音低噪"
        case .overclock: return "全速极冷"
        default: return "切换"
        }
    }

    private func modeTint(_ mode: CoolingMode) -> Color {
        switch mode {
        case .smart: return .cyan
        case .silent: return .mint
        case .overclock: return .orange
        default: return .secondary
        }
    }

    // MARK: - 风扇灯效

    private var lightCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("风扇灯效", systemImage: "light.max") {
                    HStack(spacing: 8) {
                        if cooler.lightOn {
                            Text(cooler.lightEffect.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.cyan.opacity(0.12), in: Capsule())
                        }
                        Toggle("风扇灯效", isOn: Binding(get: { cooler.lightOn }, set: { cooler.setLightOn($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }

                // 灯效实时预览光环
                HStack(spacing: 14) {
                    FanLightPreview(
                        isOn: cooler.lightOn,
                        effect: cooler.lightEffect,
                        colors: cooler.lightColors,
                        colorCount: cooler.lightColorCount,
                        speedLevel: cooler.lightSpeedLevel,
                        reduceMotion: reduceMotion
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(cooler.lightOn ? cooler.lightEffect.name : "灯效已关闭")
                                .font(.headline)
                            if cooler.lightOn {
                                Text(LightEffect.schemeName(cooler.lightColorCount))
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                        }
                        Text(cooler.lightOn ? lightEffectDescription(cooler.lightEffect.id) : "开启后可选择 11 种酷炫 RGB 动态灯效、配色方案与速度")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )

                if cooler.lightOn {
                    let effect = cooler.lightEffect

                    VStack(spacing: 8) {
                        SettingRow("灯效模式") {
                            Picker("灯效", selection: Binding(get: { effect }, set: { cooler.setLightEffect($0) })) {
                                ForEach(LightEffect.all) { item in
                                    Label(item.name, systemImage: effectIcon(item.id)).tag(item)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        if effect.schemes.count > 1 {
                            Divider()
                            SettingRow("配色方案") {
                                Picker("配色", selection: Binding(get: { cooler.lightColorCount }, set: { cooler.setLightColorCount($0) })) {
                                    ForEach(effect.schemes, id: \.self) { count in
                                        Text(LightEffect.schemeName(count)).tag(count)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }

                        if effect.hasSpeed(colorCount: cooler.lightColorCount) {
                            Divider()
                            SettingRow("变换速度") {
                                Picker("速度", selection: Binding(get: { cooler.lightSpeedLevel }, set: { cooler.setLightSpeed($0) })) {
                                    Text("缓慢").tag(0)
                                    Text("中速").tag(1)
                                    Text("快速").tag(2)
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .fixedSize()
                            }
                        }

                        if cooler.lightColorCount > 0 {
                            Divider()
                            SettingRow("自定义颜色") {
                                HStack(spacing: 10) {
                                    ForEach(0..<cooler.lightColorCount, id: \.self) { index in
                                        HStack(spacing: 5) {
                                            ColorPicker("颜色 \(index + 1)", selection: Binding(
                                                get: { Color(rgb: cooler.lightColors[index]) },
                                                set: { cooler.setLightColor($0, at: index) }
                                            ), supportsOpacity: false)
                                            .labelsHidden()

                                            Text("色 \(index + 1)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .animation(animation, value: cooler.lightOn)
            .animation(animation, value: cooler.lightEffect)
            .animation(animation, value: cooler.lightColorCount)
        }
    }

    private func effectIcon(_ id: UInt8) -> String {
        switch id {
        case 0x02: return "rainbow"
        case 0x03: return "waveform.path"
        case 0x04: return "sparkles"
        case 0x05: return "circle.dashed"
        case 0x06: return "sun.max.fill"
        case 0x07: return "arrow.triangle.2.circlepath"
        case 0x08: return "circle.circle"
        case 0x09: return "bolt.fill"
        case 0x0A: return "gauge.with.needle"
        case 0x0B: return "arrow.clockwise"
        case 0x0C: return "chart.bar.fill"
        default: return "lightbulb"
        }
    }

    private func lightEffectDescription(_ id: UInt8) -> String {
        switch id {
        case 0x02: return "七彩光谱平滑渐变循环流动"
        case 0x03: return "由弱渐强、缓缓明灭呼吸"
        case 0x04: return "夜空繁星般随机微闪跳动"
        case 0x05: return "同心光环由内向外极速扩散"
        case 0x06: return "恒定发光，沉浸陪伴氛围"
        case 0x07: return "多色光段交替环绕追逐"
        case 0x08: return "柔和环形双色循环旋转"
        case 0x09: return "三色爆发式极速对撞冲击"
        case 0x0A: return "渐进式缓冲加减速律动"
        case 0x0B: return "快速流光刷新划过"
        case 0x0C: return "跟随节奏高频跳跃律动"
        default: return "风扇动态灯效"
        }
    }

    // MARK: - 设备设置

    private var settingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("定时与防护", systemImage: "shield.lefthalf.filled")

                VStack(spacing: 8) {
                    SettingRow("定时关机") {
                        HStack(spacing: 8) {
                            if let deadline = cooler.shutdownDeadline {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    let left = max(0, deadline.timeIntervalSince(context.date).rounded(.up))
                                    HStack(spacing: 4) {
                                        Image(systemName: "hourglass")
                                            .font(.caption2)
                                        Text(Duration.seconds(left), format: .time(pattern: .hourMinuteSecond))
                                            .font(.callout.weight(.semibold).monospacedDigit())
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.orange.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.orange)
                                }

                                Button {
                                    cooler.setShutdown(units: 0)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("取消定时关机")
                            }

                            Picker("定时关机", selection: Binding(get: { cooler.shutdownUnits }, set: { cooler.setShutdown(units: $0) })) {
                                ForEach(CoolerController.shutdownOptions, id: \.self) {
                                    Text(CoolerController.shutdownLabel($0)).tag($0)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }

                    Divider()

                    SettingRow("低温保护") {
                        HStack(spacing: 8) {
                            if cooler.lowTempProtect {
                                Text("防结霜已开启")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.teal.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.teal)
                            } else {
                                Text("已关闭")
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.14), in: Capsule())
                                    .foregroundStyle(.red)
                            }

                            Toggle("低温保护", isOn: Binding(get: { cooler.lowTempProtect }, set: { on in
                                if on { cooler.setLowTempProtect(true) } else { confirmingLowTempOff = true }
                            }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("定时到点后背夹整机断电，重新吸附或插拔电源即可重新开机；低温保护可防止冷凝水损坏设备。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: - 未连接列表

    private var nearbyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader("附近的背夹", systemImage: "dot.radiowaves.left.and.right") {
                    if cooler.phase == .searching {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("正在搜索…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if cooler.discovered.isEmpty {
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .stroke(Color.cyan.opacity(0.12), lineWidth: 2)
                                .frame(width: 80, height: 80)
                            Circle()
                                .stroke(Color.cyan.opacity(0.25), lineWidth: 1.5)
                                .frame(width: 60, height: 60)
                            Image(systemName: "fan.fill")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundStyle(.cyan)
                                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        }
                        .padding(.top, 16)

                        VStack(spacing: 6) {
                            Text("正在搜索附近的黑鲨散热背夹…")
                                .font(.headline)
                            Text("请给背夹通电并靠近 Mac。\n若背夹已被手机连接，背夹不会对外广播，请先在手机蓝牙中断开。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 10) {
                        ForEach(cooler.discovered) { item in
                            HStack(spacing: 14) {
                                IconTile(systemImage: "fan.fill", tint: .cyan, size: 38)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .font(.headline)

                                    if let rssi = item.rssi {
                                        signalBadge(rssi: rssi)
                                    } else {
                                        Label("曾连接过", systemImage: "clock.arrow.circlepath")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer()

                                if cooler.phase == .connecting && cooler.deviceName == item.name {
                                    ProgressView().controlSize(.small)
                                        .padding(.trailing, 4)
                                }

                                Button("连接") {
                                    cooler.connect(item)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.regular)
                                .disabled(cooler.phase == .connecting)
                            }
                            .padding(.vertical, 4)

                            if item.id != cooler.discovered.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private func signalBadge(rssi: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "cellularbars")
                .font(.caption2)
            Text("信号 \(rssi) dBm")
                .font(.caption)
                .monospacedDigit()
            Text(rssi >= -65 ? "极佳" : (rssi >= -80 ? "良好" : "较弱"))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.1), in: Capsule())
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - 灯效实时光环预览

private struct FanLightPreview: View {
    let isOn: Bool
    let effect: LightEffect
    let colors: [UInt32]
    let colorCount: Int
    let speedLevel: Int
    let reduceMotion: Bool

    private var gradient: AngularGradient {
        if !isOn {
            return AngularGradient(
                colors: [.secondary.opacity(0.15), .secondary.opacity(0.25), .secondary.opacity(0.15)],
                center: .center
            )
        }
        if colorCount == 0 {
            return AngularGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                center: .center
            )
        } else if colorCount == 1 {
            let c = Color(rgb: colors[0])
            return AngularGradient(colors: [c, c.opacity(0.5), c], center: .center)
        } else {
            let active = (0..<colorCount).map { Color(rgb: colors[$0]) }
            return AngularGradient(colors: active + [active[0]], center: .center)
        }
    }

    private var fanColor: Color {
        guard isOn else { return .secondary }
        return colorCount > 0 ? Color(rgb: colors[0]) : .cyan
    }

    var body: some View {
        ZStack {
            // 外圈柔光
            Circle()
                .stroke(gradient, lineWidth: 5)
                .frame(width: 48, height: 48)
                .blur(radius: isOn ? 4 : 0)
                .opacity(isOn ? 0.65 : 0.15)

            // 清晰光环
            Circle()
                .stroke(gradient, lineWidth: 3)
                .frame(width: 48, height: 48)
                .opacity(isOn ? 1.0 : 0.3)

            // 扇叶旋转
            Image(systemName: "fan.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(fanColor)
                .symbolEffect(.rotate, options: .repeating, isActive: isOn && !reduceMotion)
        }
        .frame(width: 56, height: 56)
    }
}

private extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double(rgb >> 16 & 0xFF) / 255,
            green: Double(rgb >> 8 & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
