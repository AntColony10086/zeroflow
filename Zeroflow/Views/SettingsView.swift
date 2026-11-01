import SwiftUI
import AppKit
import FinderSync

/// 设置页标签页
enum SettingsTab: String, CaseIterable {
    case general = "通用"
    case screenshot = "截图"
    case switcher = "切换"
    case dock = "Dock"
    case dockPreview = "Dock 预览"
    case notch = "灵动岛"
    case finder = "右键菜单"

    var title: String { L10n.tr(rawValue) }
}

struct SettingsView: View {
    /// 跨窗口跳转：外部（如灵动岛面板「添加显示内容」）先置此值再发通知，窗口首次打开时消费
    static var pendingTab: SettingsTab?

    @StateObject private var store = SettingsStore.shared
    @State private var selectedTab: SettingsTab = .screenshot

    var body: some View {
        HStack(spacing: 0) {
            // 左侧：纵向标签栏（仿系统设置）
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    sidebarRow(tab)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 168)

            Divider()

            // 右侧：当前标签的详细设置（Form .grouped 自带滚动）
            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .screenshot:
                    screenshotTab
                case .switcher:
                    switcherTab
                case .dock:
                    dockTab
                case .dockPreview:
                    dockPreviewTab
                case .notch:
                    notchTab
                case .finder:
                    finderTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 560)
        // 无权限触发截图时自动跳到「截图」标签页，让权限引导直接可见
        .onReceive(NotificationCenter.default.publisher(for: .zeroflowOpenSettings)) { _ in
            selectedTab = .screenshot
        }
        .onReceive(NotificationCenter.default.publisher(for: .zeroflowOpenNotchSettings)) { _ in
            Self.pendingTab = nil
            selectedTab = .notch
        }
        // 窗口首次打开时（通知先于视图存在）消费外部预置的标签页
        .onAppear {
            if let tab = Self.pendingTab {
                Self.pendingTab = nil
                selectedTab = tab
            }
        }
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        let selected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundColor(selected ? .white : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color(nsColor: .controlAccentColor) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 截图

    private var screenshotTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("启用截图功能"), isOn: $store.screenshotEnabled)
                    .onChange(of: store.screenshotEnabled) { enabled in
                        guard enabled else { return }
                        // 用便宜的 preflight 判断（不弹窗），未授权再弹系统授权窗，避免重复弹窗
                        if !ScreenRecordingPermission.isGranted {
                            ScreenRecordingPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text(L10n.tr("启用"))
            } footer: {
                Text(L10n.tr("关闭后，全局快捷键与菜单栏「立即截图」将停止工作。"))
            }

            Section {
                LabeledContent(L10n.tr("截屏快捷键")) {
                    ShortcutRecorderView(
                        shortcut: $store.shortcut,
                        onSuspend: { GlobalHotkeyManager.shared.suspend() },
                        onResume: { GlobalHotkeyManager.shared.resume() },
                        resetToDefault: { store.resetShortcutToDefault() }
                    )
                }
            } header: {
                Text(L10n.tr("快捷键"))
            }

            if store.screenshotEnabled {
                Section {
                    ScreenRecordingPermissionRow()
                } header: {
                    Text(L10n.tr("屏幕录制权限"))
                }
            }

            Section {
                LabeledContent(L10n.tr("默认保存位置")) {
                    SaveDirectoryRow(store: store)
                }
                Toggle(L10n.tr("保存时询问位置"), isOn: $store.askSaveLocation)
            } header: {
                Text(L10n.tr("保存"))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 通用

    private var generalTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("开机自动启动（登录时打开）"), isOn: $store.launchAtLogin)
            } header: {
                Text(L10n.tr("开机自启"))
            } footer: {
                Text(L10n.tr("开启后，登录 macOS 时自动在后台启动 zeroflow，可随时用快捷键截图。"))
            }

            Section {
                Picker(L10n.tr("语言"), selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 切换（⌘⇥ 窗口切换器）

    private var switcherTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("用 ⌘⇥ 显示窗口缩略图"), isOn: $store.cmdTabSwitcherEnabled)
                    .onChange(of: store.cmdTabSwitcherEnabled) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text(L10n.tr("启用"))
            } footer: {
                Text(L10n.tr("开启后，按下配置的组合键会弹出窗口缩略图切换器，可切换到最小化、同 app 多窗口、其他 Space 的窗口。关闭后完全恢复系统默认。"))
            }

            if store.cmdTabSwitcherEnabled {
                Section {
                    Picker(L10n.tr("切换快捷键"), selection: $store.cmdTabShortcut) {
                        Text("⌘⇥").tag(ShortcutKey.cmdTabDefault)
                        Text("⌥`").tag(ShortcutKey.optionGraveDefault)
                    }
                    .pickerStyle(.radioGroup)
                } header: {
                    Text(L10n.tr("快捷键"))
                } footer: {
                    Text(L10n.tr("选择其一弹出切换器：⌘⇥（Command + Tab）或 ⌥`（Option + Tab 上方的「`」键）。⇧ + 修饰键 + 主键 后退。"))
                }

                Section {
                    AccessibilityPermissionRow(message: L10n.tr("需要「辅助功能」权限才能接管 ⌘⇥ 切换"))
                    Text(L10n.tr("该权限与 Dock 单击最小化共用，若已开启则此处直接显示绿色。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L10n.tr("权限"))
                }

                Section {
                    Toggle(L10n.tr("显示无窗口的应用"), isOn: $store.windowSwitcherShowWindowlessApps)
                } header: {
                    Text(L10n.tr("选项"))
                } footer: {
                    Text(L10n.tr("开启「显示无窗口的应用」后，窗口全部关闭但仍在运行的应用也会显示（无缩略图时显示 app 图标）。切换器总是会列出其他 Space 上打开的窗口。"))
                }

                Section {
                    ScreenRecordingPermissionRow()
                } header: {
                    Text(L10n.tr("屏幕录制权限"))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dock 预览

    private var dockPreviewTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("悬停 Dock 图标显示窗口缩略图"), isOn: $store.dockPreviewEnabled)
                    .onChange(of: store.dockPreviewEnabled) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text(L10n.tr("启用"))
            } footer: {
                Text(L10n.tr("悬停 Dock 图标时弹出该应用所有窗口的缩略图，点击切换窗口、悬停卡片可关闭窗口。最小化窗口的瓦片悬停同样生效。"))
            }

            if store.dockPreviewEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(L10n.tr("悬停延时")) {
                            Text("\(store.dockPreviewHoverDelayMs) ms")
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(store.dockPreviewHoverDelayMs) },
                            set: { store.dockPreviewHoverDelayMs = Int($0) }
                        ), in: 100...1000, step: 50)
                    }
                } header: {
                    Text(L10n.tr("选项"))
                } footer: {
                    Text(L10n.tr("鼠标停留在 Dock 图标上多久后弹出预览。"))
                }

                Section {
                    AccessibilityPermissionRow(message: L10n.tr("需要「辅助功能」权限才能监测 Dock 悬停"))
                    Text(L10n.tr("该权限与 Dock 单击最小化共用，若已开启则此处直接显示绿色。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L10n.tr("权限"))
                }

                Section {
                    ScreenRecordingPermissionRow()
                    Text(L10n.tr("缩略图抓取需要「屏幕录制」权限，未授权时卡片只显示窗口标题。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L10n.tr("屏幕录制权限"))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 灵动岛

    /// 增减资源项并写回（Store 端按固定顺序过滤）
    private func toggleNotchResourceItem(_ item: NotchResourceItem, on: Bool) {
        var items = store.notchResourceItems
        if on {
            if !items.contains(item.rawValue) { items.append(item.rawValue) }
        } else {
            items.removeAll { $0 == item.rawValue }
        }
        store.notchResourceItems = items
    }

    private var notchTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("启用灵动岛"), isOn: $store.notchEnabled)
                    .onChange(of: store.notchEnabled) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
            } header: {
                Text(L10n.tr("启用"))
            } footer: {
                Text(L10n.tr("鼠标悬停或单击屏幕顶部刘海区域，刘海扩大并显示内容模块；点击面板外部或按 Esc 收起。仅支持带刘海的机型。"))
            }

            if store.notchEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(L10n.tr("悬停延时")) {
                            Text("\(store.notchHoverDelayMs) ms")
                                .monospacedDigit()
                                .foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(store.notchHoverDelayMs) },
                            set: { store.notchHoverDelayMs = Int($0) }
                        ), in: 100...1000, step: 50)
                    }
                } header: {
                    Text(L10n.tr("选项"))
                } footer: {
                    Text(L10n.tr("鼠标停留在刘海区域多久后弹出面板；单击刘海区域可立即弹出，移出后同样按此时长延迟收起。面板尺寸随当前显示内容自动调整。"))
                }

                Section {
                    Toggle(L10n.tr("日历"), isOn: $store.notchShowCalendar)
                    Toggle(L10n.tr("系统资源"), isOn: $store.notchShowResources)
                    Toggle(L10n.tr("正在播放"), isOn: $store.notchShowMusic)
                } header: {
                    Text(L10n.tr("显示内容"))
                } footer: {
                    Text(L10n.tr("弹出面板中显示的内容模块，一次显示一个，可通过面板顶部刘海两侧的按钮切换（默认日历）。全部关闭时，面板仍会弹出并提示添加显示内容。"))
                }

                if store.notchShowResources {
                    Section {
                        ForEach(NotchResourceItem.allCases) { item in
                            Toggle(isOn: Binding(
                                get: { store.notchResourceItems.contains(item.rawValue) },
                                set: { on in toggleNotchResourceItem(item, on: on) }
                            )) {
                                Text(item.title)
                            }
                        }
                    } header: {
                        Text(L10n.tr("资源项"))
                    } footer: {
                        Text(L10n.tr("系统资源模块中显示的项目；CPU 和内存为环形仪表（环心为使用率），GPU 为次要小环，磁盘/网络附最近约 1 分钟的趋势曲线。"))
                    }
                }

                Section {
                    AccessibilityPermissionRow(message: L10n.tr("需要「辅助功能」权限才能监测刘海悬停"))
                    Text(L10n.tr("该权限与 Dock 预览等功能共用，若已开启则此处直接显示绿色。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text(L10n.tr("权限"))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 右键菜单

    private var finderTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("在访达右键菜单中显示「新建空文件」"), isOn: $store.finderNewFileEnabled)
            } header: {
                Text(L10n.tr("启用"))
            } footer: {
                Text(L10n.tr("开启后，在「访达」窗口或桌面的用户目录内点按右键即可新建空文件；关闭后 Finder 不监控任何目录，完全无副作用。"))
            }

            if store.finderNewFileEnabled {
                Section {
                    LabeledContent(L10n.tr("新文件名")) {
                        TextField("", text: $store.finderNewFileName, prompt: Text(L10n.tr("默认文件名")))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                } header: {
                    Text(L10n.tr("文件名"))
                } footer: {
                    Text(L10n.tr("包含扩展名，如 new file.md。名称已存在时自动追加数字（new file 1.md、new file 2.md…）。"))
                }
            }

            Section {
                Toggle(L10n.tr("在访达右键菜单中显示「自定义命令」"), isOn: $store.finderCmdEnabled)
            } header: {
                Text(L10n.tr("自定义命令"))
            } footer: {
                Text(L10n.tr("开启后，访达右键菜单新增一条菜单项，点击即执行下方配置的命令。"))
            }

            if store.finderCmdEnabled {
                Section {
                    LabeledContent(L10n.tr("菜单名称")) {
                        TextField("", text: $store.finderCmdTitle, prompt: Text(L10n.tr("打开终端")))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                    LabeledContent(L10n.tr("命令")) {
                        TextField("", text: $store.finderCmdCommand, prompt: Text(L10n.tr("如 /Applications/WezTerm.app/Contents/MacOS/wezterm start --cwd \"{path}\"")))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                    }
                } header: {
                    Text(L10n.tr("命令配置"))
                } footer: {
                    Text(L10n.tr("命令中的 {path} 会替换为右键目标的绝对路径：右键文件夹=该文件夹、右键文件=其所在文件夹、右键空白处=当前目录；不含 {path} 则原样执行。路径含空格请给 {path} 加引号。命令由 Zeroflow 主 App 代为执行（登录 Shell，PATH 含 Homebrew），请保持 Zeroflow 常驻运行。"))
                }
            }

            if store.finderNewFileEnabled || store.finderCmdEnabled {
                Section {
                    FinderSyncPermissionRow()
                } header: {
                    Text(L10n.tr("访达扩展"))
                } footer: {
                    Text(L10n.tr("首次使用需在系统中启用扩展；扩展启用后，菜单出现在用户目录（含桌面）内的任意位置。"))
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Dock

    private var dockTab: some View {
        Form {
            Section {
                Toggle(L10n.tr("单击 Dock 图标最小化窗口"), isOn: $store.dockClickMinimize)
                    .onChange(of: store.dockClickMinimize) { enabled in
                        guard enabled else { return }
                        if !AccessibilityPermission.isGranted {
                            AccessibilityPermission.requestAuthorization()
                        }
                    }
                if store.dockClickMinimize {
                    AccessibilityPermissionRow(message: L10n.tr("需要「辅助功能」权限才能最小化窗口"))
                    LabeledContent(L10n.tr("桌面与 Dock")) {
                        Button(L10n.tr("前往设置")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
                        }
                    }
                    Text(L10n.tr("建议同时开启「桌面与 Dock → 最小化窗口到应用图标」，可避免最小化后还原位置丢失。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text(L10n.tr("Dock"))
            }
        }
        .formStyle(.grouped)
    }
}

/// 截图模块的屏幕录制权限状态与引导（与 AccessibilityPermissionRow 样式一致）
private struct ScreenRecordingPermissionRow: View {
    @State private var granted = ScreenRecordingPermission.isGranted

    var body: some View {
        Group {
            if granted {
                Label(L10n.tr("屏幕录制权限已开启"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("需要「屏幕录制」权限才能截图"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L10n.tr("1. 点击下方「打开系统设置授权」\n2. 在「隐私与安全性 → 屏幕录制」中为 Zeroflow 打开开关\n3. 授权后回到应用，点击「重新检测」"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Button(L10n.tr("打开系统设置授权")) {
                            ScreenRecordingPermission.requestAuthorization()
                        }
                        Button(L10n.tr("重新检测")) {
                            recheck()
                        }
                    }
                }
            }
        }
        // 首次出现 + 授权后回到应用自动重查（真实探测，避免 preflight 缓存误判）
        .onAppear {
            recheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
    }

    private func recheck() {
        Task { @MainActor in
            granted = await ScreenRecordingPermission.hasScreenCaptureAccess()
        }
    }
}

/// 访达扩展的启用状态与引导（与 ScreenRecordingPermissionRow 样式一致）
private struct FinderSyncPermissionRow: View {
    @State private var enabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        Group {
            if enabled {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("访达扩展已启用"), systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    // 陈旧实例自愈：macOS Sequoia/Tahoe 下扩展更新后可能「已启用但右键菜单不出现」，
                    // 此按钮复现系统设置里的「关闭→打开」，强制 pkd 重载扩展实例。
                    Button(L10n.tr("刷新右键菜单扩展")) {
                        FinderSyncReloader.reloadIfNeeded(force: true) { _ in
                            DispatchQueue.main.async {
                                recheck()
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.tr("尚未在系统中启用访达扩展"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(L10n.tr("点击下方按钮，在「系统设置 → 通用 → 登录项与扩展 → 扩展」中开启 zeroflow 的「FinderSync」扩展。"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(L10n.tr("打开扩展管理")) {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                }
            }
        }
        .onAppear {
            recheck()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recheck()
        }
    }

    private func recheck() {
        enabled = FIFinderSyncController.isExtensionEnabled
    }
}

#Preview {
    SettingsView()
}
