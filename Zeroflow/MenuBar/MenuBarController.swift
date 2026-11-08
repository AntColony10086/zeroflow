import AppKit
import SwiftUI

extension Notification.Name {
    /// 请求打开设置窗口（如无截屏权限时引导授权）
    static let zeroflowOpenSettings = Notification.Name("zeroflow.openSettings")

    /// 请求打开设置窗口并跳到「灵动岛」标签页（面板空态引导按钮）
    static let zeroflowOpenNotchSettings = Notification.Name("zeroflow.openNotchSettings")
}

/// 菜单栏控制器：常驻菜单栏，提供「设置」与「退出」
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    private var settingsWindowController: NSWindowController?

    private var captureItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMenuBar()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .zeroflowOpenSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .zeroflowOpenNotchSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotEnabledDidChange(_:)),
            name: GlobalHotkeyManager.screenshotEnabledDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: L10n.didChangeNotification,
            object: nil
        )
        // 屏幕配置变化（分辨率/显示接入）时让截图的 contentFilter 缓存失效重建
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            ScreenCapture.invalidateFilterCache()
        }

        GlobalHotkeyManager.shared.setTriggerHandler {
            CaptureCoordinator.shared.startCapture()
        }
        GlobalHotkeyManager.shared.reapply()
        SettingsStore.shared.reconcileLaunchAtLogin()

        // Dock 单击最小化：按开关初始状态启停（开关变化由 DockClickMinimizer 自行监听恢复）
        DockClickMinimizer.shared.reapply()

        // Dock 快捷键弹出（自动隐藏时）：按开关初始状态启停（开关变化由 DockPeekManager 自行监听恢复）
        DockPeekManager.shared.reapply()

        // 窗口切换器：按开关初始状态启停（开关变化由 CommandTabSwitcher 自行监听恢复）
        CommandTabSwitcher.shared.reapply()

        // Dock 悬停预览：按开关初始状态启停（开关变化由 DockHoverPreviewController 自行监听恢复）
        DockHoverPreviewController.shared.reapply()

        // 灵动岛刘海面板：按开关初始状态启停（开关变化由 NotchHotspotController 自行监听恢复）
        NotchHotspotController.shared.reapply()

        // 剪贴板历史：按开关初始状态启停监听与全局热键（开关变化由各自监听恢复）
        ClipboardMonitor.shared.reapply()
        ClipboardPanelController.shared.reapply()

        // 右键菜单扩展自愈：Sequoia/Tahoe 下 FinderSync 扩展更新后常有「已启用但右键菜单
        // 不出现」的陈旧实例问题，启动时若已启用则重载一次，保证右键菜单立即可用。
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            FinderSyncReloader.reloadIfNeeded()
        }

        if ProcessInfo.processInfo.environment["ZEROFLOW_AUTO_CAPTURE"] == "1" {
            ZSLog("env ZEROFLOW_AUTO_CAPTURE: defer 1.5s then capture")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.startCapture()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_EDITOR_DEBUG"] == "1" {
            ZSLog("env ZEROFLOW_EDITOR_DEBUG: defer 1.5s then open editor directly")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CaptureCoordinator.shared.openEditorForDebug()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_DOCK_PROBE"] == "1" {
            ZSLog("env ZEROFLOW_DOCK_PROBE: defer 1s then dump dock AX tree")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                DockClickMinimizer.runProbe()
            }
        }
        if ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1" {
            ZSLog("env ZEROFLOW_SWITCHER_DEBUG: defer 1s then dump window list")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                CommandTabSwitcher.runDebugProbe()
            }
        }
        if let clipboardDebug = ProcessInfo.processInfo.environment["ZEROFLOW_CLIPBOARD_DEBUG"], clipboardDebug != "0" {
            let expand = clipboardDebug == "preview"
            ZSLog("env ZEROFLOW_CLIPBOARD_DEBUG=\(clipboardDebug): defer 1.5s then show clipboard panel, expand=\(expand)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                ClipboardPanelController.shared.showForDebug(expandAfter: expand ? 1 : 0)
            }
        }
        if let focusStr = ProcessInfo.processInfo.environment["ZEROFLOW_AUTO_FOCUS"],
           let wid = CGWindowID(exactly: Int(focusStr) ?? -1) {
            ZSLog("env ZEROFLOW_AUTO_FOCUS: defer 2s then focus wid=\(wid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let w = WindowList.shared.enumerate().first(where: { $0.id == wid }) else {
                    ZSLog("AUTO_FOCUS: wid \(wid) not in enumerate list")
                    return
                }
                ZSLog("AUTO_FOCUS: focusing wid=\(wid) app=\(w.appName)")
                WindowActivator.shared.focus(window: w)
            }
        }
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "bolt.fill",
            accessibilityDescription: "zeroflow"
        )
        item.button?.imagePosition = .imageOnly
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let item = statusItem else { return }
        let menu = NSMenu()

        let captureItem = NSMenuItem(
            title: L10n.tr("立即截图（%@）", arguments: SettingsStore.shared.shortcut.displayString),
            action: #selector(startScreenshot), keyEquivalent: ""
        )
        captureItem.target = self
        captureItem.isEnabled = SettingsStore.shared.screenshotEnabled
        self.captureItem = captureItem
        menu.addItem(captureItem)

        let settingsItem = NSMenuItem(title: L10n.tr("设置…"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        if SettingsStore.shared.lastSavedPath != nil {
            let recentItem = NSMenuItem(title: L10n.tr("打开最近截图"), action: #selector(openRecent), keyEquivalent: "")
            recentItem.target = self
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.tr("退出 zeroflow"), action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        settingsWindowController?.window?.title = L10n.tr("zeroflow 设置")
    }

    @objc private func startScreenshot() {
        CaptureCoordinator.shared.startCapture()
    }

    @objc private func screenshotEnabledDidChange(_ notification: Notification) {
        let enabled = (notification.userInfo?["enabled"] as? Bool) ?? SettingsStore.shared.screenshotEnabled
        captureItem?.isEnabled = enabled
    }

    @objc private func languageDidChange() {
        rebuildMenu()
    }

    @objc private func openRecent() {
        guard let path = SettingsStore.shared.lastSavedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView())
            )
            window.title = L10n.tr("zeroflow 设置")
            window.setContentSize(NSSize(width: 860, height: 640))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindowController = NSWindowController(window: window)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}