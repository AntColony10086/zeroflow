import SwiftUI
import AppKit

/// 面板背景：macOS 26+ 原生液态玻璃（跟随外观/降低透明度），旧系统回退磨砂。
/// 与剪贴板面板同口径（DEV-017 / DEV-037）。
enum PanelGlassBackground {
    static func make(cornerRadius: CGFloat) -> NSView {
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.cornerRadius = cornerRadius
            backdrop = glass
        } else {
            let effect = NSVisualEffectView(frame: .zero)
            effect.material = .popover
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            backdrop = effect
        }
        return backdrop
    }
}

/// 面板内容容器：玻璃背景垫底 + `NSHostingView` 铺满上层。
/// hosting 只用 autoresizing 跟随容器（DEV-024 / DEV-037），不参与 Auto Layout；
/// 面板尺寸仍由 `contentFittingSize` 按 SwiftUI 内容自然尺寸决定。
final class PanelHostingContainer<Content: View>: NSView {
    let hosting: NSHostingView<Content>
    private let backdrop: NSView?
    private let backdropInset: CGFloat

    init(rootView: Content,
         glassBackground: Bool,
         cornerRadius: CGFloat,
         backdropInset: CGFloat = 0) {
        self.hosting = NSHostingView(rootView: rootView)
        self.backdropInset = backdropInset
        self.backdrop = glassBackground
            ? PanelGlassBackground.make(cornerRadius: cornerRadius)
            : nil
        super.init(frame: .zero)

        if let backdrop {
            backdrop.frame = insetFrame
            addSubview(backdrop)
        }
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// SwiftUI 内容的自然尺寸（面板定位 / 自动定窗用）
    var contentFittingSize: NSSize { hosting.fittingSize }

    private var insetFrame: NSRect {
        let rect = bounds.insetBy(dx: backdropInset, dy: backdropInset)
        return rect.width > 0 && rect.height > 0 ? rect : .zero
    }

    override func layout() {
        super.layout()
        backdrop?.frame = insetFrame
    }
}
