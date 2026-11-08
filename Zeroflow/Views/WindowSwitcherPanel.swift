import SwiftUI
import AppKit

/// 切换会话的展示模型（仅在主线程读写）：瓦片 + 选中下标
final class WindowSwitcherViewModel: ObservableObject {
    @Published var tiles: [SwitcherWindow] = []
    @Published var selectedIndex = 0

    var selectedWindow: SwitcherWindow? {
        guard selectedIndex >= 0, selectedIndex < tiles.count else { return nil }
        return tiles[selectedIndex]
    }
}

/// 单个窗口卡：共享 `WindowCardView`，左上角注入退出/关闭/最小化/全屏四钮。
/// 无窗口占位卡只显退出钮。
struct SwitcherTileView: View {
    let tile: SwitcherWindow
    let isSelected: Bool
    let isHovered: Bool
    var onSelect: () -> Void
    var onAction: (WindowOperation) -> Void

    var body: some View {
        WindowCardView(
            thumbnail: tile.thumbnail,
            appIcon: tile.appIcon,
            title: tile.title,
            appName: tile.appName,
            showsLargeAppIcon: true,
            isSelected: isSelected,
            isHovered: isHovered,
            onSelect: onSelect
        ) {
            if tile.isWindowlessApp {
                TileActionButton(symbol: "power", title: L10n.tr("退出应用"), fill: .purple) { onAction(.quitApp) }
            } else {
                TileActionButton(symbol: "power", title: L10n.tr("退出应用"), fill: .purple) { onAction(.quitApp) }
                TileActionButton(symbol: "xmark", title: L10n.tr("关闭窗口"), fill: .red) { onAction(.close) }
                TileActionButton(symbol: "minus", title: L10n.tr("最小化"), fill: .yellow, symbolColor: .black) { onAction(.minimize) }
                TileActionButton(symbol: "arrow.up.left.and.arrow.down.right", title: L10n.tr("全屏切换"), fill: .green) { onAction(.maximize) }
            }
        }
    }
}

/// 切换器每行列数上限（面板布局与 CommandTabSwitcher 的方向键上下移动共用）
let switcherColumns = 6

/// 瓦片网格：每行最多 6 个，宽度随窗口数量自适应（不足 6 个时更窄），不满的行内容居中。
/// 悬停高亮、点击即切换；窗口多时整网格纵向滚动。
struct WindowSwitcherGridView: View {
    @ObservedObject var model: WindowSwitcherViewModel
    var glassBackground: Bool
    var onSelect: (CGWindowID) -> Void
    var onAction: (CGWindowID, WindowOperation) -> Void
    @State private var hoveredID: CGWindowID?

    private static let cardWidth: CGFloat = 148
    private static let spacing: CGFloat = 12

    /// 把瓦片切成每行 ≤ switcherColumns 的行（行序稳定、块内保序）
    private var rows: [[SwitcherWindow]] {
        let tiles = model.tiles
        guard !tiles.isEmpty else { return [] }
        return stride(from: 0, to: tiles.count, by: switcherColumns).map { start in
            Array(tiles[start..<min(start + switcherColumns, tiles.count)])
        }
    }

    /// 宽 = 列数×卡宽 + (列数-1)×间距 + 两侧 padding(14×2)；不足 6 个时按实际列数收窄
    private var gridWidth: CGFloat {
        let columns = max(1, min(model.tiles.count, switcherColumns))
        return CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * Self.spacing + 28
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Self.spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(spacing: Self.spacing) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { colIndex, tile in
                            let globalIndex = rowIndex * switcherColumns + colIndex
                            SwitcherTileView(
                                tile: tile,
                                isSelected: globalIndex == model.selectedIndex,
                                isHovered: hoveredID == tile.id,
                                onSelect: { onSelect(tile.id) },
                                onAction: { onAction(tile.id, $0) }
                            )
                            .onHover { hovering in
                                hoveredID = hovering ? tile.id : nil
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .frame(width: gridWidth, alignment: .center)
        }
        .frame(maxWidth: gridWidth)
        .background {
            if !glassBackground {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
            }
        }
        .padding(10)
    }
}

/// 切换面板窗口：非激活 borderless 面板，配置与截图遮罩窗口一致。
/// 键盘由 CommandTabSwitcher 的事件 tap 处理（canBecomeKey=false）；
/// 鼠标悬停/点击走 SwiftUI 手势。
final class WindowSwitcherPanel: NSPanel {
    private let container: PanelHostingContainer<WindowSwitcherGridView>

    init(model: WindowSwitcherViewModel,
         glassBackground: Bool,
         onSelect: @escaping (CGWindowID) -> Void,
         onAction: @escaping (CGWindowID, WindowOperation) -> Void) {
        let grid = WindowSwitcherGridView(model: model,
                                          glassBackground: glassBackground,
                                          onSelect: onSelect,
                                          onAction: onAction)
        self.container = PanelHostingContainer(rootView: grid,
                                               glassBackground: glassBackground,
                                               cornerRadius: 12,
                                               backdropInset: 10)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.contentView = container
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 居中于鼠标当前所在屏幕（多屏适配）。
    /// 先按 SwiftUI 内容的实际理想尺寸定窗，再算居中位置——
    /// 否则会用初始/上一会话的旧 frame 宽度算原点，窗口比预期宽时会向右偏。
    func centerOnMouseScreen() {
        let screens = NSScreen.screens
        let mouse = NSEvent.mouseLocation
        let screen = screens.first { $0.frame.contains(mouse) } ?? screens.first
        guard let screen else { center(); return }

        container.layoutSubtreeIfNeeded()
        let ideal = container.contentFittingSize
        let sizeOK = ideal.width >= 1 && ideal.height >= 1
        var size = NSSize(width: ceil(sizeOK ? ideal.width : frame.size.width),
                          height: ceil(sizeOK ? ideal.height : frame.size.height))
        let maxWidth = screen.frame.width - 40
        let maxHeight = screen.frame.height - 40
        if size.width > maxWidth || size.height > maxHeight {
            size = NSSize(width: min(size.width, maxWidth), height: min(size.height, maxHeight))
        }
        setContentSize(size)
        setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.midY - size.height / 2))
    }
}