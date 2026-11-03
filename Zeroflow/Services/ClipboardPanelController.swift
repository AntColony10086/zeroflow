import AppKit
import Combine
import QuartzCore
import SwiftUI

/// 剪贴板历史面板：非激活 NSPanel（`.nonactivatingPanel` + `canBecomeKey = true`），
/// 成为 key window 即可收键盘，但不激活本 app（原前台应用保持不动，粘贴时 ⌘V 直接落到原窗口）。
/// 键盘（↑↓ / ↵ / esc）由本地 keyDown monitor 拦截，搜索输入交给 SwiftUI 的 TextField。
final class ClipboardPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0,
                                       width: ClipboardPanelMetrics.listWidth,
                                       height: ClipboardPanelMetrics.height(for: 1)),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        self.becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { true }
}

/// 剪贴板历史面板控制器：热键触发 → 插入点处弹出 → 选择/搜索 → 复制并粘贴回原窗口。
final class ClipboardPanelController: NSObject, NSWindowDelegate {
    static let shared = ClipboardPanelController()

    private enum PreviewSide {
        case left
        case right
    }

    private var panel: ClipboardPanel?
    private var model: ClipboardViewModel?
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private var pendingPreview: DispatchWorkItem?
    private var isDismissing = false

    /// 面板左上角锚点（Cocoa 全局坐标）：列表列固定贴在这里，展开预览时窗口只向一侧长
    private var anchorTopY: CGFloat = 0
    private var baseX: CGFloat = 0
    private var anchorScreen: NSScreen?
    private var previewSide: PreviewSide = .right

    /// 面板弹出前的原前台应用：仅在触发兜底激活（面板拿不到 key）时用于还原焦点
    private var previousApp: NSRunningApplication?
    private var didActivateApp = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEnabledDidChange),
            name: ClipboardMonitor.didChangeNotification,
            object: nil
        )
    }

    /// 启动时 / 开关变化时调用：挂上热键触发回调并按开关注册热键
    func reapply() {
        GlobalHotkeyManager.shared.setClipboardTriggerHandler { [weak self] in
            self?.toggle()
        }
        GlobalHotkeyManager.shared.reapplyClipboard()
        if !SettingsStore.shared.clipboardEnabled {
            dismiss()
        }
    }

    @objc private func handleEnabledDidChange() {
        reapply()
    }

    // MARK: - 弹出 / 收起

    private func toggle() {
        if panel?.isVisible == true {
            dismiss()
        } else {
            show()
        }
    }

    /// 调试入口：忽略开关直接弹出（`ZEROFLOW_CLIPBOARD_DEBUG=1`），`expandAfter > 0` 时再自动展开首条预览
    func showForDebug(expandAfter delay: TimeInterval = 0) {
        show(force: true)
        guard delay > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let model = self.model, let item = model.filteredItems.first else { return }
            self.previewSide = self.hasSpaceOnRight ? .right : .left
            model.previewItem = item
            self.applyFrame(animated: true)
        }
    }

    private func show(force: Bool = false) {
        guard force || SettingsStore.shared.clipboardEnabled else { return }
        guard let panel = ensurePanel() else { return }

        previousApp = NSWorkspace.shared.frontmostApplication
        didActivateApp = false

        // 必须在 makeKeyAndOrderFront 之前取插入点：面板成为 key 后焦点会转到搜索框
        let caret = CaretLocator.focusedAnchorRect()
        let model = ClipboardViewModel(items: ClipboardHistoryStore.shared.items)
        self.model = model
        observe(model)
        installContent(model)
        positionCollapsed(anchor: caret)

        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        // 兜底：若系统没把 key 交给非激活面板（异常/旧系统），临时激活本 app 收键盘，
        // 粘贴/收面板时再还原原应用焦点
        if !panel.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            didActivateApp = true
        }
        ZSLog("clipboard panel shown, items=\(model.items.count), key=\(panel.isKeyWindow)")
    }

    func dismiss() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard let panel, panel.isVisible, !isDismissing else { return }
        isDismissing = true
        panel.orderOut(nil)
        isDismissing = false
        cancellables.removeAll()
        ZSLog("clipboard panel dismissed")
        if didActivateApp {
            didActivateApp = false
            previousApp?.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !isDismissing else { return }
        ZSLog("clipboard panel resigned key -> dismiss")
        dismiss()
    }

    // MARK: - 选择 / 预览

    private func observe(_ model: ClipboardViewModel) {
        cancellables.removeAll()
        model.$query
            .dropFirst()
            .sink { [weak self] _ in self?.handleQueryChange() }
            .store(in: &cancellables)
    }

    private func handleQueryChange() {
        guard let model else { return }
        ZSLog("clipboard: query changed, len=\(model.query.count)")
        model.selectedIndex = 0
        // 搜索变化只重算列表，不自动展开预览：展开必须由用户停留/移动选择触发
        pendingPreview?.cancel()
        pendingPreview = nil
        let wasPreviewing = model.previewItem != nil
        if wasPreviewing {
            model.previewItem = nil
        }
        applyFrame(animated: wasPreviewing)
    }

    private func hover(_ index: Int) {
        guard let model, index != model.selectedIndex else { return }
        ZSLog("clipboard: hover row \(index)")
        model.selectedIndex = index
        schedulePreview()
    }

    private func select(_ index: Int) {
        guard let model else { return }
        model.selectedIndex = index
        pasteSelected()
    }

    private func moveSelection(by step: Int) {
        guard let model else { return }
        let count = model.filteredItems.count
        guard count > 0 else { return }
        model.selectedIndex = (model.selectedIndex + step + count) % count
        schedulePreview()
    }

    /// 停留计时：未展开时到点展开；已展开时立即换成当前选中项的内容（不再重复等）
    private func schedulePreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard let panel, panel.isVisible, let model else { return }
        guard let item = model.selectedItem else {
            if model.previewItem != nil {
                model.previewItem = nil
                applyFrame(animated: true)
            }
            return
        }
        if model.previewItem != nil {
            if model.previewItem?.id != item.id { model.previewItem = item }
            return
        }
        let expectedID = item.id
        let delay = max(200, SettingsStore.shared.clipboardPreviewDelayMs)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let model = self.model, panel.isVisible,
                  model.selectedItem?.id == expectedID else { return }
            model.previewItem = item
            self.previewSide = self.hasSpaceOnRight ? .right : .left
            self.applyFrame(animated: true)
        }
        pendingPreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay) / 1000, execute: work)
    }

    // MARK: - 键盘

    private func installKeyMonitorOnce() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isVisible, event.window === panel else {
                return event
            }
            switch event.keyCode {
            case 53: // esc
                self.dismiss()
                return nil
            case 125: // ↓
                self.moveSelection(by: 1)
                return nil
            case 126: // ↑
                self.moveSelection(by: -1)
                return nil
            case 36, 76: // return / enter
                self.pasteSelected()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - 粘贴

    private func pasteSelected() {
        guard let model, let item = model.selectedItem else { return }
        ZSLog("clipboard paste: kind=\(item.kind.rawValue), bytes=\(item.byteCount)")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.kind {
        case .text:
            pasteboard.setString(item.text, forType: .string)
        case .image:
            guard let data = ClipboardHistoryStore.shared.pngData(for: item),
                  let image = NSImage(data: data) else {
                ZSLog("clipboard: image unavailable for paste")
                return
            }
            pasteboard.writeObjects([image])
        }
        // 自己写入的剪贴板不记入历史
        ClipboardMonitor.shared.markCurrentChangeCountAsHandled()

        let canPaste = AccessibilityPermission.isGranted
        dismiss()
        guard canPaste else {
            ZSLog("clipboard: copied only (no accessibility permission)")
            return
        }
        // 等面板真正收起、原窗口重新拿到 key 后再注入 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Self.postCommandV()
        }
    }

    /// 合成 ⌘V（需要辅助功能权限）；原应用自始至终是前台，按键直接落到原输入框
    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let keyV = CGKeyCode(9)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - 布局

    private var hasSpaceOnRight: Bool {
        guard let screen = anchorScreen else { return true }
        let needed = baseX + ClipboardPanelMetrics.listWidth + ClipboardPanelMetrics.dividerWidth
            + ClipboardPanelMetrics.previewWidth + 8
        return needed <= screen.visibleFrame.maxX
    }

    private func collapsedSize(rowCount: Int) -> NSSize {
        NSSize(width: ClipboardPanelMetrics.listWidth,
               height: ClipboardPanelMetrics.height(for: rowCount))
    }

    /// 锚点：优先贴着插入点（面板顶边在光标行下方 8pt，空间不够翻到上方），取不到插入点时退回鼠标右下
    private func positionCollapsed(anchor: NSRect?) {
        guard let panel, let model else { return }
        let size = collapsedSize(rowCount: model.filteredItems.count)
        let mouse = NSEvent.mouseLocation
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        anchorScreen = screen
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let gap: CGFloat = 8

        var x: CGFloat
        var topY: CGFloat
        if let anchor {
            x = anchor.minX
            topY = anchor.minY - gap
            if topY - size.height < visible.minY + gap {
                // 下方放不下：翻到插入点上方
                topY = anchor.maxY + gap + size.height
            }
        } else {
            x = mouse.x + 12
            topY = mouse.y - 12
        }
        x = min(max(x, visible.minX + gap), max(visible.minX + gap, visible.maxX - size.width - gap))
        topY = min(max(topY, visible.minY + size.height + gap), visible.maxY - gap)
        baseX = x
        anchorTopY = topY
        previewSide = hasSpaceOnRight ? .right : .left
        if let anchor {
            ZSLog("clipboard: anchor caret=\(Int(anchor.minX)),\(Int(anchor.minY)) \(Int(anchor.width))x\(Int(anchor.height))")
        } else {
            ZSLog("clipboard: anchor fallback mouse=\(Int(mouse.x)),\(Int(mouse.y))")
        }
        panel.setFrame(NSRect(x: x, y: topY - size.height, width: size.width, height: size.height),
                       display: false)
    }

    private func applyFrame(animated: Bool) {
        guard let panel, let model else { return }
        let visible = anchorScreen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var height = ClipboardPanelMetrics.height(for: model.filteredItems.count)
        height = min(height, visible.height - 16)
        let previewing = model.previewItem != nil
        let expandedWidth = ClipboardPanelMetrics.listWidth + ClipboardPanelMetrics.dividerWidth
            + ClipboardPanelMetrics.previewWidth
        let width = previewing ? expandedWidth : ClipboardPanelMetrics.listWidth

        var x = baseX
        if previewing, previewSide == .left {
            x = baseX - ClipboardPanelMetrics.previewWidth - ClipboardPanelMetrics.dividerWidth
        }
        x = min(max(x, visible.minX + 8), max(visible.minX + 8, visible.maxX - width - 8))
        var y = anchorTopY - height
        y = min(max(y, visible.minY + 8), max(visible.minY + 8, visible.maxY - height - 8))

        let frame = NSRect(x: x, y: y, width: width, height: height)
        ZSLog("clipboard: frame -> x=\(Int(x)) top=\(Int(y + height)) \(Int(width))x\(Int(height)) preview=\(previewing) side=\(previewSide) animated=\(animated)")
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    // MARK: - 面板与内容

    private func ensurePanel() -> ClipboardPanel? {
        if let panel { return panel }
        let panel = ClipboardPanel()
        panel.delegate = self
        self.panel = panel
        installKeyMonitorOnce()
        return panel
    }

    private func installContent(_ model: ClipboardViewModel) {
        guard let panel else { return }
        let root = ClipboardPanelView(
            model: model,
            onSelect: { [weak self] index in self?.select(index) },
            onHover: { [weak self] index in self?.hover(index) }
        )
        let size = collapsedSize(rowCount: model.filteredItems.count)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let background = makeBackground(size: size)
        container.addSubview(background)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // hosting 必须靠 autoresizing 跟随宿主：挂 glass.contentView 或用约束会反向钳死窗口尺寸（DEV-024）
        container.addSubview(hosting)
        panel.contentView = container
        panel.setContentSize(size)
    }

    /// 背景：macOS 26+ 原生液态玻璃（样式与系统一致，跟随外观/降低透明度），旧系统回退磨砂
    private func makeBackground(size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.autoresizingMask = [.width, .height]

        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: container.bounds)
            glass.style = .regular
            glass.cornerRadius = ClipboardPanelMetrics.cornerRadius
            glass.autoresizingMask = [.width, .height]
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: container.bounds)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = ClipboardPanelMetrics.cornerRadius
            effect.layer?.masksToBounds = true
            effect.autoresizingMask = [.width, .height]
            backdrop = effect
        }
        container.addSubview(backdrop)
        return container
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }
}
