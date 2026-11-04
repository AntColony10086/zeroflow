import AppKit
import ApplicationServices

/// 插入点定位：从系统当前焦点元素取 caret 矩形（Cocoa 全屏坐标），让剪贴板面板贴着光标弹出。
/// 必须在面板成为 key window **之前**调用——面板一 key，系统焦点就跑到面板自己的搜索框上。
enum CaretLocator {
    /// 优先级：caret 矩形 → 焦点元素整体（输入框下沿）→ nil（调用方回退鼠标位置）
    static func focusedAnchorRect() -> NSRect? {
        guard AccessibilityPermission.isGranted else { return nil }
        let systemWide = AXUIElementCreateSystemWide()
        // 目标 app 卡死时不能按默认超时拖死热键响应
        AXUIElementSetMessagingTimeout(systemWide, 0.25)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)

        // 焦点在自己身上（面板已弹出）时不能用，否则锚点会跑到搜索框
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        // 密码框不定位，避免把历史面板贴到密码输入框上
        guard !isSecureTextField(element) else { return nil }

        guard let axRect = caretRect(of: element) ?? elementFrame(element) else { return nil }
        return cocoaRect(fromAX: axRect)
    }

    private static func isSecureTextField(_ element: AXUIElement) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &raw) == .success,
              let subrole = raw as? String else { return false }
        return subrole == kAXSecureTextFieldSubrole
    }

    /// 插入点：取当前 selection 起点，用零长 range 问 AXBoundsForRange
    private static func caretRect(of element: AXUIElement) -> CGRect? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var selection = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &selection) else { return nil }

        var caret = CFRange(location: selection.location, length: 0)
        guard let parameter = AXValueCreate(.cfRange, &caret) else { return nil }
        var boundsRaw: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element,
                                                         kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter,
                                                         &boundsRaw) == .success,
              let boundsRaw, CFGetTypeID(boundsRaw) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRaw as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite, rect.height > 0 else { return nil }
        return rect
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        var posRaw: CFTypeRef?
        var sizeRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRaw) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRaw) == .success,
              let posRaw, let sizeRaw,
              CFGetTypeID(posRaw) == AXValueGetTypeID(), CFGetTypeID(sizeRaw) == AXValueGetTypeID() else {
            return nil
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posRaw as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRaw as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// AX 全屏坐标以「主屏左上角」为原点，Cocoa 以「主屏左下角」为原点
    private static func cocoaRect(fromAX rect: CGRect) -> NSRect? {
        guard let primary = NSScreen.screens.first else { return nil }
        let converted = NSRect(x: rect.minX,
                               y: primary.frame.maxY - rect.maxY,
                               width: max(1, rect.width),
                               height: rect.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(converted) }) else { return nil }
        return converted
    }
}
