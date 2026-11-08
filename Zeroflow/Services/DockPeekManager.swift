import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// Dock 快捷键弹出（自动隐藏时）：按下预设修饰键热键（默认裸 Option）并松开，
/// 记录当前指针位置 → 合成 mouseMoved 把指针短暂贴到 Dock 所在屏幕边缘 →
/// 停留 `dockPeekHoldMs` 后把指针移回原位。
/// 不读写系统 autohide 设置：指针贴边时 macOS 自己弹出 Dock，
/// 指针离开边缘时 macOS 自己收起 Dock。
///
/// 实现要点：
/// - 裸修饰键热键无法走 `GlobalHotkeyManager` 的 Carbon
///   `RegisterEventHotKey`（必须有主键），改用 listen-only CGEventTap 监听
///   flagsChanged **精确匹配**修饰键组合，且只在「按下→松开期间没有出现任何
///   其他按键/鼠标按下」时触发，保证 Option 兼作 ⌥` 切换器、打字变音等
///   正常修饰键用法时不误触发。
/// - 合成移动事件带 source userData 魔数（与 DockClickMinimizer 的合成
///   mouseDown 同一手法），`DockHoverPreviewController` 据此放行，避免指针
///   瞬移途中误触发 Dock 悬停预览面板。
/// - peek 动作在后台串行队列执行：generation 防重入，驻留期间出现鼠标按下
///   则立即还原并作废在途回调。
final class DockPeekManager {
    static let shared = DockPeekManager()

    /// 外部通知：由 SettingsStore.dockPeekEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockPeekDidChange")
    /// 外部通知：由 SettingsStore.dockPeekShortcut 的 didSet 触发（tap 为懒读配置，仅用于日志/订阅者）
    static let shortcutDidChangeNotification = Notification.Name("zeroflow.dockPeekShortcutDidChange")

    /// 合成移动事件的 source userData 魔数，跨服务识别「zeroflow 自己的瞬移」
    static let syntheticEventUserData: UInt64 = 0x5A5A_7A00_0000_0002

    /// 合成指针移动的提前量：先移到距边缘 inFromEdgePt 的内侧，再贴到边缘 +1，
    /// 两段式「走过去」保证边缘触发被系统感知（单次瞬移到边缘可能吞掉触发）。
    private static let inFromEdgePt: CGFloat = 8
    private static let nudgeDelay: TimeInterval = 0.06
    /// 按下→松开的最长间隔：超过视为正常修饰键长按，不触发
    private static let maxPressDuration: TimeInterval = 2.0
    /// 驻留时长设置的下限（毫秒），钳制极端值
    private static let minHoldMs = 150
    private static let maxHoldMs = 5000

    private let lock = NSLock()
    private var isRunning = false
    private var suspended = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let workQueue = DispatchQueue(label: "zeroflow.dock-peek", qos: .userInitiated)

    // MARK: - 热键状态机（tap 线程串行访问，无需加锁）

    /// 修饰键组合正按住（已触发过 press 判定）
    private var armed = false
    private var armedTime: CFTimeInterval = 0
    /// 按住期间出现过其他按键/鼠标事件：视为正常修饰键用法，松开不触发
    private var foreignSeen = false

    // MARK: - peek 在途（tap 线程与 workQueue 共享，经 lock）

    private var generation: UInt64 = 0
    private var inFlight = false
    /// 当前在途 peek 记录的原始指针位置（stop 兜底还原用）
    private var inFlightOrigin: CGPoint = .zero

    private let debug: Bool = ProcessInfo.processInfo.environment["ZEROFLOW_DOCKPEEK_DEBUG"] == "1"

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

    // MARK: - 系统偏好读取

    /// 系统是否开启了 Dock 自动隐藏（「桌面与 Dock → 自动显示和隐藏 Dock」）
    static func readSystemAutohide() -> Bool {
        (CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? Bool) ?? false
    }

    enum DockEdge {
        case bottom, left, right
    }

    private static func readOrientation() -> DockEdge {
        switch CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockPeekEnabled {
            start()
        } else {
            stop()
        }
    }

    /// 快捷键录制期间暂停触发识别（录制结束恢复）
    func suspend() {
        lock.lock(); suspended = true; lock.unlock()
        dlog("suspended (recording)")
    }

    func resume() {
        lock.lock(); suspended = false; lock.unlock()
        dlog("resumed")
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    @objc private func handleShortcutDidChange(_ notification: Notification) {
        dlog("shortcut changed, arm state reset")
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        suspended = false
        lock.unlock()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-peek"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        ZSLog("DockPeek: started")
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        suspended = false
        armed = false
        let wasInFlight = inFlight
        let stopOrigin = inFlightOrigin
        inFlight = false
        generation += 1
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        // 在途 peek 兜底还原（generation 已作废，纯移回，避免功能关闭时指针留在边缘）
        if wasInFlight, stopOrigin != .zero {
            workQueue.async { [weak self] in
                self?.postSyntheticMove(to: stopOrigin)
                ZSLog("DockPeek: fallback restore to \(stopOrigin)")
            }
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        ZSLog("DockPeek: stopped")
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
        // listen-only：只旁观，不吞事件（修饰键/正常组合键行为均不受影响）
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let maskValue = CGEventMask(mask)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: maskValue,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockPeek: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockPeek: tap installed OK")
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

    // MARK: - 事件回调（tap 线程）

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, info in
        guard let info else { return Unmanaged.passUnretained(event) }
        let manager = Unmanaged<DockPeekManager>.fromOpaque(info).takeUnretainedValue()
        return manager.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let manager = Unmanaged<DockPeekManager>.fromOpaque(info).takeUnretainedValue()
        manager.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        defer { dlog("event \(type.rawValue) flags=\(event.flags.rawValue) gen=\(currentGeneration())") }
        guard SettingsStore.shared.dockPeekEnabled else { return Unmanaged.passUnretained(event) }
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }
        lock.lock(); let suspendedNow = suspended; lock.unlock()
        guard !suspendedNow else { return Unmanaged.passUnretained(event) }

        switch type {
        case .flagsChanged:
            handleFlagsChanged(mods: Self.modifiers(of: event.flags), at: event.location)
        case .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
             .rightMouseDown, .otherMouseDown:
            markForeign()
            if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
                abortInFlightIfAny()
            }
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    /// flagsChanged 状态机：
    /// - flags 恰好等于录制组合 → 登记按下；
    /// - 按住期间 flags 出现组合之外的修饰键 → 标记外部使用（组合手势）；
    /// - 组合中任一修饰键抬起（flags 成为组合的真子集）→ 松开，未见过外部
    ///   事件且时长 ≤ maxPressDuration 才触发 peek。
    private func handleFlagsChanged(mods: CGEventFlags, at point: CGPoint) {
        let target = Self.modifiers(of: Self.storedShortcutFlags())
        guard !target.isEmpty else { return }

        if mods == target {
            guard !armed else { return }
            armed = true
            armedTime = CFAbsoluteTimeGetCurrent()
            foreignSeen = false
            dlog("hotkey armed \(mods), point=\(point)")
            return
        }

        guard armed else { return }

        if mods.contains(target) {
            // 添加了组合之外的其他修饰键（如 Option 按住时再按 Shift）：
            // 在组成别的快捷键，本次按下作废
            foreignSeen = true
            dlog("extra modifier added while armed, foreign")
            return
        }

        // target 的真子集：组合中有一个修饰键被抬起 → 松开
        armed = false
        let elapsed = CFAbsoluteTimeGetCurrent() - armedTime
        guard !foreignSeen, elapsed <= Self.maxPressDuration else {
            dlog("released without trigger: foreign=\(foreignSeen) elapsed=\(elapsed)s")
            return
        }
        dlog("hotkey released, peek at edge, origin=\(point)")
        workQueue.async { [weak self] in
            self?.performPeek(from: point)
        }
    }

    private func markForeign() {
        guard armed else { return }
        armed = false
        foreignSeen = true
        dlog("other input during armed press, discarded")
    }

    private static func storedShortcutFlags() -> NSEvent.ModifierFlags {
        SettingsStore.shared.dockPeekShortcut.modifiers.intersection([.command, .shift, .option, .control])
    }

    private static func modifiers(of flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
    }

    /// NSEvent.ModifierFlags → CGEventFlags
    private static func modifiers(of flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result = CGEventFlags()
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        return result
    }

    // MARK: - peek 执行（workQueue 串行）

    private func performPeek(from origin: CGPoint) {
        guard SettingsStore.shared.dockPeekEnabled else { return }
        guard AccessibilityPermission.isGranted else { return }
        guard Self.readSystemAutohide() else {
            ZSLog("DockPeek: system autohide off, peek skipped")
            return
        }
        guard !CaptureCoordinator.shared.isActive else {
            dlog("capture active, peek skipped")
            return
        }
        // 拖拽/按住鼠标期间不做指针瞬移
        let buttonsDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
            || CGEventSource.buttonState(.combinedSessionState, button: .right)
        guard !buttonsDown else {
            dlog("mouse button held, peek skipped")
            return
        }

        guard let (edgePoint, insidePoint) = Self.dockEdgePoints() else {
            ZSLog("DockPeek: no screen found, peek skipped")
            return
        }

        let holdMs = min(max(SettingsStore.shared.dockPeekHoldMs, Self.minHoldMs), Self.maxHoldMs)

        lock.lock()
        generation += 1
        let gen = generation
        inFlight = true
        inFlightOrigin = origin
        lock.unlock()

        dlog("peek begin origin=\(origin) inside=\(insidePoint) edge=\(edgePoint) hold=\(holdMs)ms gen=\(gen)")
        postSyntheticMove(to: insidePoint)
        workQueue.asyncAfter(deadline: .now() + Self.nudgeDelay) { [weak self] in
            self?.postSyntheticMove(to: edgePoint)
        }
        workQueue.asyncAfter(deadline: .now() + TimeInterval(holdMs) / 1000.0) { [weak self] in
            self?.restoreIfCurrent(generation: gen, to: origin)
        }
    }

    /// 驻留到点后把指针移回原位（仅当 generation 仍是当前在途任务）。
    /// 驻留超时与中止（鼠标按下/停止功能）都走这里，先到先得并作废对方。
    private func restoreIfCurrent(generation gen: UInt64, to origin: CGPoint) {
        lock.lock()
        guard generation == gen else { lock.unlock(); return }
        inFlight = false
        generation += 1
        lock.unlock()
        postSyntheticMove(to: origin)
        ZSLog("DockPeek: pointer restored to \(origin), dock hide timing left to macOS")
    }

    private func abortInFlightIfAny() {
        lock.lock()
        guard inFlight else { lock.unlock(); return }
        let gen = generation
        let origin = inFlightOrigin
        lock.unlock()
        dlog("mouse down while in flight, aborting")
        workQueue.async { [weak self] in
            self?.restoreIfCurrent(generation: gen, to: origin)
        }
    }

    private func currentGeneration() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    // MARK: - 合成移动

    /// 合成 mouseMoved 把指针瞬移到目标点（带 userData 魔数，Dock 预览据此放行）
    private func postSyntheticMove(to point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        source.userData = Int64(Self.syntheticEventUserData)
        let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        move?.post(tap: .cghidEventTap)
        dlog("synthetic move to \(point)")
    }

    private static func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? NSEvent.mouseLocation.flippedPoint()
    }

    // MARK: - Dock 几何（CGEvent/AX 全局坐标 = 主屏左上原点）

    /// 返回 Dock 边缘的「贴边点」与「先到的内侧点」。
    /// Dock 屏幕取菜单栏所在主屏，方向读 com.apple.dock 的 orientation。
    private static func dockEdgePoints() -> (edge: CGPoint, inside: CGPoint)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let frame = CGRect(
            x: screen.frame.minX,
            y: union.maxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
        switch readOrientation() {
        case .left:
            let point = CGPoint(x: frame.minX + inFromEdgePt, y: frame.midY)
            return (CGPoint(x: frame.minX + 1, y: frame.midY), point)
        case .right:
            let point = CGPoint(x: frame.maxX - inFromEdgePt, y: frame.midY)
            return (CGPoint(x: frame.maxX - 1, y: frame.midY), point)
        case .bottom:
            let point = CGPoint(x: frame.midX, y: frame.maxY - inFromEdgePt)
            return (CGPoint(x: frame.midX, y: frame.maxY - 1), point)
        }
    }

    private func dlog(_ message: @autoclosure () -> String) {
        guard debug else { return }
        ZSLog("DockPeek: \(message())")
    }
}

private extension NSPoint {
    /// NSEvent.mouseLocation（左下原点）→ CGEvent 全局坐标（左上原点）
    func flippedPoint() -> CGPoint {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGPoint(x: x, y: union.maxY - y)
    }
}
