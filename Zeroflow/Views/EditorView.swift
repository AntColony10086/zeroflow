import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 编辑页主视图：画布 + 底部工具栏
struct EditorView: View {
    @StateObject private var doc: EditDocument
    let onClose: () -> Void

    enum ToolState: Equatable {
        case select, pencil, bubble, rect, ellipse, mosaic
    }

    @State private var activeTool: ToolState = .pencil
    @State private var strokeWidth: CGFloat = 3
    @State private var showThicknessPanel = false
    @State private var hoveredWidth: CGFloat?
    @State private var showColorPanel = false
    @State private var tempStroke: StrokeElement?
    @State private var editingBubbleID: UUID?
    @State private var bubbleText: String = ""
    @State private var hoveredBubbleID: UUID?
    @State private var selectedElementID: UUID?
    @State private var lastTapTime: Date = .distantPast
    @State private var lastTapElementID: UUID?

    /// 矩形/圆框临时绘制
    @State private var tempShape: ShapeElement?
    @State private var shapeDragStart: CGPoint?

    /// 马赛克临时涂抹
    @State private var tempMosaic: MosaicElement?
    @State private var mosaicRadius: CGFloat = 18
    @State private var mosaicOverlayCache = MosaicOverlayCache()

    /// 元素拖动状态（气泡 / 形状）
    private enum ElementDragMode { case move, resize, anchor }
    private enum Corner { case tl, tr, bl, br }
    private struct ElementDragState {
        let id: UUID
        let mode: ElementDragMode
        let corner: Corner?
        let cursorStart: CGPoint  // 拖动起始点（图像坐标）
        let startAnchor: CGPoint
        let startBox: CGRect
    }
    @State private var elementDrag: ElementDragState?

    /// 标注固定配色：白色，不受画笔颜色影响
    private let bubbleAccent = Color.white
    private let bubbleBorder = Color.black.opacity(0.55)

    /// 气泡自动尺寸的上下限（图像坐标）
    private static let minBubbleWidth: CGFloat = 80
    private static let maxBubbleWidth: CGFloat = 240
    private static let minBubbleHeight: CGFloat = 34
    private static let maxBubbleHeight: CGFloat = 320

    /// 当前画笔颜色（默认红色）
    @State private var penColor: Color = .red
    private var strokeColor: Color { penColor }

    // 渲染几何
    @State private var displayRect: CGRect = .zero
    @State private var scaleFactor: CGFloat = 1

    private let settings = SettingsStore.shared
    private let barHeight: CGFloat
    private let glassBackground: Bool

    init(image: NSImage, onClose: @escaping () -> Void, barHeight: CGFloat = 28, glassBackground: Bool = false) {
        _doc = StateObject(wrappedValue: EditDocument(image: image))
        self.onClose = onClose
        self.barHeight = barHeight
        self.glassBackground = glassBackground
    }

    var body: some View {
        VStack(spacing: 0) {
            canvasArea
            Divider()
            toolbar
        }
        // 液态玻璃模式用 fullSizeContentView：内容铺满整窗，顶部补标题栏留白保持原布局
        .padding(.top, glassBackground ? barHeight : 0)
        .frame(minWidth: 720, minHeight: 300)
        .background {
            if !glassBackground {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .onAppear {
            installKeyboardMonitor()
        }
        .onDisappear {
            removeKeyboardMonitor()
        }
    }

    // MARK: - 键盘快捷键

    @State private var keyboardMonitor: Any?

    private func installKeyboardMonitor() {
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            // 正在编辑标注文字：除 Esc（提交并退出编辑）外，全部放行给文本编辑器
            if self.editingBubbleID != nil {
                if event.keyCode == 53 {
                    self.commitAnyPendingEdit()
                    return nil
                }
                return event
            }
            switch (event.keyCode, flags) {
            case (6, .command):              // ⌘Z 撤销
                self.doc.undo()
                return nil
            case (6, [.command, .shift]):    // ⇧⌘Z 重做
                self.doc.redo()
                return nil
            case (1, .command):              // ⌘S 下载
                self.download()
                return nil
            case (8, .command):              // ⌘C 复制
                self.copyImage()
                return nil
            case (37, [.command]):           // ⌘L 画线（37 = L）
                self.activeTool = .pencil
                return nil
            case (17, []):                   // T 标注
                self.activeTool = self.activeTool == .bubble ? .select : .bubble
                return nil
            case (51, []), (117, []):              // Backspace / Delete 删除选中标注
                if self.selectedElementID != nil {
                    self.deleteSelectedElement()
                    return nil
                }
                return event
            case (53, []):                   // Esc 关闭编辑
                self.onClose()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private var canvasArea: some View {
        GeometryReader { geo in
            ZStack {
                if !glassBackground {
                    Color(nsColor: .textBackgroundColor)
                }
                Canvas { context, size in
                    // 等比适配画布居中显示
                    let fit = fitRect(for: size)
                    context.draw(Image(nsImage: doc.image), in: fit)
                    drawElements(context: context, size: size)
                }
                .gesture(canvasGesture)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoveredBubbleID = hoveredBubbleID(at: location)
                    case .ended:
                        hoveredBubbleID = nil
                    }
                }

                if let bubble = editingBubble {
                    bubbleEditor(for: bubble)
                        .onChange(of: bubbleText) { updateEditingBubbleBox() }
                }
            }
            .onAppear {
                updateGeometry(size: geo.size)
            }
            .onChange(of: geo.size) { newSize in
                updateGeometry(size: newSize)
            }
        }
    }

    private func drawElements(context: GraphicsContext, size: CGSize) {
        var strokes: [StrokeElement] = []
        if let temp = tempStroke { strokes.append(temp) }
        for case .stroke(let s) in doc.elements { strokes.append(s) }
        for stroke in strokes { drawStroke(stroke, context: context) }

        for case .shape(let s) in doc.elements {
            drawShape(s, context: context, selected: s.id == selectedElementID)
        }
        if let temp = tempShape {
            drawShape(temp, context: context, selected: false)
        }

        for case .bubble(let b) in doc.elements {
            drawBubble(b, context: context, showText: b.id != editingBubbleID,
                       hovered: b.id == hoveredBubbleID,
                       selected: b.id == selectedElementID)
        }

        if let temp = tempMosaic {
            drawMosaic(temp, context: context)
        }
        for case .mosaic(let m) in doc.elements {
            drawMosaic(m, context: context)
        }
    }

    /// 图片在当前画布中等比居中后的绘制矩形
    private func fitRect(for size: CGSize) -> CGRect {
        let imageSize = doc.image.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else {
            return .zero
        }
        // 只缩小、不放大：保证像素清晰；放会被限制在原始尺寸
        let scale = min(1, min(size.width / imageSize.width, size.height / imageSize.height))
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func updateGeometry(size: CGSize) {
        // displayRect 与 scaleFactor 与真实绘制矩形保持一致，供手势换算使用
        displayRect = fitRect(for: size)
        guard displayRect.width > 0 else { return }
        scaleFactor = displayRect.width / doc.image.size.width
    }

    // MARK: - 坐标转换

    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - displayRect.minX) / scaleFactor,
                y: (p.y - displayRect.minY) / scaleFactor)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scaleFactor + displayRect.minX,
                y: p.y * scaleFactor + displayRect.minY)
    }

    private func toImageRect(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - displayRect.minX) / scaleFactor,
               y: (rect.minY - displayRect.minY) / scaleFactor,
               width: rect.width / scaleFactor,
               height: rect.height / scaleFactor)
    }

    private func toViewRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scaleFactor + displayRect.minX,
               y: rect.minY * scaleFactor + displayRect.minY,
               width: rect.width * scaleFactor,
               height: rect.height * scaleFactor)
    }

    // MARK: - 手势

    private var canvasGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard displayRect.contains(value.location) else { return }
                let imgPoint = toImage(value.location)
                switch activeTool {
                case .pencil:
                    if var stroke = tempStroke {
                        stroke.points.append(imgPoint)
                        tempStroke = stroke
                    } else {
                        tempStroke = StrokeElement(points: [imgPoint],
                                                   color: strokeColor,
                                                   lineWidth: strokeWidth)
                    }
                case .bubble:
                    break
                case .rect, .ellipse:
                    if shapeDragStart == nil {
                        shapeDragStart = imgPoint
                    }
                    if let start = shapeDragStart {
                        tempShape = ShapeElement(style: activeTool == .rect ? .rect : .ellipse,
                                                 box: normalizedRect(from: start, to: imgPoint),
                                                 color: strokeColor,
                                                 lineWidth: strokeWidth)
                    }
                case .mosaic:
                    if var mosaic = tempMosaic {
                        if let last = mosaic.points.last,
                           hypot(imgPoint.x - last.x, imgPoint.y - last.y) < mosaic.radius * 0.4 {
                            return
                        }
                        mosaic.points.append(imgPoint)
                        tempMosaic = mosaic
                    } else {
                        tempMosaic = MosaicElement(points: [imgPoint], radius: mosaicRadius)
                    }
                case .select:
                    if elementDrag == nil {
                        startElementDragIfNeeded(at: value.location)
                    }
                    applyElementDrag(to: value.location)
                }
            }
            .onEnded { value in
                let imgPoint = toImage(value.location)
                switch activeTool {
                case .pencil:
                    if var stroke = tempStroke {
                        stroke.points.append(imgPoint)
                        if stroke.points.count > 1 {
                            doc.snapshotBeforeChange()
                            doc.elements.append(.stroke(stroke))
                        }
                        tempStroke = nil
                    }
                case .bubble:
                    doc.snapshotBeforeChange()
                    let bubble = BubbleElement(
                        anchor: imgPoint,
                        box: defaultBubbleBox(at: imgPoint),
                        text: ""
                    )
                    doc.elements.append(.bubble(bubble))
                    bubbleText = ""
                    editingBubbleID = bubble.id
                    selectedElementID = bubble.id
                    activeTool = .select
                case .rect, .ellipse:
                    if let temp = tempShape, temp.box.width > 2, temp.box.height > 2 {
                        doc.snapshotBeforeChange()
                        doc.elements.append(.shape(temp))
                        selectedElementID = temp.id
                    }
                    tempShape = nil
                    shapeDragStart = nil
                    activeTool = .select
                case .mosaic:
                    if let temp = tempMosaic, temp.points.count > 0 {
                        doc.snapshotBeforeChange()
                        doc.elements.append(.mosaic(temp))
                    }
                    tempMosaic = nil
                case .select:
                    let tap = abs(value.translation.width) < 4 && abs(value.translation.height) < 4
                    if tap {
                        if let laterHit = element(at: value.location) {
                            let selID = laterHit.0
                            if selID == selectedElementID {
                                // 双击气泡打开文字编辑
                                let isDouble = Date().timeIntervalSince(lastTapTime) < 0.35 && lastTapElementID == selID
                                lastTapTime = Date()
                                lastTapElementID = selID
                                if isDouble, case .bubble = laterHit.1 {
                                    startTextEdit(for: selID)
                                }
                            } else {
                                lastTapTime = Date()
                                lastTapElementID = selID
                                selectedElementID = selID
                            }
                        } else {
                            // 点到空白处：结束文字编辑
                            commitAnyPendingEdit()
                            selectedElementID = nil
                            lastTapElementID = nil
                        }
                    }
                    endElementDrag()
                }
            }
    }

    // MARK: - 标注拖动（移动 / 缩放 / 锚点）

    /// 初始文本框（图像坐标）：锚点右上、较小
    private func defaultBubbleBox(at anchor: CGPoint) -> CGRect {
        let w: CGFloat = 100
        let h: CGFloat = 34
        return CGRect(x: anchor.x + 10, y: anchor.y - h - 12, width: w, height: h)
    }

    private func element(at location: CGPoint) -> (UUID, CanvasElement)? {
        for case .bubble(let b) in doc.elements {
            if bubbleHitRect(b).contains(location) { return (b.id, .bubble(b)) }
        }
        for case .shape(let s) in doc.elements {
            if shapeHitRect(s).contains(location) { return (s.id, .shape(s)) }
        }
        return nil
    }

    private func shapeHitRect(_ shape: ShapeElement) -> CGRect {
        toViewRect(shape.box).insetBy(dx: -6, dy: -6)
    }

    /// 归一化矩形：任意拖动方向都产生正的宽高
    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
               width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// 命中测试：优先缩放控点 → 锚点 → 主体，开始拖动
    private func startElementDragIfNeeded(at location: CGPoint) {
        // 若正处于某个标注的文字编辑中，先提交关闭覆盖层，避免挡住拖动
        commitAnyPendingEdit()

        // 1) 所有标注的四个角缩放控点（气泡 + 形状）
        for element in doc.elements {
            let box: CGRect
            switch element {
            case .bubble(let b): box = b.box
            case .shape(let s): box = s.box
            case .stroke, .mosaic: continue
            }
            let viewBox = toViewRect(box)
            for corner in [Corner.tl, .tr, .bl, .br] {
                let handlePos = cornerPoint(viewBox, corner)
                if CGRect(x: handlePos.x - 7, y: handlePos.y - 7, width: 14, height: 14).contains(location) {
                    selectedElementID = element.id
                    doc.snapshotBeforeChange()
                    elementDrag = ElementDragState(id: element.id, mode: .resize, corner: corner,
                                                   cursorStart: toImage(location),
                                                   startAnchor: .zero, startBox: box)
                    return
                }
            }
        }
        // 2) 气泡锚点
        for case .bubble(let b) in doc.elements {
            let anchorView = toView(b.anchor)
            let anchorHit = CGRect(x: anchorView.x - 9, y: anchorView.y - 9, width: 18, height: 18)
            if anchorHit.contains(location) {
                selectedElementID = b.id
                doc.snapshotBeforeChange()
                elementDrag = ElementDragState(id: b.id, mode: .anchor, corner: nil,
                                               cursorStart: toImage(location),
                                               startAnchor: b.anchor, startBox: b.box)
                return
            }
        }
        // 3) 主体 → 移动
        guard let (id, element) = element(at: location) else { return }
        selectedElementID = id
        doc.snapshotBeforeChange()
        let startBox: CGRect
        let startAnchor: CGPoint
        switch element {
        case .bubble(let b):
            startBox = b.box
            startAnchor = b.anchor
        case .shape(let s):
            startBox = s.box
            startAnchor = .zero
        default:
            startBox = .zero
            startAnchor = .zero
        }
        elementDrag = ElementDragState(id: id, mode: .move, corner: nil,
                                       cursorStart: toImage(location),
                                       startAnchor: startAnchor, startBox: startBox)
    }

    private func cornerPoint(_ viewBox: CGRect, _ corner: Corner) -> CGPoint {
        switch corner {
        case .tl: return CGPoint(x: viewBox.minX, y: viewBox.minY)
        case .tr: return CGPoint(x: viewBox.maxX, y: viewBox.minY)
        case .bl: return CGPoint(x: viewBox.minX, y: viewBox.maxY)
        case .br: return CGPoint(x: viewBox.maxX, y: viewBox.maxY)
        }
    }

    private func bubbleWith(id: UUID) -> (UUID, BubbleElement)? {
        guard let b = doc.elements.compactMap({
            if case .bubble(let bb) = $0, bb.id == id { return bb }
            return nil
        }).first else { return nil }
        return (id, b)
    }

    private func applyElementDrag(to location: CGPoint) {
        guard let drag = elementDrag, let index = doc.elements.firstIndex(where: { $0.id == drag.id }) else { return }
        let imgPoint = toImage(location)
        let dx = imgPoint.x - drag.cursorStart.x
        let dy = imgPoint.y - drag.cursorStart.y

        switch doc.elements[index] {
        case .bubble(let b):
            var newAnchor = b.anchor
            var newBox = b.box
            switch drag.mode {
            case .move:
                newAnchor = CGPoint(x: drag.startAnchor.x + dx, y: drag.startAnchor.y + dy)
                newBox = drag.startBox.offsetBy(dx: dx, dy: dy)
            case .anchor:
                newAnchor = CGPoint(x: drag.startAnchor.x + dx, y: drag.startAnchor.y + dy)
            case .resize:
                newBox = resizedBox(startBox: drag.startBox, corner: drag.corner ?? .br,
                                    deltaX: dx, deltaY: dy,
                                    minSize: CGSize(width: 48, height: 24))
            }
            doc.elements[index] = .bubble(BubbleElement(
                id: b.id, anchor: newAnchor, box: newBox, text: b.text))
        case .shape(let s):
            var newBox = s.box
            switch drag.mode {
            case .move:
                newBox = drag.startBox.offsetBy(dx: dx, dy: dy)
            case .resize:
                newBox = resizedBox(startBox: drag.startBox, corner: drag.corner ?? .br,
                                    deltaX: dx, deltaY: dy,
                                    minSize: CGSize(width: 8, height: 8))
            case .anchor:
                break
            }
            doc.elements[index] = .shape(ShapeElement(
                id: s.id, box: newBox, style: s.style, color: s.color, lineWidth: s.lineWidth))
        case .stroke, .mosaic:
            break
        }
    }

    /// 固定对角，按拖动的角调整文本框
    private func resizedBox(startBox: CGRect, corner: Corner, deltaX: CGFloat, deltaY: CGFloat, minSize: CGSize) -> CGRect {
        let opposite: CGRect = startBox
        var minX = opposite.minX
        var minY = opposite.minY
        var maxX = opposite.maxX
        var maxY = opposite.maxY
        switch corner {
        case .tl:
            minX = min(opposite.maxX - minSize.width, opposite.minX + deltaX)
            minY = min(opposite.maxY - minSize.height, opposite.minY + deltaY)
        case .tr:
            maxX = max(opposite.minX + minSize.width, opposite.maxX + deltaX)
            minY = min(opposite.maxY - minSize.height, opposite.minY + deltaY)
        case .bl:
            minX = min(opposite.maxX - minSize.width, opposite.minX + deltaX)
            maxY = max(opposite.minY + minSize.height, opposite.maxY + deltaY)
        case .br:
            maxX = max(opposite.minX + minSize.width, opposite.maxX + deltaX)
            maxY = max(opposite.minY + minSize.height, opposite.maxY + deltaY)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func endElementDrag() {
        elementDrag = nil
    }

    /// 删除当前选中的标注（气泡 / 形状）
    private func deleteSelectedElement() {
        guard let selID = selectedElementID else { return }
        doc.snapshotBeforeChange()
        doc.elements.removeAll { $0.id == selID }
        selectedElementID = nil
        if editingBubbleID == selID { editingBubbleID = nil }
    }

    private var editingBubble: BubbleElement? {
        guard let id = editingBubbleID else { return nil }
        return doc.elements.compactMap {
            if case .bubble(let b) = $0, b.id == id { return b }
            return nil
        }.first
    }

    // MARK: - 绘制

    private func drawStroke(_ stroke: StrokeElement, context: GraphicsContext) {
        let pts = stroke.points.map { toView($0) }
        guard pts.count >= 2, let first = pts.first else { return }
        var path = Path()
        path.move(to: first)
        for p in pts.dropFirst() { path.addLine(to: p) }
        context.stroke(path, with: .color(stroke.color),
                       style: StrokeStyle(lineWidth: stroke.lineWidth * scaleFactor,
                                          lineCap: .round, lineJoin: .round))
    }

    /// 矩形 / 圆框标注绘制（仅描边、透明填充）
    private func drawShape(_ shape: ShapeElement, context: GraphicsContext, selected: Bool) {
        let box = toViewRect(shape.box)
        let path: Path
        switch shape.style {
        case .rect: path = Path(box)
        case .ellipse: path = Path(ellipseIn: box)
        }
        context.stroke(path, with: .color(shape.color),
                       style: StrokeStyle(lineWidth: shape.lineWidth * scaleFactor,
                                          lineJoin: .round))
        if selected {
            drawSelectionHandles(for: box, context: context)
        }
    }

    /// 选中状态的四角缩放控点
    private func drawSelectionHandles(for box: CGRect, context: GraphicsContext) {
        for corner in [Corner.tl, .tr, .bl, .br] {
            let p = cornerPoint(box, corner)
            let handle = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: handle), with: .color(.accentColor))
            context.stroke(Path(ellipseIn: handle), with: .color(.white), lineWidth: 1.2)
        }
    }

    /// 马赛克涂抹绘制：整图像素化（网格对齐图片原点）后裁剪到每个涂抹圆形区域。
    /// 临时笔划与已提交笔划共用同一张叠加图，保证预览、提交、导出的样式完全一致。
    private func drawMosaic(_ mosaic: MosaicElement, context: GraphicsContext) {
        guard let first = mosaic.points.first else { return }
        let r = mosaic.radius
        var mask = Path()
        for p in mosaic.points {
            let vp = toView(p)
            mask.addEllipse(in: CGRect(x: vp.x - r, y: vp.y - r, width: r * 2, height: r * 2))
        }
        guard let overlay = mosaicOverlayCache.fullOverlay(radius: mosaic.radius, source: doc.image) else { return }
        let viewRect = toViewRect(CGRect(origin: .zero, size: doc.image.size))
        context.drawLayer { layer in
            layer.clip(to: mask)
            layer.draw(Image(nsImage: overlay), in: viewRect)
        }
    }

    /// 把图像指定区域做马赛克（缩小后最近邻放大），返回同样点位分辨率的叠加图
    private static func pixelatedImage(_ source: NSImage, in region: CGRect, block: CGFloat) -> NSImage? {
        guard region.width > 0, region.height > 0, block > 0 else { return nil }
        let result = NSImage(size: region.size)
        let smallW = max(1, Int(ceil(region.width / block)))
        let smallH = max(1, Int(ceil(region.height / block)))
        let small = NSImage(size: NSSize(width: smallW, height: smallH))
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        source.draw(in: NSRect(x: 0, y: 0, width: smallW, height: smallH),
                    from: region, operation: .copy, fraction: 1)
        small.unlockFocus()
        result.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        small.draw(in: NSRect(origin: .zero, size: result.size),
                   from: .zero, operation: .copy, fraction: 1)
        result.unlockFocus()
        return result
    }

    // MARK: - 文字标注

    /// 标注绘制（预览）：锚点圆点 → 向右上引线 → 黑色文本框
    private func drawBubble(_ bubble: BubbleElement, context: GraphicsContext, showText: Bool, hovered: Bool, selected: Bool) {
        let anchor = toView(bubble.anchor)
        let box = toViewRect(bubble.box)
        let isActive = hovered || selected

        // 锚点圆点
        let dotRadius: CGFloat = isActive ? 4.5 : 3
        let dotOutline = Path(ellipseIn: CGRect(x: anchor.x - dotRadius - 1, y: anchor.y - dotRadius - 1,
                                                width: (dotRadius + 1) * 2, height: (dotRadius + 1) * 2))
        let dot = Path(ellipseIn: CGRect(x: anchor.x - dotRadius, y: anchor.y - dotRadius,
                                         width: dotRadius * 2, height: dotRadius * 2))
        context.fill(dotOutline, with: .color(bubbleBorder))
        context.fill(dot, with: .color(isActive ? .accentColor : bubbleAccent))
        if isActive {
            context.stroke(dot, with: .color(Color.black.opacity(0.35)), lineWidth: 1)
        }

        // 引线：锚点连到文本框底部边（黑描边 + 白色主线）
        var line = Path()
        line.move(to: anchor)
        line.addLine(to: toView(bubble.lineEnd))
        context.stroke(line, with: .color(bubbleBorder), style: StrokeStyle(lineWidth: 3.5))
        context.stroke(line, with: .color(bubbleAccent), style: StrokeStyle(lineWidth: 1.5))

        // 白色文本框（黑色文字）
        let bodyPath = RoundedRectangle(cornerRadius: 6).path(in: box)
        context.fill(bodyPath, with: .color(Color.white))
        context.stroke(bodyPath,
                       with: .color(isActive ? .accentColor : bubbleBorder),
                       style: StrokeStyle(lineWidth: isActive ? 1.6 : 1,
                                          dash: selected ? [4, 3] : []))

        if showText, !bubble.text.isEmpty {
            let text = Text(bubble.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.black)
            context.draw(text, in: box.insetBy(dx: 6, dy: 4))
        }

        // 选中时显示四周缩放控点
        if selected {
            drawSelectionHandles(for: box, context: context)
        }
    }

    /// 命中测试：根据画布坐标返回悬停的标注框 id（文本框 + 锚点）
    private func hoveredBubbleID(at location: CGPoint) -> UUID? {
        for case .bubble(let b) in doc.elements {
            if bubbleHitRect(b).contains(location) { return b.id }
        }
        return nil
    }

    private func bubbleHitRect(_ bubble: BubbleElement) -> CGRect {
        let box = toViewRect(bubble.box).insetBy(dx: -6, dy: -6)
        let anchor = toView(bubble.anchor)
        let dot = CGRect(x: anchor.x - 6, y: anchor.y - 6, width: 12, height: 12)
        return box.union(dot)
    }

    // MARK: - 文字编辑控件

    /// 编辑态文本框：仅文字编辑视图（白框由画布 drawBubble 绘制），不遮挡整盒拖拽/缩放命中
    private func bubbleEditor(for bubble: BubbleElement) -> some View {
        let box = toViewRect(bubble.box)
        let textW = max(box.width - 12, 1)
        let textH = max(box.height - 8, 1)
        return BubbleTextView(text: $bubbleText)
            .frame(width: textW, height: textH)
            .position(x: box.midX, y: box.midY)
            .onDisappear { commitBubbleEdit(bubble) }
    }

    /// 点击存在的标注 → 进入文字编辑模式
    private func startTextEdit(for id: UUID) {
        guard let (_, b) = bubbleWith(id: id) else { return }
        bubbleText = b.text
        editingBubbleID = id
        selectedElementID = id
    }

    private func commitBubbleEdit(_ bubble: BubbleElement) {
        guard let index = doc.elements.firstIndex(where: { $0.id == bubble.id }) else { return }
        if case .bubble(let b) = doc.elements[index] {
            let text = bubbleText
            let box = bubbleBox(for: b.box, text: text)
            if b.box != box || b.text != text {
                doc.snapshotBeforeChange()
            }
            doc.elements[index] = .bubble(BubbleElement(
                id: b.id, anchor: b.anchor, box: box,
                text: text))
        }
        editingBubbleID = nil
    }

    /// 输入过程中实时把气泡框调整到适应文字的大小
    private func updateEditingBubbleBox() {
        guard let id = editingBubbleID,
              let index = doc.elements.firstIndex(where: { $0.id == id }),
              case .bubble(let b) = doc.elements[index] else { return }
        let box = bubbleBox(for: b.box, text: bubbleText)
        guard box != b.box else { return }
        doc.elements[index] = .bubble(BubbleElement(id: b.id, anchor: b.anchor, box: box, text: b.text))
    }

    /// 依据文字计算气泡框（图像坐标）：宽度上限 240，高度自适应；锚定右上角生长，引线出点保持稳定
    private func bubbleBox(for current: CGRect, text: String) -> CGRect {
        let size = fittedBubbleSize(for: text)
        let right = current.maxX
        let top = current.maxY
        return CGRect(x: right - size.width, y: top - size.height,
                      width: size.width, height: size.height)
    }

    private func fittedBubbleSize(for text: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let maxViewWidth = Self.maxBubbleWidth * scaleFactor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(1, maxViewWidth), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        let scale = max(scaleFactor, 0.01)
        let width = max(Self.minBubbleWidth,
                        min(Self.maxBubbleWidth, (bounds.width + 16) / scale))
        let height = max(Self.minBubbleHeight,
                         min(Self.maxBubbleHeight, (bounds.height + 10) / scale))
        return CGSize(width: width, height: height)
    }

    // MARK: - 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                toolButton(systemImage: "arrow.uturn.backward", tip: L10n.tr("撤回 (⌘Z)"), disabled: !doc.canUndo) {
                    commitAnyPendingEdit()
                    doc.undo()
                }
                toolButton(systemImage: "arrow.uturn.forward", tip: L10n.tr("重做 (⇧⌘Z)"), disabled: !doc.canRedo) {
                    commitAnyPendingEdit()
                    doc.redo()
                }
            }

            Divider().frame(height: 14)

            HStack(spacing: 2) {
                toolButton(systemImage: "pencil", tip: L10n.tr("画线 (L)"), highlighted: activeTool == .pencil) {
                    commitAnyPendingEdit()
                    activeTool = activeTool == .pencil ? .select : .pencil
                }
                toolButton(systemImage: "rectangle", tip: L10n.tr("矩形标注"), highlighted: activeTool == .rect) {
                    commitAnyPendingEdit()
                    activeTool = activeTool == .rect ? .select : .rect
                }
                toolButton(systemImage: "circle", tip: L10n.tr("圆框标注"), highlighted: activeTool == .ellipse) {
                    commitAnyPendingEdit()
                    activeTool = activeTool == .ellipse ? .select : .ellipse
                }
                Divider().frame(height: 14)
                colorSquareButton
                    .disabled(!drawingPenToolsActive)
                    .opacity(drawingPenToolsActive ? 1 : 0.35)
                    .padding(.trailing, 4)
                thicknessMenu
                    .disabled(!drawingPenToolsActive)
                    .opacity(drawingPenToolsActive ? 1 : 0.35)
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            toolButton(systemImage: "text.bubble.fill", tip: L10n.tr("标注 (T)"), highlighted: activeTool == .bubble) {
                commitAnyPendingEdit()
                activeTool = activeTool == .bubble ? .select : .bubble
            }

            HStack(alignment: .center, spacing: 4) {
                mosaicToolButton(radius: 12, cell: 3, diameter: 14, tip: L10n.tr("马赛克 小"))
                mosaicToolButton(radius: 18, cell: 4, diameter: 18, tip: L10n.tr("马赛克 中"))
                mosaicToolButton(radius: 28, cell: 5.6, diameter: 21, tip: L10n.tr("马赛克 大"))
            }
            .padding(2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                toolButton(systemImage: "arrow.down.to.line", tip: L10n.tr("下载保存 (⌘S)")) {
                    commitAnyPendingEdit()
                    download()
                }
                toolButton(systemImage: "doc.on.doc", tip: L10n.tr("复制 (⌘C)")) {
                    commitAnyPendingEdit()
                    copyImage()
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: barHeight)
        .background {
            if !glassBackground {
                Color(nsColor: .controlBackgroundColor)
            }
        }
        .overlay(
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(height: 1 / (NSScreen.main?.backingScaleFactor ?? 1))
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    /// 粗细下拉框：显示当前粗细线条，点击弹出 细/中/粗 三个线条选项
    private var thicknessMenu: some View {
        Button {
            showThicknessPanel = true
        } label: {
            HStack(spacing: 3) {
                Capsule()
                    .fill(strokeColor)
                    .frame(width: 16, height: strokeWidth)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .frame(minWidth: 40, minHeight: 24, maxHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showThicknessPanel, arrowEdge: .bottom) {
            VStack(spacing: 4) {
                ForEach([CGFloat(2), 5, 9], id: \.self) { width in
                    Button {
                        strokeWidth = width
                        showThicknessPanel = false
                    } label: {
                        RoundedRectangle(cornerRadius: width / 2)
                            .fill(strokeWidth == width ? strokeColor : Color(white: 0.78))
                            .frame(width: 60, height: width)
                            .frame(width: 80, height: 24, alignment: .center)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(strokeWidth == width ? Color.accentColor.opacity(0.3) : (hoveredWidth == width ? Color.secondary.opacity(0.18) : Color.clear))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            hoveredWidth = hovering ? width : nil
                        }
                    }
                }
            }
            .padding(6)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .help(L10n.tr("粗细"))
    }

    /// 马赛克工具按钮：圆形马赛克图标，整体尺寸随 `diameter` 递增体现 小/中/大；点击设置半径并切换工具
    private func mosaicToolButton(radius: CGFloat, cell: CGFloat, diameter: CGFloat, tip: String) -> some View {
        let active = activeTool == .mosaic && mosaicRadius == radius
        return Button {
            commitAnyPendingEdit()
            let wasActive = active
            mosaicRadius = radius
            activeTool = wasActive ? .select : .mosaic
        } label: {
            MosaicGlyph(cell: cell, diameter: diameter,
                        tint: active ? .accentColor : Color.primary.opacity(0.72))
                .contentShape(Circle())
                .background(Circle().fill(active ? Color.accentColor.opacity(0.18) : Color.clear))
                .overlay(
                    Circle()
                        .stroke(active ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    /// 是否启用画笔颜色 / 粗细（画笔、矩形、圆框）
    private var drawingPenToolsActive: Bool {
        switch activeTool {
        case .pencil, .rect, .ellipse: return true
        case .select, .bubble, .mosaic: return false
        }
    }

    /// 预设画笔颜色
    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple,
        .pink, .gray, .black, .white,
    ]

    /// 画笔颜色选择（圆形按钮，点击以气泡方式弹出预设色板；选择颜色或点击空白处自动关闭）
    private var colorSquareButton: some View {
        Button {
            showColorPanel = true
        } label: {
            Circle()
                .fill(strokeColor)
                .frame(width: 16, height: 16)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.75)
                )
                .padding(2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showColorPanel, arrowEdge: .bottom) {
            HStack(spacing: 6) {
                ForEach(Array(presetColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        penColor = color
                        showColorPanel = false
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .stroke(penColor == color ? Color.accentColor : Color.black.opacity(0.15),
                                            lineWidth: penColor == color ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .help(L10n.tr("画笔颜色"))
    }

        private func commitAnyPendingEdit() {
        if let bubble = editingBubble {
            commitBubbleEdit(bubble)
        }
    }

    private func toolButton(systemImage: String, tip: String, disabled: Bool = false, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .background(highlighted && !disabled ? Color.accentColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(highlighted && !disabled ? Color.accentColor : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .help(tip)
    }

    // MARK: - 导出

    /// 按原图尺寸重绘整张导出图（无视图依赖）。在后台线程调用（AppKit 离屏绘制线程安全）。
    /// 画布按原图「原生像素」建位图（不再用 NSImage(size:)+lockFocus 的隐式像素密度），
    /// 上下文按 pixelScale 缩放后复用点坐标绘制——保证导出 PNG 分辨率 = 屏幕原生分辨率。
    private static func exportedImage(image: NSImage, elements: [CanvasElement]) -> NSImage {
        guard let baseCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let pixelScale = CGFloat(baseCG.width) / max(image.size.width, 1)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: baseCG.width,
                                         pixelsHigh: baseCG.height,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return image
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: pixelScale, y: pixelScale)

        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)

        for element in elements {
            switch element {
            case .stroke(let s):
                let path = NSBezierPath()
                guard let first = s.points.first, s.points.count > 1 else { continue }
                path.move(to: first)
                for p in s.points.dropFirst() { path.line(to: p) }
                path.lineWidth = s.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                s.color.nsColor.setStroke()
                path.stroke()
            case .bubble(let b):
                drawBubbleIntoCanvas(b)
            case .shape(let s):
                let path: NSBezierPath
                switch s.style {
                case .rect: path = NSBezierPath(rect: s.box)
                case .ellipse: path = NSBezierPath(ovalIn: s.box)
                }
                path.lineWidth = s.lineWidth
                path.lineJoinStyle = .round
                s.color.nsColor.setStroke()
                path.stroke()
            case .mosaic(let m):
                drawMosaicIntoCanvas(m, image: image)
            }
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: NSSize(width: baseCG.width, height: baseCG.height))
        result.addRepresentation(rep)
        ZSLog("export canvas: input=\(image.size.width)x\(image.size.height)pt baseCG=\(baseCG.width)x\(baseCG.height)px scale=\(pixelScale)")
        return result
    }

    /// 后台渲染导出图 + PNG 编码，避免大图在主线程卡死 UI
    private func encodeExportInBackground() async -> Data? {
        let image = doc.image
        let elements = doc.elements
        return await Task.detached(priority: .userInitiated) {
            let exported = Self.exportedImage(image: image, elements: elements)
            guard let data = exported.pngData,
                  let rep = NSBitmapImageRep(data: data) else {
                ZSLog("export png encode failed")
                return nil
            }
            ZSLog("export png: \(rep.pixelsWide)x\(rep.pixelsHigh)px data=\(data.count)")
            return data
        }.value
    }

    private static func drawBubbleIntoCanvas(_ bubble: BubbleElement) {
        let anchor = bubble.anchor
        let box = bubble.box        // 锚点圆点（黑描边 + 白点）
        let dotOutline = NSBezierPath(ovalIn: NSRect(x: anchor.x - 4, y: anchor.y - 4, width: 8, height: 8))
        NSColor.black.withAlphaComponent(0.55).setFill()
        dotOutline.fill()
        let dot = NSBezierPath(ovalIn: NSRect(x: anchor.x - 3, y: anchor.y - 3, width: 6, height: 6))
        NSColor.white.setFill()
        dot.fill()

        // 引线（黑描边 + 白色主线）
        let line = NSBezierPath()
        line.move(to: anchor)
        line.line(to: bubble.lineEnd)
        line.lineWidth = 3.5
        NSColor.black.withAlphaComponent(0.55).setStroke()
        line.stroke()
        line.lineWidth = 1.5
        NSColor.white.setStroke()
        line.stroke()

        // 白色文本框（黑色文字）
        let body = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.white.setFill()
        body.fill()
        NSColor.black.withAlphaComponent(0.55).setStroke()
        body.lineWidth = 1
        body.stroke()

        if !bubble.text.isEmpty {
            let font = NSFont.systemFont(ofSize: 11, weight: .medium)
            let attributed = NSAttributedString(
                string: bubble.text,
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            attributed.draw(in: box.insetBy(dx: 6, dy: 4))
        }
    }

    private static func drawMosaicIntoCanvas(_ mosaic: MosaicElement, image: NSImage) {
        guard let first = mosaic.points.first else { return }
        let r = mosaic.radius
        let fullRect = CGRect(origin: .zero, size: image.size)
        guard let overlay = Self.pixelatedImage(image, in: fullRect,
                                                block: max(4, mosaic.radius * 0.5)) else { return }

        let clip = NSBezierPath()
        for p in mosaic.points {
            clip.appendOval(in: NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        }
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        overlay.draw(in: fullRect, from: NSRect(origin: .zero, size: overlay.size),
                     operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 下载 / 复制

    private func download() {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: settings.saveDirectory)
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let name = Self.fileName()

        func write(to url: URL) {
            Task {
                guard let data = await encodeExportInBackground() else {
                    presentAlert(title: L10n.tr("保存失败"), message: L10n.tr("无法生成图片数据"))
                    return
                }
                do {
                    try data.write(to: url, options: .atomic)
                    SettingsStore.shared.lastSavedPath = url.path
                } catch {
                    presentAlert(title: L10n.tr("保存失败"), message: error.localizedDescription)
                }
            }
        }

        if settings.askSaveLocation {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png]
            panel.nameFieldStringValue = name
            panel.directoryURL = dirURL
            panel.begin { response in
                if response == .OK, let url = panel.url { write(to: url) }
            }
        } else {
            var url = dirURL.appendingPathComponent(name)
            var counter = 1
            while fm.fileExists(atPath: url.path) {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                url = dirURL.appendingPathComponent("\(base)-\(counter).\(ext)")
                counter += 1
            }
            write(to: url)
        }
    }

    private func copyImage() {
        Task {
            let image = doc.image
            let elements = doc.elements
            let rendered = await Task.detached(priority: .userInitiated) {
                Self.exportedImage(image: image, elements: elements)
            }.value
            let pb = NSPasteboard.general
            pb.clearContents()
            if let data = rendered.pngData {
                pb.setData(data, forType: .png)
            } else {
                pb.writeObjects([rendered])
            }
        }
    }

    static func fileName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return "zeroflow_\(df.string(from: Date())).png"
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.tr("好的"))
        alert.runModal()
    }

    /// 马赛克像素化叠加图缓存：同一半径的整图像素化只算一次，临时笔划与已提交笔划共用，
    /// 保证预览与提交后的样式一致。只保留当前半径一张（切到新半径时替换旧的），
    /// 避免多半径各存一份整图造成的重复内存占用。
    private final class MosaicOverlayCache {
        private var cachedRadius: CGFloat?
        private var cachedOverlay: NSImage?

        func fullOverlay(radius: CGFloat, source: NSImage) -> NSImage? {
            if let cachedRadius, cachedRadius == radius, let cachedOverlay {
                return cachedOverlay
            }
            let fullRect = CGRect(origin: .zero, size: source.size)
            guard let overlay = EditorView.pixelatedImage(source, in: fullRect,
                                                          block: max(4, radius * 0.5)) else { return nil }
            cachedRadius = radius
            cachedOverlay = overlay
            return overlay
        }
    }
}

// MARK: - 辅助

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

extension Color {
    var nsColor: NSColor { NSColor(self) }
}

// MARK: - 气泡文字编辑（NSTextView 包装）

/// NSTextView 包装：创建气泡后自动聚焦、可直接输入；背景透明（白框由画布绘制）、随内容自适应
private struct BubbleTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextView {
        let tv = NSTextView(frame: .zero)
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textColor = .black
        tv.insertionPointColor = .black
        tv.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        tv.autoresizingMask = []
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = true
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.delegate = context.coordinator
        return tv
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {
        if nsView.string != text {
            nsView.string = text
        }
        context.coordinator.requestFocus(nsView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var parent: BubbleTextView
        private var hasRequestedFocus = false

        init(_ parent: BubbleTextView) {
            self.parent = parent
        }

        /// 首次出现时把键盘焦点交给编辑框（同一 NSTextView 只执行一次）
        func requestFocus(_ tv: NSTextView) {
            guard !hasRequestedFocus else { return }
            hasRequestedFocus = true
            DispatchQueue.main.async { [weak tv] in
                tv?.window?.makeFirstResponder(tv)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            DispatchQueue.main.async {
                self.parent.text = tv.string
            }
        }
    }
}

// MARK: - 马赛克图标（圆形像素块）

/// 自绘马赛克图标：与涂抹一致的正圆形笔刷头像内绘制 n×n 像素格马赛克块，`diameter` 决定整体大小、颗粒细度由 小/中/大 区分
private struct MosaicGlyph: View {
    var cell: CGFloat
    var diameter: CGFloat
    var tint: Color

    /// 像素格数：小→4×4、中→3×3、大→2×2，体现马赛克颗粒粗细
    private var dimension: Int {
        switch cell {
        case ..<3.5: return 4
        case ..<4.8: return 3
        default: return 2
        }
    }

    /// 棋盘相间的马赛克像素图案：实色格打底、淡色格填充，营造"像素化"质感
    private var mask: [[Bool]] {
        let n = dimension
        return (0..<n).map { r in
            (0..<n).map { c in (r + c) % 2 == 0 }
        }
    }

    var body: some View {
        let n = dimension
        let gap: CGFloat = diameter >= 20 ? 1.5 : (diameter >= 16 ? 1 : 0.8)
        let inner = diameter - CGFloat(n - 1) * gap
        let tile = max(1, inner / CGFloat(n))
        return VStack(spacing: gap) {
            ForEach(0..<n, id: \.self) { r in
                HStack(spacing: gap) {
                    ForEach(0..<n, id: \.self) { c in
                        RoundedRectangle(cornerRadius: 0.8)
                            .fill(mask[r][c] ? tint.opacity(0.9) : tint.opacity(0.24))
                            .frame(width: tile, height: tile)
                    }
                }
            }
        }
        .clipShape(Circle())
        .frame(width: diameter, height: diameter)
        .background(
            Circle()
                .fill(tint.opacity(0.12))
        )
        .contentShape(Circle())
    }
}