import Carbon
import AppKit
import Combine

/// 全局快捷键管理（Carbon RegisterEventHotKey）
final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var clipboardHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: "ZRST".fourCharCodeValue, id: 1)
    private let clipboardHotKeyID = EventHotKeyID(signature: "ZRST".fourCharCodeValue, id: 2)

    /// 外部通知：应从 SettingsStore 的 didSet 中触发
    static let didChangeNotification = Notification.Name("zeroflow.shortcutDidChange")

    /// 截图功能开关变化通知：应从 SettingsStore.screenshotEnabled 的 didSet 中触发
    static let screenshotEnabledDidChangeNotification = Notification.Name("zeroflow.screenshotEnabledDidChange")

    /// 剪贴板快捷键变化通知：应从 SettingsStore.clipboardShortcut 的 didSet 中触发
    static let clipboardShortcutDidChangeNotification = Notification.Name("zeroflow.clipboardShortcutDidChange")

    private var onTrigger: (() -> Void)?
    private var onClipboardTrigger: (() -> Void)?

    private init() {
        installEventHandler()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenshotEnabledDidChange(_:)),
            name: Self.screenshotEnabledDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipboardSettingsDidChange(_:)),
            name: Self.clipboardShortcutDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClipboardSettingsDidChange(_:)),
            name: ClipboardMonitor.didChangeNotification,
            object: nil
        )
    }

    func setTriggerHandler(_ handler: @escaping () -> Void) {
        onTrigger = handler
    }

    func setClipboardTriggerHandler(_ handler: @escaping () -> Void) {
        onClipboardTrigger = handler
    }

    // MARK: - 注册

    @discardableResult
    func register(_ shortcut: ShortcutKey) -> Bool {
        unregister()
        guard shortcut.isValid else { return false }

        var hotKeyRefOut: EventHotKeyRef?
        let modifiers = carbonModifiers(for: shortcut.modifiers)
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefOut
        )
        if status == noErr {
            hotKeyRef = hotKeyRefOut
            return true
        }
        return false
    }

    func unregister() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }

    func reinstall(shortcut: ShortcutKey) {
        register(shortcut)
    }

    /// 按剪贴板开关 + 当前快捷键重新启停剪贴板热键
    func reapplyClipboard() {
        unregisterClipboard()
        guard SettingsStore.shared.clipboardEnabled else { return }
        registerClipboard(SettingsStore.shared.clipboardShortcut)
    }

    @discardableResult
    func registerClipboard(_ shortcut: ShortcutKey) -> Bool {
        unregisterClipboard()
        guard shortcut.isValid else { return false }

        var hotKeyRefOut: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            carbonModifiers(for: shortcut.modifiers),
            clipboardHotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRefOut
        )
        if status == noErr {
            clipboardHotKeyRef = hotKeyRefOut
            return true
        }
        return false
    }

    func unregisterClipboard() {
        guard let ref = clipboardHotKeyRef else { return }
        UnregisterEventHotKey(ref)
        clipboardHotKeyRef = nil
    }

    /// 按截图开关 + 当前快捷键状态重新启停全局热键（启动时 / 开关或快捷键变化时调用）
    func reapply() {
        if SettingsStore.shared.screenshotEnabled {
            register(SettingsStore.shared.shortcut)
        } else {
            unregister()
        }
    }

    /// 录制新快捷键期间暂停全局热键，避免按下相同组合键时触发截图
    func suspend() {
        unregister()
    }

    /// 录制结束（成功/取消/窗口关闭）后恢复全局热键
    func resume() {
        reapply()
    }

    /// 录制剪贴板快捷键期间暂停剪贴板热键
    func suspendClipboard() {
        unregisterClipboard()
    }

    func resumeClipboard() {
        reapplyClipboard()
    }

    private func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        return result
    }

    // MARK: - 事件处理器

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let userData, let eventRef else { return noErr }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            GetEventParameter(eventRef,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            let triggeredID = hotKeyID.id
            DispatchQueue.main.async {
                if triggeredID == manager.clipboardHotKeyID.id {
                    manager.onClipboardTrigger?()
                } else {
                    manager.onTrigger?()
                }
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    @objc private func handleShortcutDidChange(_ notification: Notification) {
        reapply()
    }

    @objc private func handleScreenshotEnabledDidChange(_ notification: Notification) {
        reapply()
    }

    @objc private func handleClipboardSettingsDidChange(_ notification: Notification) {
        reapplyClipboard()
    }
}

extension String {
    var fourCharCodeValue: OSType {
        var result: OSType = 0
        for char in utf8 {
            result = (result << 8) | OSType(char)
        }
        return result
    }
}