import AppKit
import SwiftUI

/// SLK：串联「选区 → 捕获 → 打开编辑器」的协调器
final class CaptureCoordinator: NSObject, ObservableObject {
    static let shared = CaptureCoordinator()

    /// 当前是否正在截图会话中
    private(set) var isActive = false

    private var overlayWindows: [CaptureOverlayWindow] = []
    private var editorController: NSWindowController?
    /// 各屏整屏预拍结果（选区完成时直接裁剪，避免弹出框被遮罩关闭后拍不到）
    private var pendingCaptures: [ObjectIdentifier: DisplayCapture] = [:]
    /// 选区期间的全局 Esc 监听（遮罩为非激活面板后无法走 key 窗口收键盘）
    private var escMonitor: Any?

    private override init() {
        super.init()
    }

    // MARK: - 入口

    /// 开始一次截图（由热键 / 菜单触发）
    func startCapture() {
        ZSLog("startCapture called, preflight granted = \(ScreenRecordingPermission.isGranted)")
        guard !isActive else { ZSLog("already active, ignore"); return }
        guard SettingsStore.shared.screenshotEnabled else {
            ZSLog("screenshot disabled, ignore")
            return
        }
        isActive = true
        Task {
            // 用真实权限探测：与截图使用同一 ScreenCaptureKit API
            let granted = await ScreenRecordingPermission.hasScreenCaptureAccess()
            if !granted {
                ZSLog("real permission check failed -> guide")
                await MainActor.run {
                    self.isActive = false
                    self.presentPermissionGuide()
                }
                return
            }
            // 先把各屏整屏预拍：此刻不激活本 app、不建任何窗口，用户的弹出框保持打开；
            // 选区完成后从预拍图裁剪，保证截到弹出框内容。
            let captures = await preCaptureAllScreens()
            await MainActor.run {
                self.pendingCaptures = captures
                ZSLog("real permission OK -> create overlays")
                // 进入截图的那一刻就把光标切成十字线
                NSCursor.crosshair.set()
                self.createOverlayWindows()
            }
        }
    }

    /// 并行预拍所有屏幕的整屏原生像素图
    private func preCaptureAllScreens() async -> [ObjectIdentifier: DisplayCapture] {
        let screens = NSScreen.screens
        var result: [ObjectIdentifier: DisplayCapture] = [:]
        await withTaskGroup(of: (Int, DisplayCapture?).self) { group in
            for (index, screen) in screens.enumerated() {
                group.addTask {
                    (index, await ScreenCapture.captureFullDisplay(screen: screen))
                }
            }
            for await (index, capture) in group {
                if let capture {
                    result[ObjectIdentifier(screens[index])] = capture
                }
            }
        }
        ZSLog("pre-captured \(result.count)/\(screens.count) screen(s)")
        return result
    }

    // MARK: - 权限引导

    /// 无截屏权限时不弹窗，改为打开设置页的「截图」标签页展示权限引导
    private func presentPermissionGuide() {
        ZSLog("presentPermissionGuide: open settings")
        NotificationCenter.default.post(name: .zeroflowOpenSettings, object: nil)
    }

    // MARK: - 覆盖层

    private func createOverlayWindows() {
        let screens = NSScreen.screens
        ZSLog("creating overlay for \(screens.count) screen(s)")
        overlayWindows = screens.map { screen in
            ZSLog("overlay window for screen \(screen.frame)")
            let window = CaptureOverlayWindow(screen: screen,
                                              background: frozenImage(for: screen)) { [weak self] rect in
                ZSLog("selection completed: \(rect) on screen frame \(screen.frame)")
                self?.completeSelection(on: screen, rect: rect)
            } onCancel: { [weak self] in
                ZSLog("selection cancelled")
                self?.cancelSelection()
            }
            window.orderFrontRegardless()
            return window
        }
        installEscMonitor()
    }

    /// 预拍图 → 选区遮罩背景用的 NSImage（点尺寸 = 原生像素 / 缩放系数）
    private func frozenImage(for screen: NSScreen) -> NSImage? {
        guard let capture = pendingCaptures[ObjectIdentifier(screen)] else { return nil }
        return NSImage(cgImage: capture.cgImage,
                       size: NSSize(width: CGFloat(capture.cgImage.width) / capture.pixelScale,
                                    height: CGFloat(capture.cgImage.height) / capture.pixelScale))
    }

    /// 全局 Esc 监听：遮罩是非激活面板不再拥有 key 状态，键盘只能靠全局监听兜住
    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            DispatchQueue.main.async {
                self?.cancelSelection()
            }
        }
    }

    private func removeEscMonitor() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
    }

    private func completeSelection(on screen: NSScreen, rect: CGRect) {
        overlayWindow(for: screen)?.orderOut(nil)
        isActive = false
        let pending = pendingCaptures[ObjectIdentifier(screen)]
        pendingCaptures = [:]
        teardownOverlays()

        Task {
            // 优先从热键时的整屏预拍图裁剪（能截到当时的弹出框）
            if let pending {
                let image = ScreenCapture.crop(pending, on: screen, rect: rect)
                ZSLog("crop OK size=\(image.size)")
                await MainActor.run { self.openEditor(image: image) }
                return
            }
            // 预拍缺失时回退实时捕获
            ZSLog("capturing screen=\(screen.frame) rect=\(rect)")
            guard let image = await ScreenCapture.capture(screen: screen, rect: rect) else {
                ZSLog("capture returned nil")
                await MainActor.run { self.presentCaptureError() }
                return
            }
            ZSLog("capture OK size=\(image.size)")
            await MainActor.run {
                self.openEditor(image: image)
            }
        }
    }

    private func cancelSelection() {
        isActive = false
        teardownOverlays()
    }

    /// 延迟到下一轮事件循环再关闭遮罩窗口，避免在 keyDown/mouseUp 事件处理中
    /// close 正在派发事件的窗口导致释放后用崩溃（EXC_BAD_ACCESS）。
    private func teardownOverlays() {
        removeEscMonitor()
        pendingCaptures = [:]
        let windows = overlayWindows
        overlayWindows = []
        DispatchQueue.main.async {
            windows.forEach { $0.orderOut(nil) }
            NSCursor.arrow.set()
            windows.forEach { $0.close() }
        }
    }

    private func overlayWindow(for screen: NSScreen) -> CaptureOverlayWindow? {
        overlayWindows.first { $0.screen === screen }
    }

    private func presentCaptureError() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("截图失败")
        alert.informativeText = L10n.tr("无法捕获所选区域，请检查屏幕录制权限后重试。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("好的"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - 编辑器

    /// 调试专用：直接打开编辑页（绕过取景权限），用一张合成网格图测试标注
    func openEditorForDebug() {
        ZSLog("openEditorForDebug: synthetic 800x500 image")
        let size = NSSize(width: 800, height: 500)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.lightGray.withAlphaComponent(0.5).setStroke()
        for x in stride(from: CGFloat(0), through: size.width, by: 50) {
            NSBezierPath(rect: NSRect(x: x, y: 0, width: 1, height: size.height)).stroke()
        }
        for y in stride(from: CGFloat(0), through: size.height, by: 50) {
            NSBezierPath(rect: NSRect(x: 0, y: y, width: size.width, height: 1)).stroke()
        }
        image.unlockFocus()
        self.openEditor(image: image)
    }

    private func openEditor(image: NSImage) {
        if let controller = editorController {
            controller.close()
        }

        // 计算真实顶栏（标题栏）高度，让底部工具栏与之保持一致
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .resizable]
        let sampleFrame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let contentRect = NSWindow.contentRect(forFrameRect: sampleFrame, styleMask: styleMask)
        let titleBarHeight = sampleFrame.height - contentRect.height

        let glassBackground = SettingsStore.shared.editorGlassBackground
        let editorRootView = EditorView(
            image: image,
            onClose: {
                self.editorController?.close()
                self.editorController = nil
            },
            barHeight: titleBarHeight,
            glassBackground: glassBackground
        )

        let window = NSWindow()
        window.title = L10n.tr("zeroflow 截图")
        window.styleMask = styleMask
        window.isRestorable = false
        window.delegate = self
        if glassBackground {
            // 液态玻璃必须透过透明窗体采样（同剪贴板/切换器面板）；
            // 内容视图铺满整窗（含标题栏），SwiftUI 侧用标题栏高度补顶部留白，布局与非玻璃版一致
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView = PanelHostingContainer(rootView: editorRootView,
                                                       glassBackground: true,
                                                       cornerRadius: 0)
        } else {
            window.contentViewController = NSHostingController(rootView: editorRootView)
        }

        // 窗口初始尺寸根据截图自适应：
        // - 截图较小 → 窗口贴着截图大小（避免大片空白）
        // - 截图较大 → 缩放到窗口尺寸上限（避免显示不完）
        let imgSize = image.size
        let toolbarHeight: CGFloat = 64
        let maxW: CGFloat = 1100
        let maxH: CGFloat = 760
        // 最小宽度需保证底部工具栏所有按钮（撤销/重做/画线/标注/矩形/圆框/马赛克/颜色/粗细/下载/复制）完整显示
        let minW: CGFloat = 720
        let minH: CGFloat = 300

        var contentW = imgSize.width
        var contentH = imgSize.height + toolbarHeight
        let maxScale = min(maxW / max(contentW, 1), maxH / max(contentH, 1))
        if maxScale < 1 {
            contentW *= maxScale
            contentH *= maxScale
        }
        contentW = max(minW, min(contentW, maxW))
        contentH = max(minH, min(contentH, maxH))
        window.setContentSize(NSSize(width: contentW, height: contentH))
        window.minSize = NSSize(width: minW, height: minH)
        window.center()
        window.isRestorable = false

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 强制在窗口显示后立即布局渲染，避免首次打开出现空白
        window.contentView?.needsLayout = true
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        editorController = controller
    }
}

extension CaptureCoordinator: NSWindowDelegate {
    /// 编辑窗口被关闭（点红点 / ⌘W）时释放控制器，避免整张截图常驻内存
    func windowWillClose(_ notification: Notification) {
        editorController = nil
    }
}