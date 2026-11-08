import AppKit
import CoreGraphics

/// 内置 ⌘⇥ 窗口缩略图切换器：接管系统 Cmd+Tab，改为显示窗口缩略图面板供选择切换。
///
/// 实现要点（结构仿 `DockClickMinimizer`）：
/// - 用 `CGEvent.tapCreate(.cghidEventTap, .headInsertEventTap, .defaultTap)` 拦截
///   keyDown/keyUp/flagsChanged，把系统切换器完全吞掉。
/// - 事件回调只做「决策 + 吞事件」，枚举/抓图/激活全部异步（主线程或后台队列）。
/// - 会话状态机：⌘⇥ 开始会话并弹面板，⇥/⇧⇥ 前进后退（含按住自动连发），
///   Esc 取消，松开配置修饰键立即激活选中窗口。
/// - 授权前 tap 创建失败时每 2s 周期重试（授权返回自动生效，无需重启）；
///   tap 被系统暂停时 `tapEnable` 恢复。
/// - 开关关闭时 suspend() 完全移除 tap，恢复系统默认 ⌘⇥ 行为，零残留。
final class CommandTabSwitcher {
    static let shared = CommandTabSwitcher()

    /// 开关变化通知：由 SettingsStore.cmdTabSwitcherEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.cmdTabSwitcherDidChange")
    /// 快捷键变化通知：由 SettingsStore.cmdTabShortcut 的 didSet 触发
    static let shortcutDidChangeNotification = Notification.Name("zeroflow.cmdTabShortcutDidChange")

    private let lock = NSLock()
    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: - 会话状态（tap 线程读写；面板/模型只由主线程操作）

    private var sessionActive = false
    private var sessionGeneration = 0
    /// 绝对选中下标（0..count-1）；前进/后退环绕（末尾→开头、开头→末尾）。
    private var selectionIndex = 0
    /// Shift 是否处于按下状态：由 flagsChanged 显式跟踪。
    /// 比直接从 keyDown 的 flags 判 shift 更可靠（HID 级 tap 上 keyDown flags 偶发滞后）。
    private var shiftHeld = false

    /// 面板与展示模型（仅主线程访问）
    private var panel: WindowSwitcherPanel?
    private var model: WindowSwitcherViewModel?

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleShortcutDidChange(_:)),
            name: Self.shortcutDidChangeNotification,
            object: nil
        )
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.cmdTabSwitcherEnabled {
            start()
        } else {
            stop()
        }
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    @objc private func handleShortcutDidChange(_ notification: Notification) {
        // 会话进行中不打断；回调每次实时读配置，下一次触发即用新快捷键
        ZSLog("CommandTabSwitcher: shortcut changed, next trigger uses new combo")
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.cmd-tab"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    private func stop() {
        lock.lock()
        let wasRunning = isRunning
        isRunning = false
        let wasActive = sessionActive
        sessionActive = false
        selectionIndex = 0
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        if wasActive {
            DispatchQueue.main.async { [weak self] in
                self?.dismissSession()
            }
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        if wasRunning {
            ZSLog("CommandTabSwitcher: stopped, system ⌘⇥ restored")
        }
    }

    private func runTapLoop() {
        guard let runLoop = CFRunLoopGetCurrent() else { return }
        lock.lock(); tapRunLoop = runLoop; lock.unlock()
        installTap(in: runLoop)
        // 兜底：tap 创建失败（如权限授权晚了）时周期重试，授权后无需重启即生效
        installRetryTimer(in: runLoop)
        CFRunLoopRun()
    }

    private func installTap(in runLoop: CFRunLoop) {
        let mask = CGEventMask(
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("CommandTabSwitcher: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("CommandTabSwitcher: tap installed OK (⌘⇥ intercepted)")
    }

    private func installRetryTimer(in runLoop: CFRunLoop) {
        var ctx = CFRunLoopTimerContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 2,
            2,
            0,
            0,
            Self.retryTimerCallback,
            &ctx
        )
        if let timer { CFRunLoopAddTimer(runLoop, timer, .commonModes) }
    }

    private func retryCreateTapIfNeeded() {
        lock.lock()
        let missing = eventTap == nil && isRunning
        let runLoop = tapRunLoop
        lock.unlock()
        if missing, let runLoop { installTap(in: runLoop) }
    }

    // MARK: - 事件回调

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let switcher = Unmanaged<CommandTabSwitcher>.fromOpaque(info).takeUnretainedValue()
        return switcher.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let switcher = Unmanaged<CommandTabSwitcher>.fromOpaque(info).takeUnretainedValue()
        switcher.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.cmdTabSwitcherEnabled else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过（事件原样放行，系统切换器不受影响）
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        let shortcut = SettingsStore.shared.cmdTabShortcut
        guard shortcut.isValid else { return Unmanaged.passUnretained(event) }

        switch type {
        case .keyDown: return handleKeyDown(event, shortcut)
        case .keyUp: return handleKeyUp(event, shortcut)
        case .flagsChanged: return handleFlagsChanged(event, shortcut)
        default: return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - 事件处理（对应 FR-16.4 表格）

    private func handleKeyDown(_ event: CGEvent, _ shortcut: ShortcutKey) -> Unmanaged<CGEvent>? {
        let flags = event.flags
        let keyCode = keyCode(of: event)
        let isConfigKey = keyCode == shortcut.keyCode && hasConfigModifiers(shortcut, flags)
        let isBackward = (shiftHeld || flags.contains(.maskShift)) && !shortcut.modifiers.contains(.shift)

        if isConfigKey || isSessionActive() {
            debugLog("TAP keyDown keyCode=\(keyCode) flags=0x\(String(flags.rawValue, radix: 16)) shiftHeld=\(shiftHeld) session=\(isSessionActive()) backward=\(isBackward)")
        }

        if isConfigKey {
            if isSessionActive() {
                moveSelection(by: isBackward ? -1 : 1)
            } else {
                beginSession(backward: isBackward)
            }
            return nil // 吞掉，系统切换器不出现
        }

        if isSessionActive() {
            if keyCode == 53 { // Esc 取消会话
                cancelSession()
                return nil
            }
            // 方向键：左/右 环绕 ±1；上/下 ±一行（行宽 = min(tiles, 6)，与面板列数一致）
            switch keyCode {
            case 123: moveSelectionArrow(dx: -1, dy: 0); return nil
            case 124: moveSelectionArrow(dx: 1, dy: 0); return nil
            case 126: moveSelectionArrow(dx: 0, dy: -1); return nil
            case 125: moveSelectionArrow(dx: 0, dy: 1); return nil
            default: break
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleKeyUp(_ event: CGEvent, _ shortcut: ShortcutKey) -> Unmanaged<CGEvent>? {
        if isSessionActive() && keyCode(of: event) == shortcut.keyCode {
            return nil // 吞掉配置主键的 keyUp，避免系统收到残片
        }
        return Unmanaged.passUnretained(event)
    }

    private func keyCode(of event: CGEvent) -> UInt16 {
        UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func handleFlagsChanged(_ event: CGEvent, _ shortcut: ShortcutKey) -> Unmanaged<CGEvent>? {
        shiftHeld = event.flags.contains(.maskShift)
        if isSessionActive() {
            if !hasConfigModifiers(shortcut, event.flags) {
                // 配置修饰键抬起 → 激活选中窗口
                debugLog("TAP flagsChanged activate sessionActive=true flags=0x\(String(event.flags.rawValue, radix: 16))")
                activateSelected()
                return nil
            }
            // 其他修饰键（如 ⇧）变化：放行
            return Unmanaged.passUnretained(event)
        }
        return Unmanaged.passUnretained(event)
    }

    private func hasConfigModifiers(_ shortcut: ShortcutKey, _ flags: CGEventFlags) -> Bool {
        let modifiers = shortcut.modifiers
        if modifiers.contains(.command), !flags.contains(.maskCommand) { return false }
        if modifiers.contains(.option), !flags.contains(.maskAlternate) { return false }
        if modifiers.contains(.control), !flags.contains(.maskControl) { return false }
        if modifiers.contains(.shift), !flags.contains(.maskShift) { return false }
        return true
    }

    /// ZEROFLOW_SWITCHER_DEBUG=1 时输出事件级日志
    private func debugLog(_ message: String) {
        if ProcessInfo.processInfo.environment["ZEROFLOW_SWITCHER_DEBUG"] == "1" {
            ZSLog(message)
        }
    }

    // MARK: - 会话

    private func isSessionActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionActive
    }

    private func isSessionLive(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessionActive && sessionGeneration == generation
    }

    private func beginSession(backward: Bool) {
        lock.lock()
        sessionActive = true
        sessionGeneration += 1
        // 默认选中：前进 → index 1（上一个窗口）；后退 → index 0（当前窗口）
        selectionIndex = backward ? 0 : 1
        let generation = sessionGeneration
        lock.unlock()
        ZSLog("CommandTabSwitcher: session begin gen=\(generation) backward=\(backward)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let windows = WindowList.shared.enumerate()
            DispatchQueue.main.async {
                guard let self, self.isSessionLive(generation) else { return }
                self.presentSession(windows: windows, generation: generation)
            }
        }
    }

    /// 主线程：构建瓦片，抓完缩略图再弹面板（避免先图标后缩略图的闪烁）。
    /// 250ms 兜底：抓图过慢时也照常弹（未就绪的瓦片显示 app 图标，见 FR-18.6）。
    private func presentSession(windows: [SwitcherWindow], generation: Int) {
        guard isSessionLive(generation) else { return }
        guard !windows.isEmpty else {
            lock.lock(); sessionActive = false; lock.unlock()
            ZSLog("CommandTabSwitcher: no windows to show, session ended silently")
            return
        }

        let model = ensureModel()
        model.tiles = windows
        let count = windows.count
        lock.lock()
        selectionIndex = Self.wrappedIndex(selectionIndex, count: count)
        let index = selectionIndex
        lock.unlock()
        model.selectedIndex = index

        var didPresent = false
        let present = { [weak self] in
            guard let self, !didPresent, self.isSessionLive(generation) else { return }
            didPresent = true
            let panel = self.ensurePanel()
            panel.centerOnMouseScreen()
            panel.orderFront(nil)
            self.assertPanelVisible(panel, generation: generation)
        }

        WindowThumbnailer.shared.fetchThumbnails(for: windows.filter { !$0.isWindowlessApp }) { [weak self] images in
            guard let self, self.isSessionLive(generation) else { return }
            self.applyThumbnails(images)
            present()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            _ = self
            present()
        }
    }

    /// 全屏 Space 下面板偶发不显示（FR-20.5 复检）：orderFront 后延迟复检。仅 `orderFront` 无法把
    /// 窗口从旧 Space 挪到当前 Space，因此不可见 / 不在活跃 Space 时直接重建面板（新窗口落在当前 Space）。
    private func assertPanelVisible(_ panel: WindowSwitcherPanel, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.isSessionLive(generation) else { return }
            if !panel.isVisible || !panel.isOnActiveSpace {
                ZSLog("CommandTabSwitcher: panel not visible / not on active space, re-creating")
                let fresh = self.ensurePanel()
                fresh.centerOnMouseScreen()
                fresh.orderFront(nil)
                fresh.order(.above, relativeTo: 0)
            }
        }
    }

    /// 按 delta 移动选择（delta 以选中格计；任意线程可调用，UI 更新统一落主线程）。
    /// 绝对下标 + 环绕：到末尾再前进回到开头，到开头再后退回到末尾。
    private func moveSelection(by delta: Int) {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        selectionIndex += delta
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.applySelection()
        }
    }

    /// 方向键移动（主线程）：左右 ±1（环绕）；上下移动到相邻行里「渲染位置」最接近当前窗口的窗口
    /// （末行不满时会居中显示，因此按渲染列（含居中偏移）比较横向距离，而不是按行内原始列号——
    /// 这样从任意列按↓/↑ 最多横向偏 1 列，不会跳到远端）。没有相邻行则原地不动。
    private func moveSelectionArrow(dx: Int, dy: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let model = self.model else { return }
            let count = model.tiles.count
            guard count > 0 else { return }

            if dx != 0 {
                self.moveSelection(by: dx)
                return
            }

            let columns = min(count, switcherColumns)
            let current = model.selectedIndex
            let currentRow = current / columns
            let currentCol = current % columns

            let targetRow = currentRow + dy
            let rowStart = targetRow * columns
            guard targetRow >= 0, rowStart < count else { return } // 没有相邻行，不动
            let rowEnd = min(rowStart + columns, count) - 1

            // 某行的第 colInRow 个窗口的「渲染列」：行内不足 columns 个时整体居中 → 加偏移 (columns-count)/2
            func renderedCol(_ rowStart: Int, _ rowEnd: Int, _ colInRow: Int) -> CGFloat {
                let rowCount = rowEnd - rowStart + 1
                return CGFloat(columns - rowCount) / 2 + CGFloat(colInRow)
            }

            let currentRendered = renderedCol(currentRow * columns,
                                              min(currentRow * columns + columns, count) - 1,
                                              currentCol)
            var best = rowStart
            var bestDist = CGFloat.greatestFiniteMagnitude
            for idx in rowStart...rowEnd {
                let dist = abs(renderedCol(rowStart, rowEnd, idx - rowStart) - currentRendered)
                if dist < bestDist { bestDist = dist; best = idx }
            }
            self.lock.lock()
            self.selectionIndex = best
            self.lock.unlock()
            model.selectedIndex = best
        }
    }

    /// 主线程：把选中下标环绕到 [0, count-1] 并刷新（tiles 空时直接返回）。
    private func applySelection() {
        guard let model = self.model else { return }
        let count = model.tiles.count
        guard count > 0 else { return }
        lock.lock()
        selectionIndex = Self.wrappedIndex(selectionIndex, count: count)
        let index = selectionIndex
        lock.unlock()
        model.selectedIndex = index
    }

    /// 绝对下标环绕到 [0, count-1]（count ≤ 0 时原样返回）
    private static func wrappedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return index }
        var i = index % count
        if i < 0 { i += count }
        return i
    }

    private func activateSelected() {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        sessionActive = false
        lock.unlock()
        ZSLog("CommandTabSwitcher: modifier released, activating")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = self.model?.selectedWindow
            self.dismissSession()
            if let window { WindowActivator.shared.focus(window: window) }
        }
    }

    private func cancelSession() {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        sessionActive = false
        lock.unlock()
        ZSLog("CommandTabSwitcher: Esc, session cancelled")
        DispatchQueue.main.async { [weak self] in
            self?.dismissSession()
        }
    }

    /// 面板瓦片点击：立即切换该窗口（由面板视图在主线程调用）
    func activateWindow(id: CGWindowID) {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        sessionActive = false
        lock.unlock()
        ZSLog("CommandTabSwitcher: tile clicked wid=\(id)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let window = self.model?.tiles.first { $0.id == id }
            self.dismissSession()
            if let window { WindowActivator.shared.focus(window: window) }
        }
    }

    /// 主线程：收起面板并清空内容状态
    private func dismissSession() {
        panel?.orderOut(nil)
        model?.tiles = []
        model?.selectedIndex = 0
    }

    private func applyThumbnails(_ images: [CGWindowID: NSImage]) {
        guard let model else { return }
        model.tiles = model.tiles.map { tile in
            guard let image = images[tile.id] else { return tile }
            var updated = tile
            updated.thumbnail = image
            return updated
        }
    }

    private func ensureModel() -> WindowSwitcherViewModel {
        if let model { return model }
        let model = WindowSwitcherViewModel()
        self.model = model
        return model
    }

    /// 每次会话重建面板：旧面板复用会保留过期的 Space 归属（全屏 Space 创建后旧面板可能仍挂在
    /// 已隐藏的旧 Space 上，orderFront 只重排 z 序、不纠正 Space 归属）。新窗口创建时一定落在当前
    /// 活跃 Space 上，`.canJoinAllSpaces + .fullScreenAuxiliary` 保证在所有 Space（含全屏）可见。
    /// 缩略图在 `model.tiles`（`ensureModel()` 仍复用），重建面板零副作用、不重新抓图。
    private func ensurePanel() -> WindowSwitcherPanel {
        panel?.orderOut(nil)
        let panel = WindowSwitcherPanel(
            model: ensureModel(),
            glassBackground: SettingsStore.shared.windowSwitcherGlassBackground,
            onSelect: { [weak self] id in
                self?.activateWindow(id: id)
            },
            onAction: { [weak self] id, op in
                self?.performAction(op, on: id)
            }
        )
        self.panel = panel
        return panel
    }

    /// 面板卡片操作按钮（主线程）：执行退出/关闭/最小化/全屏，随后从面板移除受影响窗口。
    /// 退出应用移除该 pid 全部窗口；其余移除该窗口；列表空则收起面板。
    func performAction(_ op: WindowOperation, on id: CGWindowID) {
        lock.lock()
        guard sessionActive else { lock.unlock(); return }
        lock.unlock()
        ZSLog("CommandTabSwitcher: action \(op) wid=\(id)")
        guard let window = model?.tiles.first(where: { $0.id == id }) else { return }

        WindowOps.perform(op, on: window, then: { [weak self] in
            guard let self, let model = self.model else { return }
            if op == .quitApp {
                model.tiles = model.tiles.filter { $0.pid != window.pid }
            } else {
                model.tiles = model.tiles.filter { $0.id != id }
            }
            if model.tiles.isEmpty {
                self.dismissSession()
            } else if model.selectedIndex >= model.tiles.count {
                model.selectedIndex = model.tiles.count - 1
            }
        })
    }

    // MARK: - 独立诊断探针（ZEROFLOW_SWITCHER_DEBUG=1 启动时执行）

    static func runDebugProbe() {
        let enabled = SettingsStore.shared.cmdTabSwitcherEnabled
        let axGranted = AccessibilityPermission.isGranted
        ZSLog("SWITCHER-DEBUG enabled=\(enabled) AXTrusted=\(axGranted) tapInstalled=\(axGranted && enabled) (see 'tap installed' log line when installed)")
        let windows = WindowList.shared.enumerate()
        var byApp: [String: Int] = [:]
        for w in windows { byApp[w.appName, default: 0] += 1 }
        let minimized = windows.filter { $0.isMinimized }.count
        ZSLog("SWITCHER-DEBUG windows=\(windows.count) minimized=\(minimized)")
        for (name, count) in byApp.sorted(by: { $0.key < $1.key }) {
            ZSLog("SWITCHER-DEBUG   app '\(name)' → \(count) windows")
        }
        if windows.isEmpty {
            ZSLog("SWITCHER-DEBUG   (no windows listed)")
        }

        // 原始窗口 dump（过滤前）：核对幽灵条/小 chrome 窗口是否被排除
        if let rawInfo = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] {
            var layer0 = 0
            var kept = 0
            for dict in rawInfo {
                let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? (dict[kCGWindowLayer as String] as? Int ?? -1)
                guard layer == 0 else { continue }
                layer0 += 1
                let num = (dict[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? (dict[kCGWindowNumber as String] as? UInt32 ?? 0)
                let owner = dict[kCGWindowOwnerName as String] as? String ?? "?"
                let name = dict[kCGWindowName as String] as? String ?? ""
                let onscreen = (dict[kCGWindowIsOnscreen as String] as? Bool) ?? false
                let ws = (dict["kCGWindowWorkspace"] as? NSNumber)?.intValue ?? -99
                let b = (dict[kCGWindowBounds as String] as? [String: Any]) ?? [:]
                let w = (b["Width"] as? NSNumber)?.doubleValue ?? 0
                let h = (b["Height"] as? NSNumber)?.doubleValue ?? 0
                if layer0 <= 25 {
                    ZSLog("SWITCHER-DEBUG   raw wid=\(num) owner='\(owner)' size=\(Int(w))x\(Int(h)) onscreen=\(onscreen) ws=\(ws) title='\(name)'")
                }
                if h >= 48, (!name.isEmpty || onscreen || max(w, h) >= 400) { kept += 1 }
            }
            ZSLog("SWITCHER-DEBUG raw layer0=\(layer0) estimatedKept=\(kept)")
        }

        ZSLog("SWITCHER-DEBUG phantomDetection=\(CGSWindowServer.shared.isAvailable) (CGS/SLS available; else heuristic fallback)")

        // 缩略图抓取自检：试抓前 3 个窗口，报成功张数（区分「缺屏幕录制权限」与「抓取逻辑」问题）
        let probeWindows = Array(windows.prefix(3))
        ZSLog("SWITCHER-DEBUG capture probe on \(probeWindows.count) windows (screenRec=\(ScreenRecordingPermission.isGranted))")
        if !probeWindows.isEmpty {
            WindowThumbnailer.shared.fetchThumbnails(for: probeWindows) { images in
                ZSLog("SWITCHER-DEBUG   capture probe result: \(images.count)/\(probeWindows.count) thumbnails")
            }
        }
    }
}