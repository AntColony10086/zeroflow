import SwiftUI
import AppKit
import ServiceManagement

extension Notification.Name {
    /// 通知 FinderSync 扩展设置已变化（与 FinderSyncExtension/FinderSync.swift 同名常量）
    static let zeroflowFinderNewFileDidChange = Notification.Name("zeroflow.finderNewFileDidChange")
}

/// 设置持久化存储。M0 只负责存取，不接入真实全局热键。
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    private enum Keys {
        static let shortcutKeyCode = "globalShortcut.keyCode"
        static let shortcutModifiers = "globalShortcut.modifiers"
        static let launchAtLogin = "launchAtLogin"
        static let saveDirectory = "saveDirectory"
        static let askSaveLocation = "askSaveLocation"
        static let screenshotEnabled = "screenshotEnabled"
        static let dockClickMinimize = "dockClickMinimize"
        static let dockPreviewEnabled = "dockPreviewEnabled"
        static let dockPreviewHoverDelayMs = "dockPreviewHoverDelayMs"
        static let cmdTabSwitcherEnabled = "cmdTabSwitcherEnabled"
        static let windowSwitcherShowWindowlessApps = "windowSwitcherShowWindowlessApps"
        static let cmdTabShortcutKeyCode = "cmdTabShortcut.keyCode"
        static let cmdTabShortcutModifiers = "cmdTabShortcut.modifiers"
        static let appLanguage = "appLanguage"
        static let finderNewFileEnabled = "finderNewFileEnabled"
        static let finderNewFileName = "finderNewFileName"
        static let finderCmdEnabled = "finderCmdEnabled"
        static let finderCmdTitle = "finderCmdTitle"
        static let finderCmdCommand = "finderCmdCommand"
        static let notchEnabled = "notchEnabled"
        static let notchHoverDelayMs = "notchHoverDelayMs"
        static let notchShowCalendar = "notchShowCalendar"
        static let notchShowResources = "notchShowResources"
        static let notchShowMusic = "notchShowMusic"
        static let notchResourceItems = "notchResourceItems"
    }

    private let defaults: UserDefaults

    /// 与 FinderSync 扩展共享的 App Group 容器。双方都带 8NHN73Q43T.com.zeroflow.app 授权,
    /// 沙盒扩展的 UserDefaults(suiteName:) 读 App Group 不可靠(cfprefsd 报 Container: null),
    /// 所以直接读写容器里同一份 plist 文件(见 saveFinderSharedSettings)。
    static let finderSharedSuite = "8NHN73Q43T.com.zeroflow.app"
    static let finderSharedFileName = "finder-sync-settings.plist"

    private static var finderSharedURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: finderSharedSuite)?
            .appendingPathComponent(finderSharedFileName)
    }

    /// 「访达自定义命令」默认值：装了 WezTerm 直接用其 CLI 在目标目录开新窗口，
    /// 否则退回 open -a Terminal。路径含空格，所以默认模板给 {path} 带上双引号。
    static var defaultFinderCmdCommand: String {
        let wezterm = "/Applications/WezTerm.app/Contents/MacOS/wezterm"
        if FileManager.default.fileExists(atPath: wezterm) {
            return "\(wezterm) start --cwd \"{path}\""
        }
        return "open -a Terminal \"{path}\""
    }

    static let defaultFinderCmdTitle = "打开终端"

    /// 把访达右键菜单相关设置写进 group container,供沙盒化的 FinderSync 扩展读取。
    static func saveFinderSharedSettings(newFileEnabled: Bool, fileName: String,
                                         cmdEnabled: Bool, cmdTitle: String,
                                         cmdCommand: String, language: String) {
        guard let url = finderSharedURL else { return }
        let dict: [String: Any] = [
            Keys.finderNewFileEnabled: newFileEnabled,
            Keys.finderNewFileName: fileName,
            Keys.finderCmdEnabled: cmdEnabled,
            Keys.finderCmdTitle: cmdTitle,
            Keys.finderCmdCommand: cmdCommand,
            Keys.appLanguage: language,
        ]
        (dict as NSDictionary).write(to: url, atomically: true)
    }

    /// 默认保存位置：~/Downloads/zeroflow
    static var defaultSaveDirectory: String {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        return (downloads ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("zeroflow", isDirectory: true).path
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.launchAtLogin: true,
            Keys.saveDirectory: Self.defaultSaveDirectory,
            Keys.askSaveLocation: false,
            Keys.screenshotEnabled: false,
            Keys.dockClickMinimize: false,
            Keys.dockPreviewEnabled: false,
            Keys.dockPreviewHoverDelayMs: 300,
            Keys.cmdTabSwitcherEnabled: false,
            Keys.windowSwitcherShowWindowlessApps: true,
            Keys.cmdTabShortcutKeyCode: Int(ShortcutKey.cmdTabDefault.keyCode),
            Keys.cmdTabShortcutModifiers: Int(ShortcutKey.cmdTabDefault.modifiers.rawValue),
            Keys.finderNewFileEnabled: false,
            Keys.finderNewFileName: "new file.md",
            Keys.finderCmdEnabled: false,
            Keys.finderCmdTitle: Self.defaultFinderCmdTitle,
            Keys.finderCmdCommand: Self.defaultFinderCmdCommand,
            Keys.notchEnabled: false,
            Keys.notchHoverDelayMs: 200,
            Keys.notchShowCalendar: true,
            Keys.notchShowResources: false,
            Keys.notchShowMusic: false,
            Keys.notchResourceItems: NotchResourceItem.allRawValues,
        ])
        _launchAtLogin = Published(initialValue: defaults.bool(forKey: Keys.launchAtLogin))
        _saveDirectory = Published(initialValue: defaults.string(forKey: Keys.saveDirectory) ?? Self.defaultSaveDirectory)
        _askSaveLocation = Published(initialValue: defaults.bool(forKey: Keys.askSaveLocation))
        _screenshotEnabled = Published(initialValue: defaults.bool(forKey: Keys.screenshotEnabled))
        _dockClickMinimize = Published(initialValue: defaults.bool(forKey: Keys.dockClickMinimize))
        _dockPreviewEnabled = Published(initialValue: defaults.bool(forKey: Keys.dockPreviewEnabled))
        _dockPreviewHoverDelayMs = Published(initialValue: defaults.integer(forKey: Keys.dockPreviewHoverDelayMs))
        _cmdTabSwitcherEnabled = Published(initialValue: defaults.bool(forKey: Keys.cmdTabSwitcherEnabled))
        _windowSwitcherShowWindowlessApps = Published(initialValue: defaults.bool(forKey: Keys.windowSwitcherShowWindowlessApps))
        _finderNewFileEnabled = Published(initialValue: defaults.bool(forKey: Keys.finderNewFileEnabled))
        _finderNewFileName = Published(initialValue: defaults.string(forKey: Keys.finderNewFileName) ?? "new file.md")
        _finderCmdEnabled = Published(initialValue: defaults.bool(forKey: Keys.finderCmdEnabled))
        _finderCmdTitle = Published(initialValue: defaults.string(forKey: Keys.finderCmdTitle) ?? Self.defaultFinderCmdTitle)
        _finderCmdCommand = Published(initialValue: defaults.string(forKey: Keys.finderCmdCommand) ?? Self.defaultFinderCmdCommand)
        _notchEnabled = Published(initialValue: defaults.bool(forKey: Keys.notchEnabled))
        _notchHoverDelayMs = Published(initialValue: defaults.integer(forKey: Keys.notchHoverDelayMs))
        _notchShowCalendar = Published(initialValue: defaults.bool(forKey: Keys.notchShowCalendar))
        _notchShowResources = Published(initialValue: defaults.bool(forKey: Keys.notchShowResources))
        _notchShowMusic = Published(initialValue: defaults.bool(forKey: Keys.notchShowMusic))
        _notchResourceItems = Published(initialValue: {
            let stored = defaults.stringArray(forKey: Keys.notchResourceItems) ?? NotchResourceItem.allRawValues
            return NotchResourceItem.allCases.filter { stored.contains($0.rawValue) }.map(\.rawValue)
        }())
        _shortcut = Published(initialValue: Self.loadShortcut(from: defaults))
        _cmdTabShortcut = Published(initialValue: Self.loadCmdTabShortcut(from: defaults))
        _appLanguage = Published(initialValue: AppLanguage(rawValue: defaults.string(forKey: Keys.appLanguage) ?? "") ?? .system)
        ensureDefaultDirectoryExists()
        // 用本次加载的真实值补齐 group container 共享文件（didSet 只在变更时触发）
        syncFinderSharedSettings()
    }

    /// 汇总当前所有访达右键菜单设置写入共享 plist。
    private func syncFinderSharedSettings() {
        Self.saveFinderSharedSettings(newFileEnabled: finderNewFileEnabled,
                                      fileName: finderNewFileName,
                                      cmdEnabled: finderCmdEnabled,
                                      cmdTitle: finderCmdTitle,
                                      cmdCommand: finderCmdCommand,
                                      language: appLanguage.rawValue)
    }

    // MARK: - 快捷键

    @Published var shortcut: ShortcutKey {
        didSet {
            defaults.set(Int(shortcut.keyCode), forKey: Keys.shortcutKeyCode)
            defaults.set(Int(shortcut.modifiers.rawValue), forKey: Keys.shortcutModifiers)
            NotificationCenter.default.post(
                name: GlobalHotkeyManager.didChangeNotification,
                object: nil,
                userInfo: ["shortcut": shortcut]
            )
        }
    }

    private static func loadShortcut(from defaults: UserDefaults) -> ShortcutKey {
        loadShortcut(from: defaults,
                     keyCodeKey: Keys.shortcutKeyCode,
                     modifiersKey: Keys.shortcutModifiers,
                     defaultKeyCode: ShortcutKey.standard.keyCode,
                     defaultModifiers: UInt(ShortcutKey.standard.modifiers.rawValue),
                     defaultCharacter: ShortcutKey.standard.character)
    }

    private static func loadCmdTabShortcut(from defaults: UserDefaults) -> ShortcutKey {
        let loaded = loadShortcut(from: defaults,
                                  keyCodeKey: Keys.cmdTabShortcutKeyCode,
                                  modifiersKey: Keys.cmdTabShortcutModifiers,
                                  defaultKeyCode: ShortcutKey.cmdTabDefault.keyCode,
                                  defaultModifiers: UInt(ShortcutKey.cmdTabDefault.modifiers.rawValue),
                                  defaultCharacter: ShortcutKey.cmdTabDefault.character)
        // 切换器快捷键固定两选一（⌘⇥ / ⌥`）；旧的自由录制值钳回默认
        switch loaded.keyCode {
        case ShortcutKey.cmdTabDefault.keyCode: return .cmdTabDefault
        case ShortcutKey.optionGraveDefault.keyCode: return .optionGraveDefault
        default: return .cmdTabDefault
        }
    }

    private static func loadShortcut(from defaults: UserDefaults,
                                     keyCodeKey: String,
                                     modifiersKey: String,
                                     defaultKeyCode: UInt16,
                                     defaultModifiers: UInt,
                                     defaultCharacter: String) -> ShortcutKey {
        let keyCode = UInt16(defaults.integer(forKey: keyCodeKey))
        let modifiers = UInt(defaults.integer(forKey: modifiersKey))
        if keyCode == 0 && defaults.object(forKey: keyCodeKey) == nil {
            return ShortcutKey(character: defaultCharacter, keyCode: defaultKeyCode,
                               modifiers: NSEvent.ModifierFlags(rawValue: defaultModifiers))
        }
        var char = defaultCharacter
        if let mapped = character(forKeyCode: keyCode) {
            char = mapped
        }
        return ShortcutKey(character: char, keyCode: keyCode,
                           modifiers: NSEvent.ModifierFlags(rawValue: modifiers))
    }

    /// 尝试把 macOS ANSI 键码映射为可显示字符
    static func character(forKeyCode code: UInt16) -> String? {
        let chars: [UInt16: String] = [
            0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
            11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
            18: "1", 19: "2", 20: "3", 21: "4", 22: "5", 23: "6", 24: "7", 25: "8", 26: "9", 27: "0",
            36: "\r", 49: " ", 51: "⌫", 53: "esc", 55: "⌘", 48: "tab"
        ]
        return chars[code]
    }

    // MARK: - 启动

    /// 防止注册失败回滚时的重入循环
    private var isSyncingLaunchAtLogin = false

    @Published var launchAtLogin: Bool {
        didSet {
            syncLaunchAtLogin()
        }
    }

    /// 启动时把「持久化的开关值」与「系统登录项实际注册状态」对齐。
    /// 首次启动默认值为开（init 直接读入，didSet 不触发），此方法补上真正注册，
    /// 修复「默认开但重启不自动启动」的问题。
    func reconcileLaunchAtLogin() {
        syncLaunchAtLogin()
    }

    /// 将当前 launchAtLogin 值同步到系统登录项（注册/注销）。
    /// 手动开关与启动时 reconcile 共用，带防重入守卫。
    private func syncLaunchAtLogin() {
        guard !isSyncingLaunchAtLogin else { return }
        isSyncingLaunchAtLogin = true
        defer { isSyncingLaunchAtLogin = false }

        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        guard #available(macOS 13.0, *) else { return }

        let status = SMAppService.mainApp.status
        if launchAtLogin {
            guard status != .enabled else {
                ZSLog("launchAtLogin ON: already registered, skip")
                return
            }
            do {
                try SMAppService.mainApp.register()
                ZSLog("launchAtLogin ON: registered, status=\(status)")
            } catch {
                let reverted = false
                launchAtLogin = reverted
                defaults.set(false, forKey: Keys.launchAtLogin)
                ZSLog("launchAtLogin ON failed: \(error), status=\(status)")
            }
        } else {
            switch status {
            case .notRegistered, .notFound:
                ZSLog("launchAtLogin OFF: not registered, only persist OFF, status=\(status)")
            default:
                do {
                    try SMAppService.mainApp.unregister()
                    ZSLog("launchAtLogin OFF: unregistered, status=\(status)")
                } catch {
                    let reverted = true
                    launchAtLogin = reverted
                    defaults.set(true, forKey: Keys.launchAtLogin)
                    ZSLog("launchAtLogin OFF failed: \(error), status=\(status)")
                }
            }
        }
    }

    // MARK: - 保存

    @Published var saveDirectory: String {
        didSet {
            defaults.set(saveDirectory, forKey: Keys.saveDirectory)
            ensureDefaultDirectoryExists()
        }
    }

    @Published var askSaveLocation: Bool {
        didSet { defaults.set(askSaveLocation, forKey: Keys.askSaveLocation) }
    }

    // MARK: - 截图

    @Published var screenshotEnabled: Bool {
        didSet {
            defaults.set(screenshotEnabled, forKey: Keys.screenshotEnabled)
            NotificationCenter.default.post(
                name: GlobalHotkeyManager.screenshotEnabledDidChangeNotification,
                object: nil,
                userInfo: ["enabled": screenshotEnabled]
            )
        }
    }

    // MARK: - Dock

    @Published var dockClickMinimize: Bool {
        didSet {
            defaults.set(dockClickMinimize, forKey: Keys.dockClickMinimize)
            NotificationCenter.default.post(
                name: DockClickMinimizer.didChangeNotification,
                object: nil,
                userInfo: ["enabled": dockClickMinimize]
            )
        }
    }

    // MARK: - Dock 预览

    @Published var dockPreviewEnabled: Bool {
        didSet {
            defaults.set(dockPreviewEnabled, forKey: Keys.dockPreviewEnabled)
            NotificationCenter.default.post(
                name: DockHoverPreviewController.didChangeNotification,
                object: nil,
                userInfo: ["enabled": dockPreviewEnabled]
            )
        }
    }

    /// 悬停多久后弹出预览（毫秒）
    @Published var dockPreviewHoverDelayMs: Int {
        didSet {
            defaults.set(dockPreviewHoverDelayMs, forKey: Keys.dockPreviewHoverDelayMs)
        }
    }

    // MARK: - 窗口切换器

    @Published var cmdTabSwitcherEnabled: Bool {
        didSet {
            defaults.set(cmdTabSwitcherEnabled, forKey: Keys.cmdTabSwitcherEnabled)
            NotificationCenter.default.post(
                name: CommandTabSwitcher.didChangeNotification,
                object: nil,
                userInfo: ["enabled": cmdTabSwitcherEnabled]
            )
        }
    }

    @Published var windowSwitcherShowWindowlessApps: Bool {
        didSet {
            defaults.set(windowSwitcherShowWindowlessApps, forKey: Keys.windowSwitcherShowWindowlessApps)
        }
    }

    // MARK: - 访达新建文件

    @Published var finderNewFileEnabled: Bool {
        didSet {
            defaults.set(finderNewFileEnabled, forKey: Keys.finderNewFileEnabled)
            syncFinderSharedSettings()
            // 通知 FinderSync 扩展即时增删 directoryURLs（关闭时清空，Finder 零监控）
            DistributedNotificationCenter.default().post(
                name: .zeroflowFinderNewFileDidChange,
                object: nil
            )
        }
    }

    @Published var finderNewFileName: String {
        didSet {
            defaults.set(finderNewFileName, forKey: Keys.finderNewFileName)
            syncFinderSharedSettings()
        }
    }

    // MARK: - 访达自定义命令

    @Published var finderCmdEnabled: Bool {
        didSet {
            defaults.set(finderCmdEnabled, forKey: Keys.finderCmdEnabled)
            syncFinderSharedSettings()
            // 扩展的 directoryURLs 由「任一功能开启」决定，需通知扩展重算
            DistributedNotificationCenter.default().post(
                name: .zeroflowFinderNewFileDidChange,
                object: nil
            )
        }
    }

    /// 右键菜单里显示的名称（用户自定义文案，不参与本地化）
    @Published var finderCmdTitle: String {
        didSet {
            defaults.set(finderCmdTitle, forKey: Keys.finderCmdTitle)
            syncFinderSharedSettings()
        }
    }

    /// 命令模板：{path} 占位符替换为右键目标目录的绝对路径；不含 {path} 则原样执行
    @Published var finderCmdCommand: String {
        didSet {
            defaults.set(finderCmdCommand, forKey: Keys.finderCmdCommand)
            syncFinderSharedSettings()
        }
    }

    // MARK: - 灵动岛

    @Published var notchEnabled: Bool {
        didSet {
            defaults.set(notchEnabled, forKey: Keys.notchEnabled)
            NotificationCenter.default.post(
                name: NotchHotspotController.didChangeNotification,
                object: nil,
                userInfo: ["enabled": notchEnabled]
            )
        }
    }

    /// 悬停刘海多久后弹出面板（毫秒）；单击刘海可立即弹出
    @Published var notchHoverDelayMs: Int {
        didSet {
            defaults.set(notchHoverDelayMs, forKey: Keys.notchHoverDelayMs)
        }
    }

    /// 内容模块：日历。最多同时显示 2 个模块（设置页限制），全部关闭时面板仍会弹出并显示引导
    @Published var notchShowCalendar: Bool {
        didSet {
            defaults.set(notchShowCalendar, forKey: Keys.notchShowCalendar)
        }
    }

    /// 内容模块：系统资源
    @Published var notchShowResources: Bool {
        didSet {
            defaults.set(notchShowResources, forKey: Keys.notchShowResources)
        }
    }

    /// 内容模块：正在播放
    @Published var notchShowMusic: Bool {
        didSet {
            defaults.set(notchShowMusic, forKey: Keys.notchShowMusic)
        }
    }

    /// 系统资源模块里显示的项目（NotchResourceItem.rawValue，固定顺序）
    @Published var notchResourceItems: [String] {
        didSet {
            defaults.set(notchResourceItems, forKey: Keys.notchResourceItems)
        }
    }

    @Published var cmdTabShortcut: ShortcutKey {
        didSet {
            defaults.set(Int(cmdTabShortcut.keyCode), forKey: Keys.cmdTabShortcutKeyCode)
            defaults.set(Int(cmdTabShortcut.modifiers.rawValue), forKey: Keys.cmdTabShortcutModifiers)
            NotificationCenter.default.post(
                name: CommandTabSwitcher.shortcutDidChangeNotification,
                object: nil,
                userInfo: ["shortcut": cmdTabShortcut]
            )
        }
    }

    // MARK: - 语言

    @Published var appLanguage: AppLanguage {
        didSet {
            defaults.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            syncFinderSharedSettings()
            NotificationCenter.default.post(name: L10n.didChangeNotification, object: nil)
        }
    }

    // MARK: - 最近保存

    var lastSavedPath: String? {
        get { defaults.string(forKey: "lastSavedPath") }
        set { defaults.set(newValue, forKey: "lastSavedPath") }
    }

    /// 确保默认保存目录存在
    private func ensureDefaultDirectoryExists() {
        let dir = saveDirectory
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            return
        }
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    func resetShortcutToDefault() {
        shortcut = .standard
    }
}