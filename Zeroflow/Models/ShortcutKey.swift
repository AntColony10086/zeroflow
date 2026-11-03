import SwiftUI
import AppKit

struct ShortcutKey: Hashable {
    var character: String
    var keyCode: UInt16
    var modifiers: NSEvent.ModifierFlags

    static let standard = ShortcutKey(character: "s", keyCode: 1, modifiers: [.command, .shift])

    /// 窗口切换器默认快捷键：⌘⇥（Command + Tab，kVK_Tab = 48）
    static let cmdTabDefault = ShortcutKey(character: "tab", keyCode: 48, modifiers: [.command])

    /// 窗口切换器备选快捷键：⌥`（Option + Tab 上方的「`」键，kVK_ANSI_Grave = 50）
    static let optionGraveDefault = ShortcutKey(character: "`", keyCode: 50, modifiers: [.option])

    /// 剪贴板历史默认快捷键：⌘⇧C（kVK_ANSI_C = 8）
    static let clipboardDefault = ShortcutKey(character: "c", keyCode: 8, modifiers: [.command, .shift])

    var isValid: Bool {
        !modifiers.isEmpty && !character.isEmpty
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(character)
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if keyCode == 48 { parts.append("⇥") }
        else if !character.isEmpty { parts.append(character.uppercased()) }
        return parts.joined()
    }

    var isDefault: Bool {
        character == "s" && keyCode == 1 && modifiers == [.command, .shift]
    }
}

extension ShortcutKey {
    /// 系统修饰键的 keyCode 集合，仅在捕获到真正的主键时才记为一次有效按键
    static let modifierKeyCodes: Set<UInt16> = [
        0x36, 0x37, 0x38, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F
    ]
}