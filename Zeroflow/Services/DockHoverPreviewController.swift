import AppKit
import ApplicationServices
import CoreGraphics

/// Dock 悬停窗口预览：鼠标悬停在 Dock 应用图标（或最小化窗口瓦片）上，
/// 弹出该窗口集合的缩略图预览面板，点击卡片切换窗口、悬停卡片出关闭按钮。
///
/// 实现要点（结构仿 `DockClickMinimizer` / `CommandTabSwitcher`，Dock AX 探测为本模块
/// 独立拷贝，不与 DockClickMinimizer 共享实现，避免互相牵连回归）：
/// - CGEventTap `.listenOnly` 监听 mouseMoved + mouseDown，**绝不吞事件**，
///   Dock 原生行为（启动/聚焦/右键菜单/按住 App Exposé）与 DockClickMinimizer 零影响。
/// - move 回调内只做内存几何判定（缓存的 Dock 项 frame contains），零 AX 调用；
///   目标变化防抖（悬停延时）到期后才在后台做一次「AX 权威命中测试 + WindowList 枚举」，
///   放大/自动隐藏/缓存过期都由这次权威命中兜底。
/// - Dock 项缓存：AX 遍历 Dock 的 kAXWindows 树收集 AXApplicationDockItem；
///   app 项身份走 kAXURLAttribute（.app URL → bundleID），无 URL 项记录标题作为
///   「最小化窗口瓦片」候选（展示时按标题反查最小化窗口；堆栈/废纸篓通常匹配不到）。
/// - 窗口列表 = `WindowList.shared.enumerate()` 按 bundleID 过滤，与 ⌘⇥ 切换器**完全同源**
///   （含最小化与其他 Space 的窗口，不做特殊处理）；无窗口 app 不弹、无占位卡。
/// - 状态机：idle →(进入 Dock 边缘/命中图标)→ pending(延时) → visible；
///   visible 时鼠标移入面板保活（锚点冻结，图标缩放不跟随），移出 图标∪面板 宽限后隐藏。
/// - 全局隐藏：任意 mouseDown（放行原生行为）/ Space 切换 / 锁屏睡眠 / 目标 app 退出 /
///   Dock 重启 / 任意按键 / 屏幕配置变化。
/// - 快路径命中失败或缓存无效时，pending 定时器照常触发并走权威命中，因此缓存仅是
///   「相邻图标重定向」的优化项，不是正确性依赖。
/// - 自动隐藏 Dock：AX 给的是「隐藏位」坐标（整条落到屏幕边之外，比展开位低一条 Dock 高），
///   条带因此统一先吸附到最近的屏幕边再用于触发/闸门；权威命中失败时在 Dock 落位前短期
///   重试（指针停住后不再有 move 事件，只能自己轮询）。
final class DockHoverPreviewController {
    static let shared = DockHoverPreviewController()

    /// 开关变化通知：由 SettingsStore.dockPreviewEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.dockPreviewDidChange")

    private static let dockBundleID = "com.apple.dock"
    private static let dockItemRole = "AXApplicationDockItem"
    /// 触发/闸门对 Dock 条带 bbox 的外扩：触发稍早于进入，闸门拦截条带外的误命中（如放大图标的「空气区」）
    private static let stripTriggerMargin: CGFloat = 30
    private static let stripGateMargin: CGFloat = 16
    /// 闸门对「命中项自身 frame」的外扩容差：命中项就在指针下，只需微宽容差
    private static let resolvedItemGateSlack: CGFloat = 4
    /// 权威命中失败后的短期重试（自动隐藏 Dock 的展开动画竞态）：间隔与总窗口（s）
    private static let resolveRetryInterval: TimeInterval = 0.12
    private static let resolveRetryWindow: TimeInterval = 1.2
    /// 条带不可用时的边缘兜底触发宽度
    private static let edgeFallbackMargin: CGFloat = 150
    /// visible 后移出 图标∪面板(外扩) 的隐藏宽限（s）：给鼠标移向面板留时间
    private static let hideGrace: TimeInterval = 0.2
    /// 保活判定对 图标/面板 的外扩：吞掉两者之间的缝隙，慢速移动不掉出保活区
    private static let keepAliveInset: CGFloat = 6
    /// 兜底命中测试时向上找 dock 项的父级深度上限
    private static let parentWalkDepth = 8
    /// move 事件处理节流间隔（s）：几何判定足够快，但没必要每个 HID 事件都跑
    private static let moveThrottle: CFTimeInterval = 0.016
    /// 右键菜单抑制：菜单开合探针的节流间隔 / 进入抑制后的确认探针延时（s）
    private static let menuProbeInterval: CFTimeInterval = 0.2
    private static let menuConfirmDelay: TimeInterval = 0.5

    private enum Phase { case idle, pending, visible }

    /// 展示目标：app 图标（该 app 的全部窗口）或最小化窗口瓦片（按标题反查）
    private enum HoverTarget {
        case app(NSRunningApplication, frameTL: CGRect)
        case tile(title: String, frameTL: CGRect)

        var frameTL: CGRect {
            switch self {
            case .app(_, let frameTL): return frameTL
            case .tile(_, let frameTL): return frameTL
            }
        }
    }

    /// Dock 项缓存条目（frame 为「主屏左上原点」全局坐标，与 CGEvent/AX 一致）
    private struct DockItem {
        let id: Int
        let frame: CGRect
        let app: NSRunningApplication?
        let title: String
    }

    // MARK: - 状态（lock 保护；tap 线程 / workQueue / 主线程共用）

    private let lock = NSLock()
    private var phase: Phase = .idle
    /// show 工作代数：scheduleShow 递增使旧 show 作废；hidePanel/failResolve 也递增
    private var showGen = 0
    /// 宽限隐藏代数：移出 图标∪面板 后挂 200ms 宽限隐藏（给「移向面板」留时间），
    /// 回到区域内即取消；与 showGen 分开避免互相误杀
    private var hideGen = 0
    /// 当前悬停候选（缓存项 id；缓存重建后可能错位，仅作优化信号）
    private var hoverItemID: Int?
    /// 已调度、尚未触发的 show 工作代数（防同一停留重复调度）
    private var pendingShowGen: Int?
    private var lastMousePoint = CGPoint.zero
    private var lastMoveProcessedAt = CFTimeInterval(0)
    /// Dock 项缓存
    private var dockItems: [DockItem] = []
    private var cacheInvalid = true
    private var pendingCacheRebuild: DispatchWorkItem?
    /// visible 时锚点与面板 frame（topLeft 坐标），用于「移出图标∪面板」判定
    private var currentItemTL: CGRect?
    private var panelFrameTL: CGRect?
    /// 点击卡片激活后的防重弹：指针仍停留在同一图标区域内时不再次弹出
    private var suppressKey: String?
    private var suppressRegionTL: CGRect?
    /// Dock 右键菜单打开期间的预览抑制：期间不调度/弹出预览，探针确认菜单关闭后自动解除
    private var contextMenuGuardActive = false
    private var lastMenuProbeAt = CFTimeInterval(0)
    /// 权威命中失败的短期重试截止时刻（nil = 未在重试）
    private var retryDeadline: CFTimeInterval?

    // 主线程专用
    private var currentTarget: HoverTarget?
    private var currentWindows: [SwitcherWindow] = []
    private var panel: DockPreviewPanel?
    private let model = DockPreviewViewModel()
    private var keyMonitor: Any?
    /// 应用生命周期内的缩略图缓存（主线程读写）：抓到过就一直用，
    /// 悬停时先显旧图再换新图，避免 WindowThumbnailer TTL(5s)/节流(0.8s)导致的空面板
    private var thumbnailCache: [CGWindowID: NSImage] = [:]
    private var lastCacheRefreshAt = Date.distantPast
    /// 面板 orderFront 状态镜像（主线程）：软隐藏后置 false，present 后置 true
    private var panelShown = false

    // MARK: - 基础设施

    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "zeroflow.dock-hover-preview", qos: .userInitiated)
    private let cacheQueue = DispatchQueue(label: "zeroflow.dock-hover-cache")
    private static let debug: Bool = ProcessInfo.processInfo.environment["ZEROFLOW_DOCKPREVIEW_DEBUG"] == "1"

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidChange(_:)),
            name: Self.didChangeNotification,
            object: nil
        )
        observeHideTriggers()
    }

    // MARK: - 启停

    /// 按开关当前状态启停（启动时 / 开关变化时调用）
    func reapply() {
        if SettingsStore.shared.dockPreviewEnabled {
            start()
        } else {
            stop()
        }
    }

    @objc private func handleDidChange(_ notification: Notification) {
        reapply()
    }

    private func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        lock.unlock()

        dockLayoutMayHaveChanged()
        installKeyMonitor()

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.dock-hover-preview"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        // 启动预热：抓一次全量窗口缩略图进缓存（允许旧图），首次悬停即有图
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, SettingsStore.shared.dockPreviewEnabled else { return }
            let windows = WindowList.shared.enumerate().filter { !$0.isWindowlessApp }
            self.refreshThumbnailCacheAsync(for: windows)
        }
        ZSLog("DockHoverPreview: started")
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        contextMenuGuardActive = false
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        removeKeyMonitor()
        DispatchQueue.main.async { [weak self] in
            self?.panel?.orderOut(nil)
        }
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        ZSLog("DockHoverPreview: stopped")
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
        // listen-only：只旁观，不吞事件（Dock 原生行为、DockClickMinimizer 均不受影响）
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("DockHoverPreview: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("DockHoverPreview: tap installed OK")
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
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        return controller.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let controller = Unmanaged<DockHoverPreviewController>.fromOpaque(info).takeUnretainedValue()
        controller.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.dockPreviewEnabled else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }
        // DockPeek 合成的指针瞬移（按热键弹出 Dock 时贴边/还原）不参与悬停判定
        if event.getIntegerValueField(.eventSourceUserData) == Int64(DockPeekManager.syntheticEventUserData) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .mouseMoved:
            handleMouseMoved(event.location)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handleAnyMouseDown(at: event.location, type: type, flags: event.flags)
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 状态机（tap 线程决策，workQueue/主线程执行）

    private func isVisible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return phase == .visible
    }

    private func hoverDelay() -> TimeInterval {
        let ms = SettingsStore.shared.dockPreviewHoverDelayMs
        return TimeInterval(max(50, ms)) / 1000.0
    }

    private func setHoverItem(_ id: Int) {
        lock.lock()
        hoverItemID = id
        lock.unlock()
    }

    /// 缓存命中测试（纯内存几何，零 AX 调用）
    private func cachedItem(at point: CGPoint) -> (id: Int, item: DockItem)? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        // 倒序遍历（后画的在绘制层级更上层）
        for item in dockItems.reversed() where item.frame.contains(point) {
            return (item.id, item)
        }
        return nil
    }

    private func handleMouseMoved(_ point: CGPoint) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveProcessedAt < Self.moveThrottle {
            lastMousePoint = point // 记录最新点，节流不影响权威命中的取点
            lock.unlock()
            return
        }
        lastMoveProcessedAt = now
        lastMousePoint = point
        let currentPhase = phase
        let hoverID = hoverItemID
        let panelFrame = panelFrameTL
        let anchorFrame = currentItemTL
        lock.unlock()

        // Dock 右键菜单打开期间：探针确认仍开着则本事件不参与悬停判定，
        // 菜单关闭（探针解除抑制）后照常恢复
        if isContextMenuGuarded() {
            probeContextMenuOpen()
            if isContextMenuGuarded() { return }
        }

        let hit = cachedItem(at: point)

        // 离开抑制区域即解除防重弹
        lock.lock()
        if suppressKey != nil, let region = suppressRegionTL, !region.contains(point) {
            suppressKey = nil
            suppressRegionTL = nil
        }
        lock.unlock()
        switch currentPhase {
        case .idle:
            if let entry = hit {
                if entry.id != hoverID {
                    setHoverItem(entry.id)
                    scheduleShow(after: hoverDelay())
                }
                // 同一图标内移动不重置计时
            } else if isNearDockStrip(point) {
                // 缓存未命中（无效/过期/放大中图标横移）：指针在 Dock 条带附近才挂延时，
                // 到期后由 AX 权威命中判定真正目标
                scheduleShowIfNone(after: hoverDelay())
            }

        case .pending:
            if let entry = hit, entry.id != hoverID {
                setHoverItem(entry.id)
                scheduleShow(after: hoverDelay()) // 换图标：重置防抖
            }
            // 其余情况：定时器继续倒数，到期权威判定

        case .visible:
            if let entry = hit, entry.id != hoverID {
                setHoverItem(entry.id)
                bumpHideGen() // 取消可能挂着的宽限隐藏，避免它杀掉在途 show
                softHidePanel() // 换目标：旧面板立刻消失，避免残留与「扫过旧面板区域取消重弹」
                scheduleShow(after: hoverDelay()) // 相邻图标：延时后原位换内容
                return
            }
            // 面板显示中：仍在 (图标∪面板)±6pt 内 → 保活（外扩吞掉两者间缝隙，慢速移动不掉出）
            var inside = false
            if let anchorFrame, anchorFrame.insetBy(dx: Self.keepAliveInset, dy: Self.keepAliveInset).contains(point) { inside = true }
            if let panelFrame, panelFrame.insetBy(dx: Self.keepAliveInset, dy: Self.keepAliveInset).contains(point) { inside = true }
            if inside {
                bumpHideGen() // 取消已调度的宽限隐藏
            } else {
                // 移出保活区：不立即隐藏，挂 200ms 宽限隐藏——
                // 给「移向面板」留时间；在途 show（换目标重弹）时则交给 show 自行收尾
                lock.lock()
                let hasPendingShow = pendingShowGen != nil
                lock.unlock()
                if !hasPendingShow {
                    scheduleHideAfterGrace()
                }
            }
        }
    }

    private func handleAnyMouseDown(at point: CGPoint, type: CGEventType, flags: CGEventFlags) {
        lock.lock()
        let onPanel: Bool
        if let panelFrame = panelFrameTL, phase == .visible {
            onPanel = panelFrame.contains(point)
        } else {
            onPanel = false
        }
        let active = phase != .idle || pendingShowGen != nil
        lock.unlock()
        // 点击发生在自己面板上：放行（卡片点击/关闭钮需要收到这次 mouseDown），不隐藏
        if onPanel { return }
        // 右键（含 Ctrl+左键）落在 Dock 本体附近：大概率要弹 Dock 右键菜单，
        // 进入抑制直到菜单关闭——hidePanel 会清空 hoverItemID，否则指针在图标内
        // 稍一移动就会走 idle 分支重新 scheduleShow 弹出预览
        let menuOpener = type == .rightMouseDown
            || (type == .leftMouseDown && flags.contains(.maskControl))
        if menuOpener {
            enterContextMenuGuardIfDockZone(at: point)
        }
        // 其余任意 mouseDown：面板收起，事件放行（Dock 原生行为、DockClickMinimizer 不受影响）
        if active { hidePanel(reason: "mouseDown") }
    }

    // MARK: - 右键菜单抑制（Dock 菜单打开期间禁止弹出预览）

    private func isContextMenuGuarded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return contextMenuGuardActive
    }

    /// 右键打开 Dock 菜单只可能发生在 Dock 本体上：缓存命中图标，或 Dock 条带 bbox 外扩内。
    /// 不用 isNearDockStrip 的屏幕边缘兜底——屏幕中部右键不应进入抑制。
    private func isDockMenuLaunchZone(_ point: CGPoint) -> Bool {
        if cachedItem(at: point) != nil { return true }
        if let zone = dockRegionTL(margin: Self.stripTriggerMargin) {
            return zone.contains(point)
        }
        return false
    }

    private func enterContextMenuGuardIfDockZone(at point: CGPoint) {
        guard isDockMenuLaunchZone(point) else { return }
        lock.lock()
        let newlyArmed = !contextMenuGuardActive
        contextMenuGuardActive = true
        lock.unlock()
        if newlyArmed { ZSLog("DockHoverPreview: context menu guard on") }
        // 确认探针：菜单没真正弹出时（右键分隔符/空白处）尽快解除
        workQueue.asyncAfter(deadline: .now() + Self.menuConfirmDelay) { [weak self] in
            self?.probeContextMenuOpen(force: true)
        }
    }

    /// 节流探针：Dock AX 树里还挂着菜单 → 保持抑制；已关闭 → 解除。
    /// AX 扫描丢到 workQueue，不占用 tap 回调线程（listen-only 回调必须快）。
    private func probeContextMenuOpen(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard contextMenuGuardActive else { lock.unlock(); return }
        guard force || now - lastMenuProbeAt >= Self.menuProbeInterval else { lock.unlock(); return }
        lastMenuProbeAt = now
        lock.unlock()
        workQueue.async { [weak self] in
            guard let self else { return }
            let open = self.isDockContextMenuOpen()
            self.lock.lock()
            if self.contextMenuGuardActive && !open {
                self.contextMenuGuardActive = false
                ZSLog("DockHoverPreview: context menu guard off")
            }
            self.lock.unlock()
        }
    }

    /// Dock 应用元素的 AX 树里是否存在打开的菜单（右键菜单/子菜单）。
    /// resolveTarget 实测右键菜单元素可沿 Dock 层级命中（isMenuElement），浅层扫描即可。
    /// AX 调用失败一律视为未打开（自愈，避免抑制永久卡死）。
    private func isDockContextMenuOpen() -> Bool {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return false }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard var frontier = copyAXElements(dockElement, kAXChildrenAttribute), !frontier.isEmpty else { return false }
        for _ in 0..<3 {
            var next: [AXUIElement] = []
            for element in frontier {
                if isMenuElement(element) { return true }
                if let children = copyAXElements(element, kAXChildrenAttribute) {
                    next.append(contentsOf: children)
                }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return false
    }

    // MARK: - 调度

    /// 保活：取消待触发的宽限隐藏（不动在途 show）
    private func bumpHideGen() {
        lock.lock()
        hideGen += 1
        lock.unlock()
    }

    /// 宽限隐藏：移出 图标∪面板(外扩) 200ms 后仍在 visible 且无在途 show 才真正隐藏。
    /// 期间回到保活区（bumpHideGen）或调度了新 show（pendingShowGen 置位/作废本 hide）都会取消。
    private func scheduleHideAfterGrace() {
        lock.lock()
        hideGen += 1
        let h = hideGen
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + Self.hideGrace) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = h == self.hideGen && self.phase == .visible && self.pendingShowGen == nil
            self.lock.unlock()
            guard live else { return }
            self.hidePanel(reason: "left icon+panel region")
        }
    }

    private func scheduleShow(after delay: TimeInterval) {
        lock.lock()
        showGen += 1
        let g = showGen
        pendingShowGen = g
        retryDeadline = nil
        if phase == .idle { phase = .pending }
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pendingShowGen == g { self.pendingShowGen = nil }
            let live = g == self.showGen && (self.phase == .pending || self.phase == .visible)
            self.lock.unlock()
            guard live else { return }
            self.resolveAndShow(showGen: g)
        }
    }

    /// 仅当没有任何挂起的 show 时调度（防止边缘区连续移动重复触发）
    private func scheduleShowIfNone(after delay: TimeInterval) {
        lock.lock()
        let none = pendingShowGen == nil
        lock.unlock()
        guard none else { return }
        scheduleShow(after: delay)
    }

    /// 视觉上立刻收起面板（换目标/移出时），状态保持不变以便正常重弹。
    /// 同时清掉 panelFrameTL：保活区域随之收缩，指针扫过旧面板区域不再误判保活。
    private func softHidePanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panelShown else { return }
            self.panel?.orderOut(nil)
            self.panelShown = false
            self.lock.lock()
            self.panelFrameTL = nil
            self.lock.unlock()
        }
    }

    private func hidePanel(reason: String) {
        lock.lock()
        phase = .idle
        hoverItemID = nil
        pendingShowGen = nil
        currentItemTL = nil
        panelFrameTL = nil
        suppressKey = nil
        suppressRegionTL = nil
        retryDeadline = nil
        showGen += 1
        lock.unlock()
        ZSLog("DockHoverPreview: hide (\(reason))")
        let dismiss = { [weak self] in
            guard let self else { return }
            self.panel?.orderOut(nil)
            self.panelShown = false
            let shown = self.currentWindows
            self.currentTarget = nil
            self.currentWindows = []
            self.refreshThumbnailCacheAsync(for: shown)
        }
        if Thread.isMainThread {
            dismiss()
        } else {
            DispatchQueue.main.async(execute: dismiss)
        }
    }

    /// 静默刷新一批窗口的缩略图缓存（节流 3s），只补缓存不碰面板 UI。
    /// 用于启动预热与面板收起后，保证下次悬停立即有图（允许旧图）。
    private func refreshThumbnailCacheAsync(for windows: [SwitcherWindow]) {
        guard !windows.isEmpty else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCacheRefreshAt) > 3 else { return }
        lastCacheRefreshAt = now
        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
            guard let self else { return }
            for (windowID, image) in images {
                self.thumbnailCache[windowID] = image
            }
        }
    }
    // MARK: - 解析与展示（workQueue → 主线程）

    /// 延时到期：AX 权威命中 → 过滤窗口 → 主线程展示。
    /// 失败（不在 Dock 项上/命中右键菜单/目标无窗口）时回到 idle；面板已开则收起。
    private func resolveAndShow(showGen g: Int) {
        let point: CGPoint = {
            lock.lock(); defer { lock.unlock() }
            return lastMousePoint
        }()
        // 兜底：抑制期间到达的在途 show 一律不放行
        if isContextMenuGuarded() {
            failResolve(showGen: g, reason: "dock context menu open", retryable: false)
            return
        }
        let target: HoverTarget
        switch resolveTarget(at: point) {
        case .resolved(let resolved):
            target = resolved
        case .failed:
            // AX 偶发失败：用缓存身份兜底（缓存无效时 cachedItem 返回 nil，不会误弹）。
            // 注意仅在 AX 完全失败时兜底：右键菜单等「正常但非 Dock 项」不走这里，
            // 否则右键菜单悬在图标上时会弹出预览。
            if let entry = cachedItem(at: point) {
                if let app = entry.item.app {
                    target = .app(app, frameTL: entry.item.frame)
                } else if !entry.item.title.isEmpty {
                    target = .tile(title: entry.item.title, frameTL: entry.item.frame)
                } else {
                    failResolve(showGen: g, reason: "no dock item at point")
                    return
                }
            } else {
                failResolve(showGen: g, reason: "no dock item at point")
                return
            }
        case .notDockElement:
            failResolve(showGen: g, reason: "point is not a dock item")
            return
        }
        // 位置闸门：优先用「AX 权威命中到的图标自身 frame」（实时、不受 Dock 隐藏位影响），
        // 条带（已按自动隐藏吸附回屏幕边）仅作兜底，防止放大图标的「空气区」/远处误命中
        if Self.debug {
            let bar = dockBarFrameTL().map { "\($0)" } ?? "nil"
            let region = dockRegionTL(margin: Self.stripGateMargin).map { "\($0)" } ?? "nil"
            ZSLog("DockHoverPreview: resolve pt=\(point) item=\(target.frameTL) bar=\(bar) region=\(region)")
        }
        let onResolvedItem = target.frameTL.insetBy(dx: -Self.resolvedItemGateSlack, dy: -Self.resolvedItemGateSlack).contains(point)
        if !onResolvedItem, let gate = dockRegionTL(margin: Self.stripGateMargin), !gate.contains(point) {
            if Self.debug { ZSLog("DockHoverPreview: gate reject pt=\(point) strip=\(gate)") }
            failResolve(showGen: g, reason: "pointer outside dock strip")
            return
        }
        // 点击卡片激活后的防重弹：同一目标且指针仍在原图标区域内 → 不弹
        lock.lock()
        var suppressed = false
        if let region = suppressRegionTL, let key = suppressKey, region.contains(point) {
            suppressed = key == self.suppressKey(for: target)
        }
        lock.unlock()
        if suppressed {
            failResolve(showGen: g, reason: "suppressed after activate", retryable: false)
            return
        }
        let windows = windows(for: target)
        guard !windows.isEmpty else {
            failResolve(showGen: g, reason: "target has no windows", retryable: false)
            return
        }
        syncDockCache(with: target)
        DispatchQueue.main.async { [weak self] in
            self?.present(windows: windows, target: target, showGen: g, pointer: point)
        }
    }

    /// 权威命中失败/无窗口：指针仍在 Dock 区域内且 Dock 尚未落位时先短期重试
    /// （自动隐藏 Dock 的展开动画中图标坐标/命中结果还在变，而指针停住不再产生
    /// mouseMoved），重试用尽才回到 idle；面板已开着则在回 idle 时收起。
    private func failResolve(showGen g: Int, reason: String, retryable: Bool = true) {
        if retryable, scheduleResolveRetry(showGen: g, reason: reason) { return }
        lock.lock()
        let wasVisible = phase == .visible
        if g == self.showGen {
            phase = .idle
            hoverItemID = nil
            currentItemTL = nil
            panelFrameTL = nil
            retryDeadline = nil
            showGen += 1
            pendingShowGen = nil
        }
        lock.unlock()
        if wasVisible {
            hidePanel(reason: reason)
        } else {
            ZSLog("DockHoverPreview: resolve failed (\(reason))")
        }
    }

    /// 是否值得短期重试：指针仍在 Dock 区域附近，且 Dock 还没完全落位（自动隐藏的展开动画）——
    /// 这两条同时成立时失败是时序竞态，不是「指针真的不在图标上」。
    private func scheduleResolveRetry(showGen g: Int, reason: String) -> Bool {
        lock.lock()
        let point = lastMousePoint
        lock.unlock()
        guard isNearDockStrip(point), !isDockSettled() else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        guard g == self.showGen, pendingShowGen == nil else { lock.unlock(); return false }
        // 首次重试才开始计时窗口，后续沿用同一 deadline
        let deadline = retryDeadline ?? (now + Self.resolveRetryWindow)
        retryDeadline = deadline
        let hasBudget = now < deadline
        lock.unlock()
        guard hasBudget else { return false }

        if Self.debug { ZSLog("DockHoverPreview: resolve retry (\(reason))") }
        workQueue.asyncAfter(deadline: .now() + Self.resolveRetryInterval) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = g == self.showGen && self.pendingShowGen == nil
            self.lock.unlock()
            guard live else { return }
            self.resolveAndShow(showGen: g)
        }
        return true
    }

    /// Dock 是否已完全落位（主窗口框几乎全部在屏内）：自动隐藏的展开动画期间为 false
    private func isDockSettled() -> Bool {
        guard let bar = dockBarFrameTL(), let screen = nearestScreenTL(to: bar) else { return false }
        let inter = screen.intersection(bar)
        guard !inter.isNull, bar.width > 0, bar.height > 0 else { return false }
        return inter.width * inter.height >= bar.width * bar.height * 0.95
    }

    /// 权威命中的图标坐标与缓存不一致时（自动隐藏 Dock 展开前后 AX 坐标整体位移几十点），
    /// 触发防抖重建；否则快路径命中与「可见时换图标」判定会一直用隐藏位坐标。
    private func syncDockCache(with target: HoverTarget) {
        let frame = target.frameTL
        let key = suppressKey(for: target)
        lock.lock()
        var stale = false
        if !cacheInvalid {
            for item in dockItems where dockItemKey(item) == key {
                if abs(item.frame.minX - frame.minX) > 1 || abs(item.frame.minY - frame.minY) > 1
                    || abs(item.frame.width - frame.width) > 1 || abs(item.frame.height - frame.height) > 1 {
                    stale = true
                }
            }
        }
        lock.unlock()
        guard stale else { return }
        if Self.debug { ZSLog("DockHoverPreview: cache geometry stale, rebuild") }
        dockLayoutMayHaveChanged()
    }

    private func dockItemKey(_ item: DockItem) -> String {
        if let app = item.app {
            return "app:\(app.bundleIdentifier ?? "pid:\(app.processIdentifier)")"
        }
        return "tile:\(item.title)"
    }

    /// 目标 → 窗口列表（与 ⌘⇥ 切换器同源；无窗口 app 返回空 → 不弹）
    private func windows(for target: HoverTarget) -> [SwitcherWindow] {
        let all = WindowList.shared.enumerate()
        switch target {
        case .app(let app, _):
            let bundleID = app.bundleIdentifier
            let pid = app.processIdentifier
            return all.filter { window in
                guard !window.isWindowlessApp else { return false }
                if let bundleID { return window.app.bundleIdentifier == bundleID }
                return window.pid == pid
            }
        case .tile(let title, _):
            return all.filter { !$0.isWindowlessApp && $0.isMinimized && $0.title == title }
        }
    }

    /// 组装卡片模型：直接用窗口数据，先用持久缓存里的旧图占位（抓到过就一直有），
    /// 新图抓到后在 applyThumbnails 替换，避免空面板/闪烁。
    private func makeItems(_ windows: [SwitcherWindow]) -> [SwitcherWindow] {
        windows.map { window in
            var item = window
            item.thumbnail = thumbnailCache[window.id]
            return item
        }
    }

    /// 主线程：更新模型并弹出/刷新面板（复用同一面板实例，换图标仅换内容不闪烁）
    private func present(windows: [SwitcherWindow], target: HoverTarget, showGen generation: Int, pointer: CGPoint) {
        // 先在锁外取锚点图标缓存 id（cachedItem 内部会加锁，NSLock 不可重入，
        // 持锁调用会主线程死锁——面板永远弹不出来）
        let anchorItemID = cachedItem(at: pointer)?.id
        lock.lock()
        // 菜单抑制兜底：即使 generation/phase 均在途，菜单开着也不上屏
        guard generation == self.showGen, phase == .pending || phase == .visible, !contextMenuGuardActive else {
            lock.unlock()
            return
        }
        phase = .visible
        currentItemTL = target.frameTL
        retryDeadline = nil
        // 同图标内移动走保活，不再误判为换目标；缓存无效时为 nil，靠 anchorFrame 保活
        hoverItemID = anchorItemID
        lock.unlock()

        currentTarget = target
        currentWindows = windows
        model.items = makeItems(windows)

        let panel = ensurePanel()
        let placement = self.placement(for: target.frameTL)
        panel.present(anchorTL: target.frameTL,
                      placement: placement,
                      model: model,
                      onSelect: { [weak self] windowID in self?.activate(windowID: windowID) },
                      onClose: { [weak self] windowID in self?.close(windowID: windowID) })
        panelShown = true
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.frame)
        lock.unlock()
        if Self.debug {
            ZSLog("DockHoverPreview: show gen=\(generation) windows=\(windows.count) anchor=\(target.frameTL)")
        }

        WindowThumbnailer.shared.fetchThumbnails(for: windows) { [weak self] images in
            self?.applyThumbnails(images, showGen: generation)
        }
    }

    private func applyThumbnails(_ images: [CGWindowID: NSImage], showGen generation: Int) {
        lock.lock()
        let live = generation == self.showGen && phase == .visible
        lock.unlock()
        guard live else { return }
        // 新图先入持久缓存：即使下次抓取失败/被节流，卡片也不会变回空占位
        for (windowID, image) in images {
            thumbnailCache[windowID] = image
        }
        for (index, item) in model.items.enumerated() {
            if let image = images[item.id] {
                model.items[index].thumbnail = image
            }
        }
    }

    /// 主线程：懒创建面板
    private func ensurePanel() -> DockPreviewPanel {
        if let panel { return panel }
        let panel = DockPreviewPanel()
        self.panel = panel
        return panel
    }

    /// 主线程：卡片剔除后重算面板尺寸（外框收缩，不留空白），
    /// 并同步保活/mouseDown 命中用的 panelFrameTL，避免旧的大框区域误判。
    private func refitPanelAfterClose() {
        guard panelShown, let panel else { return }
        panel.refit()
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.frame)
        lock.unlock()
    }

    // MARK: - 卡片动作（主线程）

    private func activate(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        let anchor = currentTarget?.frameTL
        let key = currentTarget.map { self.suppressKey(for: $0) }
        hidePanel(reason: "activate")
        if let anchor, let key {
            lock.lock()
            suppressKey = key
            suppressRegionTL = anchor
            lock.unlock()
        }
        // 复用切换器激活链：最小化先还原、跨 Space 自动切换、本 app 窗口走主线程
        WindowActivator.shared.focus(window: window)
    }

    private func suppressKey(for target: HoverTarget) -> String {
        switch target {
        case .app(let app, _):
            return "app:\(app.bundleIdentifier ?? "pid:\(app.processIdentifier)")"
        case .tile(let title, _):
            return "tile:\(title)"
        }
    }

    private func close(windowID: CGWindowID) {
        guard let window = currentWindows.first(where: { $0.id == windowID }) else { return }
        lock.lock()
        let gen = showGen
        lock.unlock()
        // 乐观更新：立即从面板剔除该卡片（缩略图走持久缓存预填，无闪烁）；
        // 单窗口 → 直接收起面板。随后校验刷新同步真实状态。
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let alive = gen == self.showGen && self.phase == .visible
            self.lock.unlock()
            guard alive else { return }
            let remaining = self.currentWindows.filter { $0.id != windowID }
            if remaining.isEmpty {
                self.hidePanel(reason: "last window closed")
            } else {
                self.currentWindows = remaining
                self.model.items = self.makeItems(remaining)
                self.refitPanelAfterClose()
            }
        }
        WindowOps.perform(.close, on: window) { [weak self] in
            self?.refreshAfterClose(showGen: gen)
        }
    }

    /// 关闭后刷新：重新枚举目标窗口；最后一个窗口被关掉时整个面板撤掉
    /// 关闭后的校验刷新（延时 400ms，等关窗动画结束）：只「剔除确认消失的窗口」，
    /// 不回加——枚举在关窗动画期间可能仍列出旧窗口，回加会让卡片闪回。
    private func refreshAfterClose(showGen generation: Int) {
        workQueue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                self.lock.lock()
                guard self.phase == .visible, let target = self.currentTarget, generation == self.showGen else {
                    self.lock.unlock()
                    return
                }
                self.lock.unlock()
                self.workQueue.async { [weak self] in
                    let windows = self?.windows(for: target) ?? []
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let alive = generation == self.showGen && self.phase == .visible
                        self.lock.unlock()
                        guard alive else { return }
                        let remaining = self.currentWindows.filter { window in
                            windows.contains(where: { $0.id == window.id })
                        }
                        guard remaining.count != self.currentWindows.count else { return }
                        if remaining.isEmpty {
                            self.hidePanel(reason: "last window closed")
                        } else {
                            self.currentWindows = remaining
                            self.model.items = self.makeItems(remaining)
                            self.refitPanelAfterClose()
                            WindowThumbnailer.shared.fetchThumbnails(for: remaining) { [weak self] images in
                                self?.applyThumbnails(images, showGen: generation)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 面板定位

    /// 依据 Dock 项缓存的分布与图标在屏上的位置判定面板朝向
    private func placement(for anchorTL: CGRect) -> DockPreviewPanel.Placement {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let cocoa = CGRect(x: anchorTL.minX, y: unionMaxY - anchorTL.maxY,
                           width: anchorTL.width, height: anchorTL.height)
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(cocoa) }) else {
            return .above
        }
        lock.lock()
        let items = dockItems
        lock.unlock()
        if items.count >= 2 {
            // 多项：图标整体沿横轴排布 → 底部 Dock（面板在上方）；沿纵轴 → 左右 Dock
            var bbox = CGRect.null
            for item in items { bbox = bbox.union(item.frame) }
            if bbox.width >= bbox.height { return .above }
            return cocoa.midX < screen.frame.midX ? .rightOf : .leftOf
        }
        // 单项兜底：取图标中心到各屏幕边的最近边
        let frame = toTopLeftCoords(screen.frame)
        let dBottom = frame.maxY - anchorTL.maxY
        let dLeft = anchorTL.minX - frame.minX
        let dRight = frame.maxX - anchorTL.maxX
        let nearest = min(dBottom, dLeft, dRight)
        if nearest == dLeft { return .rightOf }
        if nearest == dRight { return .leftOf }
        return .above
    }

    // MARK: - 键盘与全局隐藏触发

    /// visible 时任意按键（含 Esc）收起面板；事件不吞，不影响其他响应
    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.isVisible() {
                self.hidePanel(reason: "keyDown \(event.keyCode)")
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// 全局隐藏触发：Space 切换 / 锁屏睡眠 / 目标 app 或 Dock 退出 / 屏幕配置变化
    private func observeHideTriggers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "space changed")
                self?.dockLayoutMayHaveChanged()
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "sleep")
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "screens sleep")
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                if app.bundleIdentifier == Self.dockBundleID {
                    self?.dockLayoutMayHaveChanged()
                }
                self?.hideIfTarget(app: app)
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                self?.dockLayoutMayHaveChanged()
            },
        ]
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hidePanel(reason: "screen config changed")
            self?.dockLayoutMayHaveChanged()
        }
    }

    /// 目标 app 退出时收起（tile 目标不跟踪 app 退出）
    private func hideIfTarget(app: NSRunningApplication) {
        guard let target = currentTarget else { return }
        switch target {
        case .app(let targetApp, _):
            if targetApp.processIdentifier == app.processIdentifier {
                hidePanel(reason: "target app quit")
            }
        case .tile:
            break
        }
    }

    // MARK: - Dock 项缓存（独立拷贝自 DockClickMinimizer 的探测逻辑，另含瓦片标题）

    /// Dock 布局变化（图标增删、切 Space、Dock 重启）时置缓存失效并防抖重建
    private func dockLayoutMayHaveChanged() {
        lock.lock()
        cacheInvalid = true
        lock.unlock()
        scheduleCacheRebuild()
    }

    /// trailing-edge 防抖：布局事件爆发时合并为一次重建
    private func scheduleCacheRebuild(delay: TimeInterval = 0.3) {
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildDockCache()
        }
        lock.lock()
        pendingCacheRebuild?.cancel()
        pendingCacheRebuild = work
        lock.unlock()
        cacheQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func rebuildDockCache() {
        lock.lock()
        let enabled = SettingsStore.shared.dockPreviewEnabled && isRunning
        lock.unlock()
        guard enabled else { return }

        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else {
            scheduleCacheRebuild(delay: 2)
            return
        }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        // 注意:Dock 不通过 kAXWindowsAttribute 公开图标(实测返回空数组),
        // 必须从应用元素的直接子元素开始递归(与 DockClickMinimizer 的命中目标同源)
        guard let roots = copyAXElements(dockElement, kAXChildrenAttribute), !roots.isEmpty else {
            ZSLog("DockHoverPreview: cache rebuild retry (dock children unreadable)")
            scheduleCacheRebuild(delay: 2)
            return
        }

        var nextID = 0
        var items: [DockItem] = []
        var roles: [String: Int] = [:]
        for root in roots {
            collectDockItems(in: root, into: &items, nextID: &nextID, roles: &roles)
        }
        lock.lock()
        dockItems = items
        cacheInvalid = false
        lock.unlock()
        let top = roles.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        ZSLog("DockHoverPreview: cache rebuilt items=\(items.count) strip=\(bboxOfItems(items).map{"\($0)"} ?? "nil") roles=[\(top)]")
    }

    private func collectDockItems(in element: AXUIElement, into items: inout [DockItem], nextID: inout Int, roles: inout [String: Int]) {
        let roleName = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String? ?? "?"
        roles[roleName, default: 0] += 1
        if isDockItemElement(element),
           let point = axPoint(element, kAXPositionAttribute),
           let size = axSize(element, kAXSizeAttribute) {
            let app = appForDockItem(element)
            let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
            items.append(DockItem(id: nextID, frame: CGRect(origin: point, size: size), app: app, title: title))
            nextID += 1
        }
        if let children = copyAXElements(element, kAXChildrenAttribute) {
            for child in children {
                collectDockItems(in: child, into: &items, nextID: &nextID, roles: &roles)
            }
        }
    }

    // MARK: - AX 权威命中（独立拷贝自 DockClickMinimizer，扩展瓦片识别）

    /// 解析结果三态：notDockElement 表示 AX 正常但该点不是可识别 Dock 项（右键菜单/分隔符等），
    /// 不可用缓存兜底；failed 表示 AX 调用本身偶发失败，可用缓存身份兜底。
    private enum ResolveOutcome {
        case resolved(HoverTarget)
        case notDockElement
        case failed
    }

    /// 问系统「该点上是什么元素」，向上找最近的 Dock 项；app 项与无 URL 项（瓦片候选）都返回
    private func resolveTarget(at point: CGPoint) -> ResolveOutcome {
        let systemWide = AXUIElementCreateSystemWide()
        var raw: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &raw) == .success,
              let raw else { return .failed }
        var element = raw
        for _ in 0..<Self.parentWalkDepth {
            if isDockItemElement(element) {
                guard let pos = axPoint(element, kAXPositionAttribute),
                      let size = axSize(element, kAXSizeAttribute) else { return .failed }
                let frame = CGRect(origin: pos, size: size)
                if let app = appForDockItem(element) {
                    return .resolved(.app(app, frameTL: frame))
                }
                // 无 URL 项：最小化窗口瓦片候选（堆栈/废纸篓标题通常反查不到窗口，自然不弹）
                let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? ?? ""
                guard !title.isEmpty else { return .notDockElement }
                return .resolved(.tile(title: title, frameTL: frame))
            }
            // 命中 Dock 右键菜单/菜单项：不视为图标悬停
            if isMenuElement(element) { return .notDockElement }
            guard let parent = axParent(element) else { break }
            element = parent
        }
        return .notDockElement
    }

    /// 菜单类元素：Dock 图标右键弹出的菜单/菜单项
    private func isMenuElement(_ element: AXUIElement) -> Bool {
        let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?
        let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?
        switch role ?? subrole {
        case kAXMenuRole, kAXMenuItemRole, kAXMenuBarRole, kAXMenuBarItemRole:
            return true
        default:
            return false
        }
    }

    private func isDockItemElement(_ element: AXUIElement) -> Bool {
        if let role = copyAXValue(element, kAXRoleAttribute, as: CFString.self) as String?,
           role == Self.dockItemRole {
            return true
        }
        if let subrole = copyAXValue(element, kAXSubroleAttribute, as: CFString.self) as String?,
           subrole == Self.dockItemRole {
            return true
        }
        return false
    }

    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let raw else { return nil }
        // AX 元素的父元素恒为 AXUIElement，强制桥接
        let parent: AXUIElement = raw as! AXUIElement
        return parent
    }

    /// Dock 项 → 对应运行中的应用。优先 kAXURL（.app file URL → bundleID），
    /// 无 URL 的项（Launchpad/Trash/窗口图标等）按标题兜底匹配。
    private func appForDockItem(_ element: AXUIElement) -> NSRunningApplication? {
        if let urlRaw = copyAXValue(element, kAXURLAttribute, as: NSURL.self),
           let bundle = Bundle(url: urlRaw as URL),
           let bundleID = bundle.bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            return app
        }
        if let title = copyAXValue(element, kAXTitleAttribute, as: CFString.self) as String? {
            return runningApp(named: title)
        }
        return nil
    }

    private func runningApp(named title: String) -> NSRunningApplication? {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            let displayName = app.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let executableName = app.executableURL?.deletingPathExtension().lastPathComponent.lowercased()
            return displayName == normalized || executableName == normalized
        }
    }

    // MARK: - 坐标（CGEvent/AX/CGWindow 均为「主屏左上原点」的点坐标）

    private func topLeftFrame(of screen: NSScreen) -> CGRect {
        toTopLeftCoords(screen.frame)
    }

    /// Cocoa 矩形（左下原点）→ 左上原点全局坐标
    private func toTopLeftCoords(_ rect: CGRect) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(
            x: rect.minX,
            y: union.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Dock 条带 bbox（缓存项整体范围，AX 左上原点全局坐标）；缓存无效时 nil
    private func dockStripTL() -> CGRect? {
        lock.lock(); defer { lock.unlock() }
        guard !cacheInvalid else { return nil }
        return bboxOfItems(dockItems)
    }

    private func bboxOfItems(_ items: [DockItem]) -> CGRect? {
        var bbox = CGRect.null
        for item in items { bbox = bbox.union(item.frame) }
        return bbox.isNull ? nil : bbox
    }

    /// 指针是否在 Dock 条带附近（外扩 stripTriggerMargin）：作为挂起权威命中的触发条件。
    /// 对齐 DockClickMinimizer 的思路：只有真正接近 Dock 本体才参与判定，
    /// 而不是「靠近屏幕任意边缘」——后者会导致从上方接近时过早触发、在屏幕中部误触发。
    private func isNearDockStrip(_ point: CGPoint) -> Bool {
        if let zone = dockRegionTL(margin: Self.stripTriggerMargin) {
            return zone.contains(point)
        }
        return isNearDockEdgeFallback(point)
    }

    /// Dock 可交互条带（AX 左上原点，含外扩 margin）。
    /// **自动隐藏时 Dock 的 AX 坐标是「隐藏位」（整条落到屏幕边之外）**，直接用会让触发区/
    /// 闸门整体下移几十点（表现为停在图标上就是不弹、只有屏幕最底一条缝能弹），
    /// 因此统一先把条带吸附到最近的屏幕边再外扩。左/右 Dock 同理吸附到左/右边。
    private func dockRegionTL(margin: CGFloat) -> CGRect? {
        guard let rect = dockBarFrameTL() ?? dockStripTL() else { return nil }
        return snapToScreenEdge(rect).insetBy(dx: -margin, dy: -margin)
    }

    /// 把 Dock 条带吸附到最近的屏幕边：横向排布贴底边，纵向排布贴左/右边。
    /// 已落位的条带吸附后位置不变（幂等），只有隐藏位/动画中的条带会被拉回屏幕内。
    private func snapToScreenEdge(_ rect: CGRect) -> CGRect {
        guard let screen = nearestScreenTL(to: rect) else { return rect }
        if rect.width >= rect.height {
            return CGRect(x: rect.minX, y: screen.maxY - rect.height, width: rect.width, height: rect.height)
        }
        let onLeft = rect.midX < screen.midX
        return CGRect(x: onLeft ? screen.minX : screen.maxX - rect.width,
                      y: rect.minY, width: rect.width, height: rect.height)
    }

    /// 与 rect 最近的屏幕（左上原点；已相交时距离为 0），用于把隐藏位条带吸回正确的屏幕
    private func nearestScreenTL(to rect: CGRect) -> CGRect? {
        var best: (frame: CGRect, distance: CGFloat)?
        for screen in NSScreen.screens {
            let frame = topLeftFrame(of: screen)
            var distance: CGFloat = 0
            if frame.intersection(rect).isNull {
                let dx = max(0, max(frame.minX - rect.maxX, rect.minX - frame.maxX))
                let dy = max(0, max(frame.minY - rect.maxY, rect.minY - frame.maxY))
                distance = hypot(dx, dy)
            }
            if best == nil || distance < best!.distance { best = (frame, distance) }
        }
        return best?.frame
    }

    /// 兕底触发区：屏幕底/左/右边缘 150pt（不含顶部，避免菜单栏区参与判定）。
    /// 仅当 Dock 条带信息完全不可用时短暂使用；「没到 Dock 就弹」由到期闸门拦截。
    private func isNearDockEdgeFallback(_ point: CGPoint) -> Bool {
        for frame in NSScreen.screens.map({ topLeftFrame(of: $0) }) where frame.contains(point) {
            let m = Self.edgeFallbackMargin
            if point.x < frame.minX + m || point.x > frame.maxX - m { return true }
            if point.y > frame.maxY - m { return true }
            return false
        }
        return false
    }

    /// Dock 主窗口框（AX 左上原点全局坐标，1s TTL）。直接向 Dock 进程要窗口框，
    /// 不依赖 Dock 项层级缓存——缓存未建好/失效时触发与闸门仍然可用。
    private var dockBarFrameCache: (frame: CGRect, at: Date)?
    private func dockBarFrameTL() -> CGRect? {
        lock.lock()
        if let c = dockBarFrameCache, Date().timeIntervalSince(c.at) < 1 {
            lock.unlock()
            return c.frame
        }
        lock.unlock()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        guard let windows = copyAXElements(dockElement, kAXWindowsAttribute) else { return nil }
        var best: CGRect?
        for w in windows {
            guard let pt = axPoint(w, kAXPositionAttribute), let sz = axSize(w, kAXSizeAttribute) else { continue }
            let f = CGRect(origin: pt, size: sz)
            guard f.width > 0, f.height > 0 else { continue }
            if best == nil || f.width * f.height > best!.width * best!.height { best = f }
        }
        guard let frame = best else { return nil }
        lock.lock()
        dockBarFrameCache = (frame, Date())
        lock.unlock()
        return frame
    }

    // MARK: - AX 辅助（与 DockClickMinimizer 同款）

    private func copyAXValue<T>(_ element: AXUIElement, _ attribute: String, as _: T.Type) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? T
    }

    private func copyAXElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else { return nil }
        return value as? [AXUIElement]
    }

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = copyAXValue(element, attribute, as: AXValue.self) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value, .cgSize, &size) else { return nil }
        return size
    }
}
