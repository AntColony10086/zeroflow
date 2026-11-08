import SwiftUI
import AppKit

/// Dock 弹出热键录制控件（仅录修饰键组合，默认裸 Option）。
/// 与截图快捷键不同，本功能的触发是「修饰键按下→松开」，没有主键：
/// - 监听 flagsChanged 持续更新草稿（记录按下的修饰键集合）；
/// - 全部修饰键抬起时提交（取按住期间出现过的最大修饰键集合）；
/// - 期间出现任何主键或鼠标按下则本次录制作废（Option 只能单独用）；
/// - Esc 取消录制。
/// 录制期间通过 onSuspend/onResume 挂起/恢复 DockPeekManager 的触发识别。
struct DockPeekHotkeyRecorderView: View {
    @Binding var shortcut: ShortcutKey
    /// 录制期间临时挂起 DockPeekManager 的触发识别
    var onSuspend: () -> Void
    /// 录制结束（成功/取消/视图消失）后恢复
    var onResume: () -> Void
    /// 「恢复默认」按钮动作
    var resetToDefault: () -> Void

    @State private var isRecording = false
    @State private var recordedMods: NSEvent.ModifierFlags = []
    @State private var recordedKeyCode: UInt16 = 0
    @State private var errorMessage: String?
    @State private var eventMonitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor),
                                          lineWidth: isRecording ? 1.5 : 1)
                    )
                Text(isRecording ? draftText : shortcutDisplay)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRecording ? Color.accentColor : (shortcut.isValid ? .primary : Color(nsColor: .secondaryLabelColor)))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .frame(minWidth: 150)
            .fixedSize()
            .onTapGesture {
                toggleRecording()
            }

            Button(L10n.tr("恢复默认")) {
                resetToDefault()
                errorMessage = nil
            }
            .disabled(isRecording)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var shortcutDisplay: String {
        shortcut.isValid ? shortcut.displayString : L10n.tr("未设置")
    }

    private var draftText: String {
        if !recordedMods.isEmpty {
            return Self.modifiersDisplay(recordedMods)
        }
        return L10n.tr("按住修饰键…")
    }

    private static func modifiersDisplay(_ mods: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if mods.contains(.control) { parts.append("⌃") }
        if mods.contains(.option) { parts.append("⌥") }
        if mods.contains(.shift) { parts.append("⇧") }
        if mods.contains(.command) { parts.append("⌘") }
        return parts.isEmpty ? L10n.tr("按住修饰键…") : parts.joined()
    }

    private func toggleRecording() {
        isRecording.toggle()
        errorMessage = nil
        if isRecording {
            startListening()
        } else {
            stopRecording()
        }
    }

    private func startListening() {
        // 录制期间挂起 DockPeekManager 触发识别，避免录制中的按下即触发 peek
        onSuspend()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown]) { [self] event in
            guard isRecording else { return event }
            switch event.type {
            case .keyDown:
                handleKeyDown(event)
            case .flagsChanged:
                handleFlagsChanged(event)
            default:
                // 鼠标按下/松开：热键只认修饰键，作废当前会话
                recordedMods = []
                recordedKeyCode = 0
                errorMessage = L10n.tr("录制期间请勿点击鼠标，只按修饰键")
            }
            return nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { // Esc 取消录制
            stopRecording()
            return
        }
        // 出现主键（字母/数字等）：本功能只支持修饰键组合，作废当前会话
        recordedMods = []
        recordedKeyCode = 0
        errorMessage = L10n.tr("此功能只支持修饰键组合（⌘ / ⇧ / ⌃ / ⌥），请只按修饰键")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods.isEmpty {
            // 全部修饰键抬起：会话内出现过修饰键则提交（取按住期间的最大并集）
            if !recordedMods.isEmpty {
                commit(mods: recordedMods, keyCode: recordedKeyCode)
            }
        } else {
            // 持续记录会话内出现过的修饰键（多修饰键组合按住期间逐步叠加）
            recordedMods.formUnion(mods)
            recordedKeyCode = event.keyCode
            errorMessage = nil
        }
    }

    private func commit(mods: NSEvent.ModifierFlags, keyCode: UInt16) {
        let newShortcut = ShortcutKey(character: "", keyCode: keyCode, modifiers: mods)
        shortcut = newShortcut
        errorMessage = nil
        stopRecording()
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        isRecording = false
        recordedMods = []
        recordedKeyCode = 0
        // 恢复 DockPeekManager 触发识别（此时 shortcut 已更新或保持原值）
        onResume()
    }
}
