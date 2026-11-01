import AppKit
import ApplicationServices
import Combine
import CoreGraphics

/// 灵动岛：悬停/单击刘海区域，弹出「更大的刘海」——顶边贴屏幕顶、水平居中于刘海、
/// 尺寸随当前内容模块自适应；一次显示一个内容模块（默认日历），刘海两侧顶部条内药丸切换。
/// 形状/动画细节见 NotchPanel 类文档。
///
/// 实现要点（结构仿 `DockHoverPreviewController`）：
/// - listen-only CGEventTap 监听 mouseMoved / mouseDown / keyDown，绝不吞事件：
///   刘海热区只是几何判定（不依赖热区窗收事件），菜单栏图标点击、Esc 等原生行为零影响。
/// - 刘海矩形由公开 API 推导：`safeAreaInsets.top > 0` 判定刘海屏，
///   `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` 之间的水平间隙即刘海（竖向占满菜单栏条带）；
///   热区 = 刘海矩形左右各外扩 12pt（不纵向外扩，避免盖住菜单栏下方内容区）。
/// - 状态机：idle →(悬停延时 / 单击热区)→ visible；visible 时指针在 (热区∪面板)外扩内
///   保活，移出后按悬停延时（notchHoverDelayMs）延迟收起；区域外任意 mouseDown 收起；Esc 收起；Space 切换 /
///   锁屏睡眠 / 屏幕配置变化全局收起。
/// - 无刘海屏静默不生效（合盖再开屏、屏幕配置变化时重新探测）；
///   `ZEROFLOW_NOTCH_FAKE=1` 在主屏合成伪刘海便于调试，`ZEROFLOW_NOTCH_DEBUG=1` 输出决策日志。
final class NotchHotspotController {
    static let shared = NotchHotspotController()

    /// 开关变化通知：由 SettingsStore.notchEnabled 的 didSet 触发
    static let didChangeNotification = Notification.Name("zeroflow.notchDidChange")

    private static let debug = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_DEBUG"] == "1"
    private static let fakeNotch = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_FAKE"] == "1"

    /// 热区对刘海的左右外扩
    private static let hotspotMargin: CGFloat = 12
    /// 悬停延时（s）：弹出等待与移出后的收起等待共用同一设置 notchHoverDelayMs
    private static var configuredDelay: TimeInterval {
        TimeInterval(max(50, SettingsStore.shared.notchHoverDelayMs)) / 1000.0
    }
    /// 保活判定对 热区/面板 的外扩：吞掉两者之间的缝隙，慢速移动不掉出保活区
    private static let keepAliveInset: CGFloat = 6
    /// move 事件处理节流间隔（s）：几何判定足够快，但没必要每个 HID 事件都跑
    private static let moveThrottle: CFTimeInterval = 0.016
    /// Esc 键码
    private static let escKeyCode: UInt16 = 53

    private enum Phase { case idle, pending, visible }

    // MARK: - 状态（lock 保护；tap 线程 / workQueue / 主线程共用）

    private let lock = NSLock()
    private var phase: Phase = .idle
    /// show 工作代数：悬停调度/单击开启时递增，使旧 show 作废
    private var showGen = 0
    /// 延迟隐藏代数：回到保活区即取消；与 showGen 分开避免互相误杀
    private var hideGen = 0
    /// 已调度、尚未触发的悬停 show 代数（防同一停留重复调度；移出热区即作废）
    private var pendingShowGen: Int?
    /// 刘海热区（主屏左上原点全局坐标）；nil = 当前无刘海屏
    private var hotspotTL: CGRect?
    /// 面板 frame（同坐标），visible 时用于保活/区域外判定
    private var panelFrameTL: CGRect?
    private var lastMousePoint = CGPoint.zero
    private var lastMoveProcessedAt = CFTimeInterval(0)
    /// 收起后的重弹抑制：面板被 Esc/点击外部等收起后，若指针仍留在热区内，
    /// 悬停不会再弹，直到指针离开热区（否则按 Esc 面板立刻在一个悬停延时后重弹）
    private var suppressReshow = false

    // 主线程专用
    private var panel: NotchPanel?
    private var model: NotchCalendarViewModel?
    private var panelShown = false
    private var notchScreen: NSScreen?
    private var dayEventsCancellable: AnyCancellable?
    /// 会话内记住的显示模块（默认日历，重启回默认；不落盘）
    private var selectedModule: NotchContentView.Module?
    /// 最近一次 present 的热区/刘海矩形/屏幕（日程变化后 refit 复用；收起动画缩回刘海用 notchTL）
    private var lastPresented: (screen: NSScreen, hotspotTL: CGRect, notchTL: CGRect)?

    // MARK: - 基础设施

    private var isRunning = false
    private var thread: Thread?
    private weak var tapRunLoop: CFRunLoop?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let workQueue = DispatchQueue(label: "zeroflow.notch", qos: .userInitiated)

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
        if SettingsStore.shared.notchEnabled {
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

        refreshHotspot()
        lock.lock()
        let hasHotspot = hotspotTL != nil
        lock.unlock()
        if !hasHotspot {
            ZSLog("Notch: no notch display detected, waiting for screen config change")
        }

        let t = Thread { [weak self] in
            self?.runTapLoop()
        }
        t.name = "zeroflow.notch"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
        ZSLog("Notch: started")
    }

    private func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let runLoop = tapRunLoop
        let source = runLoopSource
        let tap = eventTap
        eventTap = nil
        runLoopSource = nil
        tapRunLoop = nil
        lock.unlock()

        hidePanel(reason: "disabled")
        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFRunLoopStop(runLoop)
        }
        if let tap { CFMachPortInvalidate(tap) }
        thread = nil
        ZSLog("Notch: stopped")
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
        // listen-only：只旁观，不吞事件（菜单栏/热键/Esc 原生行为均不受影响）
        let mask = CGEventMask(
            (1 << CGEventType.mouseMoved.rawValue)
                | (1 << CGEventType.leftMouseDown.rawValue)
                | (1 << CGEventType.rightMouseDown.rawValue)
                | (1 << CGEventType.otherMouseDown.rawValue)
                | (1 << CGEventType.keyDown.rawValue)
        )
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            ZSLog("Notch: tap create failed (no accessibility permission?)")
            return
        }
        lock.lock(); eventTap = tap; lock.unlock()
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        lock.lock(); runLoopSource = source; lock.unlock()
        ZSLog("Notch: tap installed OK")
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
        let controller = Unmanaged<NotchHotspotController>.fromOpaque(info).takeUnretainedValue()
        return controller.handle(type: type, event: event)
    }

    private static let retryTimerCallback: @convention(c) (CFRunLoopTimer?, UnsafeMutableRawPointer?) -> Void = { _, info in
        guard let info else { return }
        let controller = Unmanaged<NotchHotspotController>.fromOpaque(info).takeUnretainedValue()
        controller.retryCreateTapIfNeeded()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock(); let tap = eventTap; lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard SettingsStore.shared.notchEnabled else { return Unmanaged.passUnretained(event) }
        // 未授权辅助功能时静默跳过
        guard AccessibilityPermission.isGranted else { return Unmanaged.passUnretained(event) }

        switch type {
        case .mouseMoved:
            handleMouseMoved(event.location)
        case .leftMouseDown:
            handleMouseDown(at: event.location, isOpeningClick: true)
        case .rightMouseDown, .otherMouseDown:
            handleMouseDown(at: event.location, isOpeningClick: false)
        case .keyDown:
            if event.getIntegerValueField(.keyboardEventKeycode) == Int64(Self.escKeyCode) {
                lock.lock()
                let visible = phase == .visible
                lock.unlock()
                if visible { hidePanel(reason: "esc") }
            }
        default:
            break
        }
        // listen-only：事件原样放行
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 状态机（tap 线程决策，workQueue/主线程执行）

    private func handleMouseMoved(_ point: CGPoint) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveProcessedAt < Self.moveThrottle {
            lastMousePoint = point // 记录最新点，节流不影响 show 到期时的取点
            lock.unlock()
            return
        }
        lastMoveProcessedAt = now
        lastMousePoint = point
        let currentPhase = phase
        let hotspot = hotspotTL
        let panelFrame = panelFrameTL
        lock.unlock()

        guard let hotspot else { return } // 无刘海屏：不响应

        switch currentPhase {
        case .idle:
            if hotspot.contains(point) {
                if !isSuppressingReshow() {
                    scheduleShowIfNone()
                }
            } else {
                if isSuppressingReshow() {
                    clearSuppressReshow()
                }
                cancelPendingShow()
            }

        case .pending:
            // 悬停计时期间移出热区：作废在途 show
            if !hotspot.contains(point) {
                cancelPendingShow()
            }

        case .visible:
            // 显示中：仍在 (热区∪面板)外扩 内 → 保活；移出 → 按悬停延时延迟隐藏
            var inside = false
            if hotspot.insetBy(dx: -Self.keepAliveInset, dy: -Self.keepAliveInset).contains(point) { inside = true }
            if let panelFrame, panelFrame.insetBy(dx: -Self.keepAliveInset, dy: -Self.keepAliveInset).contains(point) { inside = true }
            if inside {
                bumpHideGen()
            } else {
                scheduleHideAfterDelay()
            }
        }
    }

    private func handleMouseDown(at point: CGPoint, isOpeningClick: Bool) {
        lock.lock()
        let currentPhase = phase
        let hotspot = hotspotTL
        let panelFrame = panelFrameTL
        lock.unlock()

        switch currentPhase {
        case .idle, .pending:
            // 未显示：左键单击热区立即弹出（悬停延时的另一条触发路径）
            if isOpeningClick, let hotspot, hotspot.contains(point) {
                openNow()
                return
            }
            // 悬停计时期间点击热区外：取消在途 show
            if currentPhase == .pending, let hotspot, !hotspot.contains(point) {
                cancelPendingShow()
            }

        case .visible:
            // 显示中：点击在 (热区∪面板)内 → 保活（面板自身交互需要收到 mouseDown）；区域外 → 收起
            var inside = false
            if let hotspot, hotspot.insetBy(dx: -Self.keepAliveInset, dy: -Self.keepAliveInset).contains(point) { inside = true }
            if let panelFrame, panelFrame.insetBy(dx: -Self.keepAliveInset, dy: -Self.keepAliveInset).contains(point) { inside = true }
            if inside {
                bumpHideGen()
            } else {
                hidePanel(reason: "mouseDown outside")
            }
        }
    }

    // MARK: - 调度

    /// 保活：取消待触发的延迟隐藏（不动在途 show）
    private func bumpHideGen() {
        lock.lock()
        hideGen += 1
        lock.unlock()
    }

    /// 延迟隐藏：移出 热区∪面板(外扩) 一个悬停延时后仍 visible 且无在途 show 才真正隐藏。
    /// 期间回到保活区（bumpHideGen）或调度了新 show 都会取消。
    private func scheduleHideAfterDelay() {
        lock.lock()
        hideGen += 1
        let gen = hideGen
        lock.unlock()
        workQueue.asyncAfter(deadline: .now() + Self.configuredDelay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let live = gen == self.hideGen && self.phase == .visible && self.pendingShowGen == nil
            self.lock.unlock()
            guard live else { return }
            self.hidePanel(reason: "left hotspot+panel region")
        }
    }

    /// 仅当没有任何挂起的 show 时调度（防止热区内连续移动重复触发）
    private func scheduleShowIfNone() {
        lock.lock()
        let none = pendingShowGen == nil
        lock.unlock()
        guard none else { return }

        lock.lock()
        showGen += 1
        let gen = showGen
        pendingShowGen = gen
        phase = .pending
        lock.unlock()
        let delay = Self.configuredDelay
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pendingShowGen == gen { self.pendingShowGen = nil }
            let live = gen == self.showGen && self.phase == .pending
            let point = self.lastMousePoint
            let hotspot = self.hotspotTL
            self.lock.unlock()
            guard live, let hotspot, hotspot.contains(point) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.presentPanel(showGen: gen)
            }
        }
    }

    /// 是否处于收起后的重弹抑制状态
    private func isSuppressingReshow() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return suppressReshow
    }

    private func clearSuppressReshow() {
        lock.lock()
        suppressReshow = false
        lock.unlock()
    }

    /// 单击热区立即弹出（无需等悬停延时）
    private func openNow() {
        lock.lock()
        pendingShowGen = nil
        suppressReshow = false
        showGen += 1
        let gen = showGen
        phase = .pending
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.presentPanel(showGen: gen)
        }
    }

    /// 移出热区/点击热区外时作废在途悬停 show
    private func cancelPendingShow() {
        lock.lock()
        if pendingShowGen != nil {
            pendingShowGen = nil
            showGen += 1
            if phase == .pending { phase = .idle }
        }
        lock.unlock()
    }

    private func hidePanel(reason: String) {
        lock.lock()
        let wasVisible = phase == .visible
        phase = .idle
        pendingShowGen = nil
        panelFrameTL = nil
        suppressReshow = true
        showGen += 1
        hideGen += 1
        lock.unlock()
        guard wasVisible else { return }
        ZSLog("Notch: hide (\(reason))")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let notchTL = self.lastPresented?.notchTL
            self.panelShown = false
            self.dayEventsCancellable = nil
            self.lastPresented = nil
            SystemResourceMonitor.shared.setActive(false)
            NowPlayingMonitor.shared.setActive(false)
            // 视觉收起交给面板：弹簧缩回刘海再 orderOut；期间再 present 会无缝续接展开
            if let notchTL {
                self.panel?.dismiss(notchTL: notchTL)
            } else {
                self.panel?.orderOut(nil)
            }
        }
    }

    // MARK: - 展示（主线程）

    /// 悬停延时到期 / 单击热区：主线程重建面板内容并以弹簧动画从刘海展开显示
    private func presentPanel(showGen gen: Int) {
        lock.lock()
        guard gen == showGen, phase == .pending else {
            lock.unlock()
            return
        }
        phase = .visible
        lock.unlock()

        // 主线程重新探测（合盖/接屏等边缘情况的权威值），并校验代数仍有效
        guard let detected = refreshHotspot() else {
            hidePanel(reason: "no notch")
            return
        }
        lock.lock()
        let live = gen == showGen && phase == .visible
        lock.unlock()
        guard live else { return }

        let viewModel = ensureModel()
        viewModel.reset()
        let panel = ensurePanel()
        let module = currentSelectedModule()
        panel.present(hotspotTL: detected.hotspotTL, notchTL: detected.notchTL,
                      screen: detected.screen, model: viewModel, module: module,
                      onSelectModule: { [weak self] in self?.handleSelectModule($0) })
        panelShown = true
        lastPresented = (detected.screen, detected.hotspotTL, detected.notchTL)
        updateMonitors()
        startDayEventsRefit(model: viewModel)
        // 用弹簧目标 frame，而非 present() 返回时刻的瞬时 frame（动画刚从刘海开始）
        syncPanelFrame()
        if Self.debug {
            ZSLog("Notch: show gen=\(gen) hotspot=\(detected.hotspotTL) panel=\(panel.frame)")
        }
    }

    /// 会话内选择的显示模块；被禁用/失效时回退默认（日历优先，无启用模块 = nil → 空状态）
    private func currentSelectedModule() -> NotchContentView.Module? {
        let enabled = NotchContentView.enabledModules
        if let selected = selectedModule, enabled.contains(selected) { return selected }
        selectedModule = NotchContentView.defaultModule
        return selectedModule
    }

    /// 顶部药丸切换模块：更新会话状态、重建面板内容并同步数据轮询/日程订阅
    private func handleSelectModule(_ module: NotchContentView.Module) {
        guard module != selectedModule else { return }
        selectedModule = module
        panel?.switchModule(to: module)
        syncPanelFrame()
        updateMonitors()
        if let model { startDayEventsRefit(model: model) }
    }

    /// 按当前显示模块启停数据轮询（仅面板可见期间运行，hidePanel 时全部停止）
    private func updateMonitors() {
        SystemResourceMonitor.shared.setActive(selectedModule == .resources)
        NowPlayingMonitor.shared.setActive(selectedModule == .music)
    }

    private func ensurePanel() -> NotchPanel {
        if let panel { return panel }
        let panel = NotchPanel()
        self.panel = panel
        return panel
    }

    private func ensureModel() -> NotchCalendarViewModel {
        if let model { return model }
        let model = NotchCalendarViewModel()
        self.model = model
        return model
    }

    /// 日历模块显示中时订阅日程变化：日程异步加载完成 / 切换选中日期后重测内容布局
    /// （面板尺寸随日程列表变化，refit 会弹簧变形并同步命中区域）
    private func startDayEventsRefit(model: NotchCalendarViewModel) {
        dayEventsCancellable = nil
        guard selectedModule == .calendar else { return }
        dayEventsCancellable = model.$dayEvents
            .removeDuplicates()
            .sink { [weak self] _ in self?.refitPanel() }
    }

    /// 重测内容：尺寸随内容变化，重建 contentView 并同步命中区域
    private func refitPanel() {
        lock.lock()
        let visible = phase == .visible
        lock.unlock()
        guard visible, let panel, let model, lastPresented != nil else { return }
        panel.refit(model: model)
        syncPanelFrame()
    }

    /// 面板尺寸变化后用弹簧目标 frame 更新保活/点击外部命中区域
    private func syncPanelFrame() {
        guard let panel else { return }
        lock.lock()
        panelFrameTL = toTopLeftCoords(panel.targetFrame)
        lock.unlock()
    }

    // MARK: - 刘海探测（主线程）

    /// 探测刘海屏并计算热区。无刘海返回 nil；ZEROFLOW_NOTCH_FAKE=1 时在主屏合成伪刘海。
    @discardableResult
    private func refreshHotspot() -> (screen: NSScreen, hotspotTL: CGRect, notchTL: CGRect)? {
        let detected = detectNotch()
        notchScreen = detected?.screen
        lock.lock()
        hotspotTL = detected?.hotspotTL
        lock.unlock()
        return detected
    }

    private func detectNotch() -> (screen: NSScreen, hotspotTL: CGRect, notchTL: CGRect)? {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        for screen in NSScreen.screens {
            let barHeight: CGFloat
            let notchFrameCocoa: CGRect
            if Self.fakeNotch {
                guard screen == NSScreen.main else { continue }
                barHeight = 24
                notchFrameCocoa = CGRect(x: screen.frame.midX - 90, y: screen.frame.maxY - barHeight,
                                         width: 180, height: barHeight)
            } else {
                guard screen.safeAreaInsets.top > 0,
                      let left = screen.auxiliaryTopLeftArea,
                      let right = screen.auxiliaryTopRightArea,
                      right.minX - left.maxX > 4 else { continue }
                barHeight = max(left.height, right.height, screen.safeAreaInsets.top)
                notchFrameCocoa = CGRect(x: left.maxX, y: screen.frame.maxY - barHeight,
                                         width: right.minX - left.maxX, height: barHeight)
            }
            // Cocoa（左下原点）→ 主屏左上原点全局坐标，并左右外扩成热区
            let notchTL = CGRect(x: notchFrameCocoa.minX, y: unionMaxY - notchFrameCocoa.maxY,
                                 width: notchFrameCocoa.width, height: notchFrameCocoa.height)
            let hotspot = notchTL.insetBy(dx: -Self.hotspotMargin, dy: 0)
            if Self.debug {
                ZSLog("Notch: detect screen=\(screen.localizedName) notchTL=\(notchTL) hotspot=\(hotspot)")
            }
            return (screen, hotspotTL: hotspot, notchTL: notchTL)
        }
        return nil
    }

    // MARK: - 全局隐藏触发

    /// Space 切换 / 锁屏睡眠 / 屏幕配置变化时收起；屏幕配置变化同时重探刘海
    private func observeHideTriggers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "space changed")
            },
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "sleep")
            },
            center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.hidePanel(reason: "screens sleep")
            },
        ]
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.hidePanel(reason: "screen config changed")
            self?.refreshHotspot()
        }
    }

    // MARK: - 坐标（CGEvent 均为「主屏左上原点」的点坐标）

    /// Cocoa 矩形（左下原点）→ 主屏左上原点全局坐标
    private func toTopLeftCoords(_ rect: CGRect) -> CGRect {
        let union = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGRect(x: rect.minX, y: union.maxY - rect.maxY,
                      width: rect.width, height: rect.height)
    }
}
