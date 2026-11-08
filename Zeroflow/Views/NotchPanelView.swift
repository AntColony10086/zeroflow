import SwiftUI
import AppKit
import EventKit

/// 灵动岛面板的一条日程（主线程由 EKEvent 转换生成）
struct NotchEventItem: Identifiable, Equatable {
    let id: String
    let title: String
    let timeText: String
    let color: NSColor
}

/// 月视图日历的视图模型（仅主线程读写）。面板每次弹出 reset() 回到今天。
/// 数据加载走后台查询，代数（monthGen/dayGen）作废在途结果，面板关开/快速翻月不串数据。
final class NotchCalendarViewModel: ObservableObject {
    @Published private(set) var monthAnchor: Date = Date()
    @Published private(set) var selectedDate: Date = Date()
    /// 显示月份中有日程的日期（本地时区当日零点）
    @Published private(set) var monthEventDays: Set<Date> = []
    @Published private(set) var dayEvents: [NotchEventItem] = []
    @Published private(set) var authStatus: EKAuthorizationStatus = CalendarService.shared.status

    private var monthGen = 0
    private var dayGen = 0

    /// 日历与本地化随设置语言变化（跟随系统/zh/en/ja）
    var calendar: Calendar { SettingsStore.shared.appLanguage.locale.calendar }

    var isAuthorized: Bool { authStatus == .fullAccess }

    // MARK: - 状态迁移

    func reset() {
        let now = Date()
        monthAnchor = startOfMonth(now)
        selectedDate = calendar.startOfDay(for: now)
        refreshAuth()
        if authStatus == .notDetermined {
            CalendarService.shared.requestAccess { [weak self] _ in
                guard let self else { return }
                self.refreshAuth()
                self.reloadMonth()
                self.reloadDay()
            }
        }
        reloadMonth()
        reloadDay()
    }

    func refreshAuth() {
        let status = CalendarService.shared.status
        if status != authStatus {
            authStatus = status
        }
    }

    /// 翻月；选中日跟随到新月份同日（超出天数钳到月末）
    func moveMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthAnchor),
              let range = calendar.range(of: .day, in: .month, for: next) else { return }
        monthAnchor = startOfMonth(next)
        var comps = calendar.dateComponents([.year, .month], from: next)
        comps.day = min(calendar.component(.day, from: selectedDate), range.count)
        if let moved = calendar.date(from: comps) {
            selectedDate = calendar.startOfDay(for: moved)
        }
        reloadMonth()
        reloadDay()
    }

    func select(_ day: Date) {
        let dayStart = calendar.startOfDay(for: day)
        guard dayStart != selectedDate else { return }
        selectedDate = dayStart
        reloadDay()
    }

    // MARK: - 数据加载

    private func reloadMonth() {
        monthGen += 1
        let gen = monthGen
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = CalendarService.shared.events(from: interval.start, to: interval.end)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.monthGen else { return }
                var days = Set<Date>()
                for event in events {
                    // 跨天日程在区间内的每一天都打点（EventKit 结束时间为独占的次日零点）
                    let from = max(event.startDate, interval.start)
                    let to = min(event.endDate, interval.end)
                    var day = self.calendar.startOfDay(for: from)
                    while day < to {
                        days.insert(day)
                        guard let next = self.calendar.date(byAdding: .day, value: 1, to: day) else { break }
                        day = next
                    }
                }
                self.monthEventDays = days
            }
        }
    }

    private func reloadDay() {
        dayGen += 1
        let gen = dayGen
        let dayStart = selectedDate
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let events = CalendarService.shared.events(from: dayStart, to: dayEnd)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.dayGen else { return }
                self.dayEvents = events
                    .sorted { lhs, rhs in
                        if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                        return lhs.title < rhs.title
                    }
                    .map { self.makeItem($0) }
            }
        }
    }

    private func makeItem(_ event: EKEvent) -> NotchEventItem {
        // macOS 上 EKCalendar.color 即 NSColor（iOS 才是 CGColor）
        let color = event.calendar?.color ?? .controlAccentColor
        let timeText: String
        if event.isAllDay {
            timeText = L10n.tr("全天")
        } else {
            // EventKit 的 endDate 为独占（次日零点），回退 1s 取真实末日
            let lastDay = event.endDate.addingTimeInterval(-1)
            if calendar.isDate(event.startDate, inSameDayAs: lastDay) {
                let end = lastDay
                if calendar.compare(event.startDate, to: end, toGranularity: .minute) == .orderedSame {
                    timeText = Self.timeFormatter.string(from: event.startDate)
                } else {
                    timeText = "\(Self.timeFormatter.string(from: event.startDate)) – \(Self.timeFormatter.string(from: end))"
                }
            } else {
                timeText = "\(Self.dayFormatter.string(from: event.startDate)) – \(Self.dayFormatter.string(from: lastDay))"
            }
        }
        let title = (event.title?.isEmpty == false) ? event.title! : L10n.tr("无标题日程")
        return NotchEventItem(
            id: "\(event.calendarItemIdentifier)-\(event.startDate.timeIntervalSince1970)",
            title: title,
            timeText: timeText,
            color: color
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    // MARK: - 月网格

    func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    /// 月网格单元格：按周首日补前置空位 + 当月日期，末尾补齐到 6 行（面板高度稳定不跳）
    func monthCells() -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let leading = (calendar.component(.weekday, from: interval.start) - calendar.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            cells.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        while cells.count < 42 { cells.append(nil) }
        return cells
    }

    /// 按周首日重排的极短星期符号
    var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    var monthTitle: String {
        titleFormatter(template: "yMMMM").string(from: monthAnchor)
    }

    var selectedTitle: String {
        titleFormatter(template: "MMMd EEEE").string(from: selectedDate)
    }

    private func titleFormatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = SettingsStore.shared.appLanguage.locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    func dayNumber(_ date: Date) -> Int {
        calendar.component(.day, from: date)
    }

    func isToday(_ date: Date) -> Bool {
        calendar.isDateInToday(date)
    }

    func isSelected(_ date: Date) -> Bool {
        date == selectedDate
    }

    func hasEvents(_ date: Date) -> Bool {
        monthEventDays.contains(date)
    }
}

/// 卡片切换滑动进度驱动器：由面板的弹簧时钟逐帧推进（0 = 起手帧，1 = 落定）。
/// SwiftUI 侧只让两个卡片包装视图观察它做纯位移，不依赖首帧上屏时序，也不重算整张卡片。
final class CardSlideDriver: ObservableObject {
    @Published var progress: CGFloat = 1
}

/// 单张卡片的滑动位移容器：只观察进度驱动器（body 只做 offset，不重算卡片内容）
private struct SlideCard<Content: View>: View {
    @ObservedObject var driver: CardSlideDriver
    /// 进度 0…1 → 横向位移
    let offset: (CGFloat) -> CGFloat
    let content: Content

    init(driver: CardSlideDriver, offset: @escaping (CGFloat) -> CGFloat,
         @ViewBuilder content: () -> Content) {
        self._driver = ObservedObject(wrappedValue: driver)
        self.offset = offset
        self.content = content()
    }

    var body: some View {
        content.offset(x: offset(driver.progress))
    }
}

/// 灵动岛面板内容：顶部条（左上角两个切换箭头）+ 单个内容模块卡片
/// （日历 / 系统资源 / 正在播放，一次只显示一个）；无启用模块时显示「添加显示内容」引导。
/// 面板尺寸随内容自适应：卡片 = 模块自然尺寸（宽度取自然列宽，高度取内容自然高，
/// 超出屏幕上限时日程列表滚动/紧凑密度/等比缩小兜底）；内容按卡片内宽重排（宽度不做缩放）；
/// 卡片包圆角半透明背景。
struct NotchContentView: View {
    @ObservedObject var model: NotchCalendarViewModel
    /// 显示宽度：nil = 测量模式（卡片自然尺寸）；正式展示由 NotchPanel 传入面板尺寸
    var displayWidth: CGFloat? = nil
    /// 显示高度：正式展示时传入面板高
    var displayHeight: CGFloat? = nil
    /// 刘海高度：顶部占位条高度（内容保持在刘海以下；面板水平居中于刘海）
    var notchHeight: CGFloat = 0
    /// 正式渲染时显示的模块；nil = 空状态（无启用模块）
    var displayModule: Module? = nil
    /// 点击左右箭头切换模块回调（-1 = 上一张，+1 = 下一张）
    var onNavigateModule: ((Int) -> Void)? = nil
    /// 遮罩侧墙相对窗口边缘的内缩量（由 NotchPanel 按面板宽算），箭头按钮据此避开肩弧遮罩
    var sideWallInset: CGFloat = 0
    /// 测量单模块尺寸时指定要渲染的模块
    var modulesOverride: Module? = nil
    /// 测量时指定列宽；nil = 按自然宽/拉伸规则
    var columnWidthOverride: CGFloat? = nil
    /// 测量日历卡日程列表的最大高度；nil = 不限制（渲染时靠面板高度约束滚动）
    var dayListMaxHeight: CGFloat? = nil
    /// 测量日历卡固定部分高度时收起日程列表（只留选中日标题）
    var collapseDayEvents = false
    /// 卡片尺寸（含卡片内边距；由 NotchPanel 按内容自然尺寸决定），渲染时居中于槽位
    var cardSize: CGSize = CGSize(width: 100, height: 100)
    /// 卡片内容的布局高度（含卡片内边距）：= 内容自然高（封顶到卡片上限），
    /// 大于卡片高时说明连固定部分都装不下，靠 cardScale 缩小兜底
    var cardContentHeight: CGFloat = 100
    /// 卡片内容等比缩放系数（≤1，由 NotchPanel 按卡片高与内容高计算）
    var cardScale: CGFloat = 1
    /// 紧凑密度：卡片高装不下常规密度时整体切换（资源行单行化、字号/间距/网格收紧），
    /// 目标是自然高≈卡片内高、scale≈1；仍装不下再等比缩小兜底
    var compactMode: Bool = false
    /// 卡片切换滑动过渡（左右箭头 / 双指左右滑动）：旧卡按切换前几何滑出、新卡自另一侧滑入；
    /// nil = 无过渡（present / 日程加载 refit）
    var slide: CardSlide? = nil
    /// 滑动进度驱动器：面板弹簧逐帧写 progress，两个卡片包装视图只观察它做位移。
    /// 这里用普通属性（默认实例）而不是 @ObservedObject，避免整个内容视图按 120Hz 重算
    var slideDriver = CardSlideDriver()
    @ObservedObject private var resources = SystemResourceMonitor.shared
    @ObservedObject private var music = NowPlayingMonitor.shared

    private let accent = Color.accentColor
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    /// 面板内容内边距（测量与尺寸决策共用）；水平方向 = 卡片到面板「可见」边缘的留白
    /// （遮罩左右侧墙还会内缩，NotchPanel 算面板宽时会额外补上）
    static let outerHPadding: CGFloat = 16
    static let outerVPadding: CGFloat = 16
    /// 顶部条与内容卡槽的间距（渲染与尺寸决策共用）
    static let switcherGap: CGFloat = 8
    /// 切换箭头按钮：按钮边长 / 两按钮间距 / 两个按钮合计宽度（面板最小宽度据此取，见 NotchPanel）
    private static let arrowButtonSize: CGFloat = 24
    private static let arrowGap: CGFloat = 6
    static let arrowBlockWidth: CGFloat = arrowButtonSize * 2 + arrowGap
    /// 卡片水平内边距（测量与尺寸决策共用：卡片宽 = 内容列宽 + 2×该值）
    static let cardPadding: CGFloat = 10
    /// 卡片竖直内边距：比水平略紧，日历/资源/音乐共用
    static let cardVPadding: CGFloat = 6
    private static let cardRadius: CGFloat = 14
    /// 日历列自然宽度：卡片约 320 宽；固定部分高约 229–252（间距已收紧），卡片宽于高
    private static let calendarColumnWidth: CGFloat = 300
    /// 系统资源列自然宽度：两列主要项环（CPU/内存）之间的空白要放得下浮动的 GPU 小环，
    /// 读数行与通栏趋势线也需要横向空间（与日历卡片同宽 320，观感统一）
    private static let resourcesColumnWidth: CGFloat = 300
    /// 正在播放列自然宽度
    private static let musicColumnWidth: CGFloat = 224

    /// 模块自然列宽（卡片宽 = 列宽 + 左右内边距，即卡片宽度不会超过此自然尺寸）
    static func naturalColumnWidth(for module: Module) -> CGFloat {
        switch module {
        case .calendar: return calendarColumnWidth
        case .resources: return resourcesColumnWidth
        case .music: return musicColumnWidth
        }
    }

    /// 卡片内宽（卡片宽 − 左右内边距）：渲染列宽与内容测量共用同一口径
    static func columnWidth(forCardWidth cardWidth: CGFloat) -> CGFloat {
        max(1, cardWidth - cardPadding * 2)
    }

    /// 内容模块（固定顺序；一次只显示一个，可全部启用，靠顶部箭头 / 双指左右滑动切换）
    enum Module: CaseIterable {
        case calendar
        case resources
        case music
    }

    /// 卡片切换滑动参数：旧模块 + 切换前布局几何 + 方向 + 切换时冻结的行程/裁切宽度。
    /// step = -1（上一张）：旧卡向右滑出、新卡自左滑入；step = +1（下一张）：反向。
    /// 旧卡沿用当前密度（compactMode 只在极矮屏幕上才切换，不随切换抖动）
    struct CardSlide {
        let from: Module
        let step: Int
        let fromCard: CGSize
        let fromContentHeight: CGFloat
        let fromScale: CGFloat
        /// 滑动行程 = 两张卡较宽者 + 24（切换时冻结，refit 改布局也不跳）
        let travel: CGFloat
        /// 卡片区裁切宽度 = 两张卡较宽者（保证宽卡起手不被先削边）
        let viewportWidth: CGFloat
    }

    var body: some View {
        if displayWidth == nil {
            measureBody
        } else {
            renderBody
        }
    }

    /// 启用的模块（固定顺序，无数量上限）
    static var enabledModules: [Module] {
        var enabled: [Module] = []
        if SettingsStore.shared.notchShowCalendar { enabled.append(.calendar) }
        if SettingsStore.shared.notchShowResources { enabled.append(.resources) }
        if SettingsStore.shared.notchShowMusic { enabled.append(.music) }
        return enabled
    }

    /// 会话默认模块：日历优先，否则第一个启用模块（无启用模块 = nil → 空状态）
    static var defaultModule: Module? {
        enabledModules.contains(.calendar) ? .calendar : enabledModules.first
    }

    /// 测量单个模块卡片的尺寸（含卡片内边距，不含面板内边距与顶部条）。
    /// columnWidth 非 nil 时以该列宽测量；columnHeight 非 nil 时以该列高测量
    /// （资源卡按指定列高拉伸）；dayListMaxHeight / collapseDayEvents 用于日历卡的全高/固定高两档。
    static func measureCardSize(module: Module,
                                columnWidth: CGFloat?,
                                dayListMaxHeight: CGFloat? = nil,
                                collapseDayEvents: Bool = false,
                                compact: Bool = false,
                                model: NotchCalendarViewModel) -> CGSize {
        let view = NotchContentView(model: model,
                                    modulesOverride: module,
                                    columnWidthOverride: columnWidth,
                                    dayListMaxHeight: dayListMaxHeight,
                                    collapseDayEvents: collapseDayEvents,
                                    compactMode: compact)
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// 测量模式：单个模块卡的自然尺寸（不含面板内边距与顶部条）
    @ViewBuilder private var measureBody: some View {
        let module = modulesOverride ?? .calendar
        moduleView(module, inner: effectiveColumnWidth(Self.naturalColumnWidth(for: module)))
            .padding(.horizontal, Self.cardPadding)
            .padding(.vertical, Self.cardVPadding)
            .background(cardBackground)
    }

    /// 正式渲染：顶部条（刘海高度，左上角放切换箭头）+ 内容卡槽（刘海以下区域），
    /// 卡片左右留白与底部一致
    private var renderBody: some View {
        VStack(spacing: Self.switcherGap) {
            topBar
            contentSlot.frame(maxWidth: .infinity)
        }
        .padding(.bottom, Self.outerVPadding)
        .frame(width: displayWidth, height: displayHeight, alignment: .top)
    }

    /// 内容卡槽：卡片区（滑动过渡时旧卡与新卡同时在场，按 progress 反向外移；
    /// 裁切在卡片区边界——顶部条/箭头不动，滑出去的部分不落到面板留白上）
    private var contentSlot: some View {
        ZStack {
            if let slide {
                SlideCard(driver: slideDriver,
                          offset: { p in -CGFloat(slide.step) * slide.travel * p }) {
                    cardBody(slide.from,
                             inner: Self.columnWidth(forCardWidth: slide.fromCard.width),
                             card: slide.fromCard,
                             contentHeight: slide.fromContentHeight,
                             scale: slide.fromScale)
                }
            }
            if let module = displayModule {
                let step = CGFloat(slide?.step ?? 0)
                let travel = slide?.travel ?? 0
                SlideCard(driver: slideDriver,
                          offset: { p in step * travel * (1 - p) }) {
                    renderedCard(module)
                }
            } else {
                // 空状态：卡片固定尺寸（内容只有一行提示+按钮，缩成小条不好点）
                emptyState
                    .padding(.vertical, Self.cardVPadding)
                    .frame(width: max(1, cardSize.width), height: max(1, cardSize.height))
                    .background(cardBackground)
                    .frame(height: cardSlotHeight)
            }
        }
        .frame(width: slotViewportWidth, height: cardSlotHeight)
        .clipped()
    }

    /// 卡片区裁切宽度：过渡时取两张卡较宽者（宽卡起手不被削边），平时就是当前卡宽
    private var slotViewportWidth: CGFloat {
        slide?.viewportWidth ?? cardSize.width
    }

    /// 正式渲染时的列宽：卡片内宽（宽度方向不额外缩放，内容按此重排）
    private func effectiveColumnWidth(_ natural: CGFloat) -> CGFloat {
        if let override = columnWidthOverride { return max(1, override) }
        guard displayWidth != nil else { return natural }
        return Self.columnWidth(forCardWidth: cardSize.width)
    }

    @ViewBuilder private func moduleView(_ module: Module, inner: CGFloat) -> some View {
        switch module {
        case .calendar: calendarColumn(inner: inner)
        case .resources: resourcesColumn(inner: inner)
        case .music: musicColumn(inner: inner)
        }
    }

    /// 内容卡槽高度：面板高 − 刘海高 − 顶部条间距 − 底部内边距（与 computeLayout 同口径）
    private var cardSlotHeight: CGFloat {
        max(1, (displayHeight ?? 0) - notchHeight - Self.switcherGap - Self.outerVPadding)
    }

    /// 正式渲染：卡片宽度由内容决定，在槽位内水平+垂直居中；
    /// 内容列按卡片内宽布局、高度取 cardContentHeight，超出卡片时靠 cardScale 缩小兜底
    /// （scale 缩的是视觉尺寸，布局高度仍钉在内容高）
    private func renderedCard(_ module: Module) -> some View {
        cardBody(module, inner: effectiveColumnWidth(Self.naturalColumnWidth(for: module)),
                 card: cardSize, contentHeight: cardContentHeight, scale: cardScale)
    }

    /// 按给定几何渲染一张卡片（当前模块用布局几何，滑动过渡中的旧卡用切换前几何，不重排）
    private func cardBody(_ module: Module, inner: CGFloat, card: CGSize,
                          contentHeight: CGFloat, scale: CGFloat) -> some View {
        moduleView(module, inner: inner)
            .padding(.horizontal, Self.cardPadding)
            .padding(.vertical, Self.cardVPadding)
            .frame(height: max(1, contentHeight), alignment: .center)
            .scaleEffect(scale, anchor: .center)
            .frame(width: max(1, card.width), height: max(1, card.height), alignment: .center)
            .background(cardBackground)
            .frame(height: cardSlotHeight)
    }

    /// 顶部条：刘海高度的黑条（面板水平居中于刘海，中间被硬件刘海挡住），
    /// 左上角挨着卡片左边缘放「上一张 / 下一张」箭头，不占卡片左右的留白；
    /// 面板最小宽度由 NotchPanel 保证这两个箭头落在刘海左侧可见处
    private var topBar: some View {
        HStack(spacing: Self.arrowGap) {
            navigationArrow(step: -1)
            navigationArrow(step: 1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, sideWallInset + Self.outerHPadding)
        .frame(height: notchHeight, alignment: .center)
    }

    /// 切换箭头按钮（上一张 / 下一张）：顶部条内的小圆钮；
    /// 启用模块不足 2 个时置灰且不可点
    private func navigationArrow(step: Int) -> some View {
        let enabled = Self.enabledModules.count > 1 && onNavigateModule != nil
        return Button {
            onNavigateModule?(step)
        } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary.opacity(enabled ? 0.85 : 0.25))
                .frame(width: Self.arrowButtonSize, height: Self.arrowButtonSize)
                .background(Circle().fill(Color.primary.opacity(enabled ? 0.10 : 0.04)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(L10n.tr(step < 0 ? "上一个" : "下一个"))
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }

    private func calendarColumn(inner: CGFloat) -> some View {
        VStack(spacing: compactMode ? 4 : 5) {
            header
            weekdayRow
            monthGrid
            // 紧凑密度：只留月历网格（卡片高受限时日程区装不下，标题+列表整体隐藏）
            if !compactMode {
                Divider()
                daySection
            }
        }
        .frame(width: inner)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text(L10n.tr("暂无显示内容"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Button(L10n.tr("添加显示内容")) {
                SettingsView.pendingTab = .notch
                NotificationCenter.default.post(name: .zeroflowOpenNotchSettings, object: nil)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 16)
    }

    // MARK: - 系统资源模块

    /// 资源卡分块尺寸：上半块（主要项 CPU/内存 环形仪表，GPU 小环浮在两环之间的空白正中）
    /// 与下半块（磁盘/网络 上下两行：标题 + 读数一行，趋势线通栏拉满）；上下两块之间一条细分隔线。
    private static let resourceHalfHeight: CGFloat = 88
    private static let resourceCellGap: CGFloat = 8
    /// 顶部条与上半块、上半块与下半块之间的间距（细分隔线上下的留白同值）
    private static let resourceHalfDividerGap: CGFloat = 7
    private static let primaryRingSize: CGFloat = 56
    private static let primaryRingLineWidth: CGFloat = 5.5
    /// GPU 次要项：小环明显小于主项环（主次分明），浮在两主项之间的空白里，不占格子
    private static let gpuRingSize: CGFloat = 34
    private static let gpuRingLineWidth: CGFloat = 3
    private static let resourceRateRowGap: CGFloat = 8
    /// 趋势线通栏（标题与读数独占一行），比左右分栏时长一倍以上
    private static let resourceSparklineHeight: CGFloat = 24

    /// 主要项（环形仪表，占上半块）：固定顺序 CPU → 内存
    private var primaryResourceItems: [NotchResourceItem] {
        enabledResourceItems.filter { $0 == .cpu || $0 == .memory }
    }

    /// 速率项（占下半块）：固定顺序 磁盘 → 网络（上下两行，趋势线可拉长）
    private var rateResourceItems: [NotchResourceItem] {
        enabledResourceItems.filter { $0 == .disk || $0 == .network }
    }

    /// 系统资源卡：上半块 = CPU/内存 环形仪表各占一格（共半块），GPU 小环浮在两环之间的空白正中；
    /// 下半块 = 磁盘/网络 上下两行（标题+读数一行 + 通栏趋势线）。
    /// 紧凑密度（屏幕极矮兜底）= 每项单行。
    private func resourcesColumn(inner: CGFloat) -> some View {
        let primary = primaryResourceItems
        let rates = rateResourceItems
        let showGPU = enabledResourceItems.contains(.gpu)
        let hasUpper = !primary.isEmpty || (showGPU && !compactMode)
        return VStack(alignment: .leading, spacing: 0) {
            moduleHeader("cpu", L10n.tr("系统资源"))
                .padding(.bottom, compactMode ? 4 : Self.resourceHalfDividerGap)
            if compactMode {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(enabledResourceItems, id: \.self) { item in
                        compactResourceRow(item, width: inner)
                    }
                }
            } else {
                if hasUpper {
                    resourceUpperHalf(primary: primary, showGPU: showGPU, inner: inner)
                }
                if hasUpper && !rates.isEmpty {
                    Rectangle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(height: 0.5)
                        .padding(.vertical, Self.resourceHalfDividerGap)
                }
                if !rates.isEmpty {
                    VStack(alignment: .leading, spacing: Self.resourceRateRowGap) {
                        ForEach(rates, id: \.self) { rateResourceRow($0, width: inner) }
                    }
                    .frame(width: inner)
                }
            }
        }
        .frame(width: inner)
    }

    /// 上半块：CPU/内存 环各占一格；GPU 小环浮在两格之间的空白正中（不占格、不挤主项）。
    /// 只启用一个主项（或没有主项）时中间没有留白，GPU 退回成紧邻的第二个格子。
    private func resourceUpperHalf(primary: [NotchResourceItem], showGPU: Bool, inner: CGFloat) -> some View {
        let width = resourceCellWidth(count: max(1, primary.count), inner: inner)
        // 两格之间才有空白可浮（ZStack 居中），否则与主项并排
        let floats = showGPU && primary.count >= 2
        let inline = showGPU && !floats
        return ZStack {
            HStack(spacing: Self.resourceCellGap) {
                ForEach(primary, id: \.self) { item in
                    primaryResourceCell(item, width: width)
                }
                if inline { gpuBadge }
            }
            .frame(width: inner)
            if floats { gpuBadge }
        }
        .frame(width: inner)
    }

    /// GPU 次要项：小环（环心百分比）+ 名称，浮在上半块两环之间的空白正中
    private var gpuBadge: some View {
        VStack(spacing: 2) {
            ResourceRing(progress: normalizedProgress(.gpu),
                         text: percentText(.gpu),
                         size: Self.gpuRingSize,
                         lineWidth: Self.gpuRingLineWidth,
                         fontSize: 10,
                         tint: ringTint(.gpu))
            Text(NotchResourceItem.gpu.title)
                .font(.system(size: 9.5))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// 半块内的单元格均分：n 格按内宽等分，单个格子不铺满整行（与多格观感一致）
    private func resourceCellWidth(count: Int, inner: CGFloat) -> CGFloat {
        let n = max(1, count)
        guard n > 1 else { return min(inner, Self.primaryRingSize * 2.4) }
        return (inner - Self.resourceCellGap * CGFloat(n - 1)) / CGFloat(n)
    }

    /// 主要项单元格：环形仪表（环心 = 百分比）+ 名称 + 副信息（CPU 核心数 / 内存 已用-总量）
    private func primaryResourceCell(_ item: NotchResourceItem, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            ResourceRing(progress: normalizedProgress(item),
                         text: percentText(item),
                         size: Self.primaryRingSize,
                         lineWidth: Self.primaryRingLineWidth,
                         fontSize: 15,
                         tint: ringTint(item))
            Text(item.title)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Text(primaryDetail(item))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        // minHeight 而非固定高：内容永远不被迫溢出，两块等高至少各占半块
        .frame(width: width)
        .frame(minHeight: Self.resourceHalfHeight)
    }

    /// 速率项一行：标题 + 两向读数占一行，趋势线整条通栏（线长拉满内宽）
    private func rateResourceRow(_ item: NotchResourceItem, width: CGFloat) -> some View {
        let lines = rateLines(item)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize()
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    Text(lines.read)
                    Text(lines.write)
                }
                .font(.system(size: 9.5, weight: .medium))
                .monospacedDigit()
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            ResourceSparkline(normalizedValues: normalizedHistory(item))
                .frame(height: Self.resourceSparklineHeight)
        }
        .frame(width: width)
    }

    /// 紧凑密度兜底（屏幕极矮）：每项单行「图标 名称 … 数值」，无环、无趋势线
    private func compactResourceRow(_ item: NotchResourceItem, width: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: item.symbol)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(item.title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(compactValue(item))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: width)
    }

    /// 环形仪表色相：CPU 蓝 / 内存绿 / GPU 紫，三项一眼可分（HUD 固定深色，用系统色相即可）
    private func ringTint(_ item: NotchResourceItem) -> Color {
        switch item {
        case .cpu: return .blue
        case .memory: return .green
        case .gpu: return .purple
        case .disk, .network: return .accentColor
        }
    }

    /// 百分比项当前用量 0–1；nil = 暂不可用（只显示空轨道，环心同步显示「—」）
    private func normalizedProgress(_ item: NotchResourceItem) -> Double? {
        let s = resources.sample
        switch item {
        case .cpu: return s.cpuPercent.map { min(1, max(0, $0 / 100)) }
        case .gpu: return s.gpuPercent.map { min(1, max(0, $0 / 100)) }
        case .memory:
            guard let used = s.memUsedBytes, let total = s.memTotalBytes, total > 0 else { return nil }
            return min(1, max(0, Double(used) / Double(total)))
        case .disk, .network: return nil
        }
    }

    /// 迷你趋势图数据（仅速率项 磁盘/网络）：按窗口内峰值归一化（峰值下限 200KB/s 防除零全矮）
    private func normalizedHistory(_ item: NotchResourceItem) -> [Double] {
        let h = resources.history
        let raw: [Double]
        switch item {
        case .disk: raw = h.disk
        case .network: raw = h.network
        default: return []
        }
        let scale = max(raw.max() ?? 0, 200_000)
        return raw.map { min(1, max(0, $0 / scale)) }
    }

    private var enabledResourceItems: [NotchResourceItem] {
        SettingsStore.shared.notchResourceItems.compactMap { NotchResourceItem(rawValue: $0) }
    }

    /// 环形仪表环心文字：百分比项为用量百分比，速率项不进环
    private func percentText(_ item: NotchResourceItem) -> String {
        guard let progress = normalizedProgress(item) else { return "—" }
        return String(format: "%.0f%%", min(1, max(0, progress)) * 100)
    }

    /// 主要项副信息：CPU = 核心数；内存 = 已用 / 总量
    private func primaryDetail(_ item: NotchResourceItem) -> String {
        let s = resources.sample
        switch item {
        case .cpu:
            return "\(ProcessInfo.processInfo.processorCount) \(L10n.tr("核"))"
        case .memory:
            guard let used = s.memUsedBytes else { return "—" }
            guard let total = s.memTotalBytes else { return SystemResourceMonitor.formatBytes(used) }
            return "\(SystemResourceMonitor.formatBytes(used)) / \(SystemResourceMonitor.formatBytes(total))"
        case .gpu, .disk, .network:
            return ""
        }
    }

    /// 速率项两行数值：磁盘 = 读/写，网络 = 下行/上行；任一方向有值即显示，双向都缺失显示「—」
    private func rateLines(_ item: NotchResourceItem) -> (read: String, write: String) {
        let s = resources.sample
        switch item {
        case .disk:
            guard s.diskReadBps != nil || s.diskWriteBps != nil else {
                return ("\(L10n.tr("读")) —", "\(L10n.tr("写")) —")
            }
            return ("\(L10n.tr("读")) \(SystemResourceMonitor.formatBps(s.diskReadBps))",
                    "\(L10n.tr("写")) \(SystemResourceMonitor.formatBps(s.diskWriteBps))")
        case .network:
            guard s.netDownBps != nil || s.netUpBps != nil else { return ("↓ —", "↑ —") }
            return ("↓ \(SystemResourceMonitor.formatBps(s.netDownBps))",
                    "↑ \(SystemResourceMonitor.formatBps(s.netUpBps))")
        case .cpu, .memory, .gpu:
            return ("—", "—")
        }
    }

    /// 紧凑密度行数值：百分比项给百分比，速率项并成一行
    private func compactValue(_ item: NotchResourceItem) -> String {
        switch item {
        case .cpu, .memory, .gpu:
            return percentText(item)
        case .disk, .network:
            let lines = rateLines(item)
            return "\(lines.read) · \(lines.write)"
        }
    }

    // MARK: - 正在播放模块

    private func musicColumn(inner: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            moduleHeader("music.note", L10n.tr("正在播放"))
            if let info = music.nowPlaying {
                musicBody(info)
            } else {
                Text(L10n.tr("没有正在播放的音乐"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .frame(width: inner)
    }

    private func musicBody(_ info: NowPlayingInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                appIcon(info)
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.appName ?? L10n.tr("未知应用"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(info.isPlaying ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 5, height: 5)
                        Text(info.isPlaying ? L10n.tr("正在播放") : L10n.tr("已暂停"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Text(info.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)

            musicSubtitle(info)

            if let progress = musicProgress(info) {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.15))
                            Capsule().fill(Color.accentColor)
                                .frame(width: max(2, proxy.size.width * progress))
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(Self.timeText(info.elapsed ?? 0))
                        Spacer()
                        Text(Self.timeText(info.duration ?? 0))
                    }
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 18) {
                musicButton("backward.fill", L10n.tr("上一首"), disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.previous)
                }
                musicButton(info.isPlaying ? "pause.fill" : "play.fill",
                            info.isPlaying ? L10n.tr("暂停") : L10n.tr("播放"),
                            disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.togglePlay)
                }
                musicButton("forward.fill", L10n.tr("下一首"), disabled: !music.controlsAvailable) {
                    NowPlayingMonitor.shared.send(.next)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func musicSubtitle(_ info: NowPlayingInfo) -> some View {
        let parts = [info.artist, info.album].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func musicProgress(_ info: NowPlayingInfo) -> Double? {
        guard let duration = info.duration, duration > 0, let elapsed = info.elapsed else { return nil }
        return min(1, max(0, elapsed / duration))
    }

    private static func timeText(_ t: Double) -> String {
        let total = Int(max(0, t))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func appIcon(_ info: NowPlayingInfo) -> some View {
        Group {
            if let bid = info.appBundleID, let icon = Self.icon(forBundleID: bid) {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .frame(width: 22, height: 22)
    }

    private static let iconCache = NSCache<NSString, NSImage>()

    private static func icon(forBundleID bid: String) -> NSImage? {
        if let cached = iconCache.object(forKey: bid as NSString) { return cached }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bid }),
              let icon = app.icon else { return nil }
        iconCache.setObject(icon, forKey: bid as NSString)
        return icon
    }

    private func musicButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(disabled ? Color.secondary.opacity(0.4) : .primary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(label)
    }

    private func moduleHeader(_ icon: String, _ title: String) -> some View {
        HStack(spacing: compactMode ? 4 : 6) {
            Image(systemName: icon)
                .font(.system(size: compactMode ? 9 : 11, weight: .medium))
                .foregroundColor(.secondary)
            Text(title)
                .font(.system(size: compactMode ? 10 : 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var header: some View {
        HStack(spacing: compactMode ? 4 : 8) {
            Button(L10n.tr("今天")) {
                model.reset()
            }
            .buttonStyle(.plain)
            .font(.system(size: compactMode ? 10 : 11))
            .foregroundColor(.secondary)

            Spacer()
            Text(model.monthTitle)
                .font(.system(size: compactMode ? 12 : 14, weight: .semibold))
            Spacer()

            HStack(spacing: compactMode ? 2 : 4) {
                monthNavButton("chevron.left") { model.moveMonth(-1) }
                monthNavButton("chevron.right") { model.moveMonth(1) }
            }
        }
    }

    private func monthNavButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: compactMode ? 10 : 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: compactMode ? 14 : 16, height: compactMode ? 14 : 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(model.weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: compactMode ? 9 : 10))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: Self.columns, spacing: 2) {
            ForEach(Array(model.monthCells().enumerated()), id: \.offset) { _, cell in
                if let date = cell {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: compactMode ? 17 : 22)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let selected = model.isSelected(date)
        let today = model.isToday(date)
        return VStack(spacing: compactMode ? 1 : 2) {
            Text("\(model.dayNumber(date))")
                .font(.system(size: compactMode ? 10 : 12, weight: selected || today ? .semibold : .regular))
                .foregroundColor(selected ? .white : (today ? accent : .primary))
            Circle()
                .fill(selected ? Color.white.opacity(0.9) : accent)
                .frame(width: compactMode ? 2 : 3, height: compactMode ? 2 : 3)
                .opacity(model.hasEvents(date) ? 1 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compactMode ? 17 : 22)
        .background {
            if selected {
                Circle()
                    .fill(accent)
                    .frame(width: compactMode ? 15 : 20, height: compactMode ? 15 : 20)
            } else if today {
                Circle()
                    .strokeBorder(accent.opacity(0.7), lineWidth: 1)
                    .frame(width: compactMode ? 15 : 20, height: compactMode ? 15 : 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(date)
        }
    }

    /// 选中日详情：标题 + 授权提示/日程列表。列表高度弹性——面板装得下就完整展开，
    /// 装不下就压缩到剩余空间内滚动（文字不缩放）；collapseDayEvents 仅用于测量
    /// 日历固定部分高度（收起列表，只留标题）
    @ViewBuilder private var daySection: some View {
        VStack(alignment: .leading, spacing: compactMode ? 4 : 6) {
            Text(model.selectedTitle)
                .font(.system(size: compactMode ? 10 : 12, weight: .medium))
                .foregroundColor(.secondary)

            if !collapseDayEvents {
                if !model.isAuthorized && model.authStatus != .notDetermined {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("未获准访问日历，无法显示日程。"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Button(L10n.tr("前往设置")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.privacy?Privacy_Calendars") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                } else if model.dayEvents.isEmpty {
                    Text(L10n.tr("没有日程"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 6)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.dayEvents) { item in
                                HStack(alignment: .top, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 1.5)
                                        .fill(Color(nsColor: item.color))
                                        .frame(width: 3, height: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(2)
                                        Text(item.timeText)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    // 高度不设上限：测量时由 dayListMaxHeight 兜底，渲染时靠面板高度约束
                    // 压缩到剩余空间内滚动（文字保持原大）
                    .frame(maxHeight: dayListMaxHeight)
                }
            }
        }
    }
}

/// 资源项的环形仪表：灰色轨道 = 无用量参照，彩色弧（各资源项各自的色相）= 当前用量
/// （自 12 点顺时针），环心为数值文字（不可用时显示「—」）；用量变化做 0.4s 缓出插值
/// （2s 采样不至于跳变）
private struct ResourceRing: View {
    let progress: Double?
    let text: String
    let size: CGFloat
    let lineWidth: CGFloat
    let fontSize: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)
            if let progress, progress > 0.001 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(1, max(0, progress)))
                    .stroke(tint,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: progress)
            }
            Text(text)
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, lineWidth + 1)
        }
        .frame(width: size, height: size)
    }
}

/// 资源行的迷你趋势图：无坐标轴的单色渐变面积线（数据已归一化到 0–1）
private struct ResourceSparkline: View {
    let normalizedValues: [Double]

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            if normalizedValues.count >= 2, w > 0, h > 2 {
                let step = w / CGFloat(normalizedValues.count - 1)
                let points = normalizedValues.enumerated().map { pair -> CGPoint in
                    CGPoint(x: CGFloat(pair.offset) * step,
                            y: (1 - CGFloat(min(1, max(0, pair.element)))) * (h - 2) + 1)
                }
                ZStack {
                    areaPath(points: points, bottom: h)
                        .fill(LinearGradient(colors: [Color.accentColor.opacity(0.35),
                                                      Color.accentColor.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom))
                    linePath(points: points)
                        .stroke(Color.accentColor,
                                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        path.addLines(points)
        return path
    }

    private func areaPath(points: [CGPoint], bottom: CGFloat) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: bottom))
        path.addLines(points)
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.closeSubpath()
        return path
    }
}

/// 灵动岛面板：非激活 borderless 面板，纯黑底，形状 = 「刘海形」：
/// 顶边满宽且贴屏幕顶（盖住真刘海）、顶部两个角位补月牙黑并沿凹弧收细到内缩的竖直侧墙
/// （外侧背景在角上呈圆角：右上 ╭ / 左上呈 ╮，与真刘海肩部同形）、底部两角外凸圆角，
/// 半径随面板宽度相对刘海宽等比放大（始终像「放大版刘海」）。
/// 悬停/点击/Esc 判定全部由 NotchHotspotController 的 listen-only tap 完成，
/// 本面板只负责内容展示（不成为 key，无键盘交互）。
///
/// 尺寸 = 内容自适应：卡片取模块自然尺寸（日历列宽 300，卡片 ≈ 320 宽、自然高 ≈ 229–252），
/// 面板 = 卡片 + 可见外边距（四面 16，另补遮罩侧墙内缩 ≈15）
/// + 顶部刘海条（仅保留屏幕边界，日程多时卡片向下生长、到上限后列表滚动）。
/// 模块切换有两路：顶部条左上角的箭头按钮（面板最小宽度保证它们不被刘海挡住），
/// 以及面板范围内的双指左右滑动
/// （local monitor 收 scrollWheel，锁横轴累积超阈值切一张；循环切换，单模块时箭头置灰）。
/// 动画（NotchSpringAnimator 只驱动「形状状态」与窗口 frame，黑底全程不透明：形状渐变
/// 本身就是全部视觉效果，DEV-022）：
/// - 展开 = 单段弹簧（iOS 灵动岛式「液体铺开」）：宽高同时起跳、宽度领先、高度慢半拍——
///   面板先横向铺满、底缘跟着坠到底，收尾各带一次小幅过冲（宽 ≈3%、高 ≈1%）后回落；
///   全程没有中途换道、没有回缩、没有停顿，≈0.45s 落定；
/// - 位置以最终窗口的顶边中点（centerX/topY）为锚点，尺寸过冲时左右/上下对称外扩，
///   窗口整体不发生平移（DEV-027）；
/// - 内容视图（hosting）从全透明淡入，透明度由展开的几何进度驱动（宽度行程 60% 即完全
///   不透明，≈0.1s）；黑底形状始终不透明，所以起手就能看到内容随形状一起长出来；
/// - 收起 = 单段弹簧（临界阻尼）：三宽 + 高度同时收回迷你刘海，动画结束才 orderOut；
/// - 打断续接（DEV-023）：弹簧以当前值/速度重定向，在途 completion 作废。
/// 起点/收起终点的迷你刘海 = 比真刘海小一圈（顶边贴屏幕顶、左右/底各内缩），
/// 完全藏在刘海硬件后不可见。
final class NotchPanel: NSPanel {
    /// 圆角基准：刘海宽 180pt 时的目测半径（四角同半径），随面板宽度相对刘海宽等比放大
    static let referenceNotchWidth: CGFloat = 180
    static let cornerBase: CGFloat = 7
    /// 迷你刘海相对真刘海的内缩（左右/底部；顶边贴屏幕顶）
    static let startInset: CGFloat = 6
    /// 顶部条箭头与刘海硬件之间的最小间距（决定面板最小宽度）
    private static let arrowNotchClearance: CGFloat = 4
    private lazy var springAnimator = NotchSpringAnimator(panel: self)
    /// 当前内容的形状遮罩容器（makeContentView 更新；弹簧每帧给它换形状参数）
    private weak var shapeContainer: NotchShapeContainerView?
    /// 内容视图（展开时按几何进度淡入的对象）
    private weak var contentHosting: NSView?
    /// 弹簧正在趋向的目标 frame（present/dismiss 更新）。
    /// 控制器保活/点击判定用这个，而不是 present() 返回时刻的瞬时 frame：
    /// 展开动画从迷你刘海开始，那一刻的真实 frame 还是迷你大小（DEV-024 修复后
    /// 窗口尺寸真实可变，原来「present 后 frame 已是终值」的隐含前提不再成立）。
    private(set) var targetFrame: NSRect = .zero

    /// present 上下文（switchModule / refit 复用；面板尺寸随内容变化）
    private var lastScreen: NSScreen?
    private var lastNotchSize: CGSize = .zero
    private var lastNotchTL: CGRect = .zero
    private var lastModel: NotchCalendarViewModel?
    private var displayedModule: NotchContentView.Module?
    /// 卡片切换滑动过渡（方向 + 切换前几何）：过渡期间旧卡与新卡同时在内容视图里，
    /// 进度跑到 1 后旧卡停在卡片区外（被裁掉不可见），随后清掉
    private var currentSlide: NotchContentView.CardSlide?
    /// 卡片滑动进度驱动器（由弹簧时钟逐帧推进；SwiftUI 只观察它做位移）
    let slideDriver = CardSlideDriver()
    /// 卡片滑动是否在途（连点保护：一次滑动落定前忽略新的切换请求）
    var isSliding: Bool { springAnimator.isSliding }
    /// 顶部箭头 / 双指左右滑动切换回调（-1 = 上一张，+1 = 下一张）
    private var onNavigateModule: ((Int) -> Void)?
    private var lastLayout: PanelLayout?

    /// 双指左右滑动手势监视（local monitor）：只看本窗口范围内的 scrollWheel
    private var scrollMonitor: Any?
    /// 手势累积量（横向/纵向）与锁轴结果：一次手势只切一张，纵向滚动原样放行
    private var swipeAccumulatedX: CGFloat = 0
    private var swipeAccumulatedY: CGFloat = 0
    private var swipeIsHorizontal: Bool?
    private var swipeDidTrigger = false
    /// 锁轴所需的最小累积位移（pt）
    private static let swipeAxisLockThreshold: CGFloat = 12
    /// 触发切换所需的横向累积位移（pt）
    private static let swipeTriggerDistance: CGFloat = 50
    /// 无 phase 事件（滚轮/鼠标）间隔超过该值即视为新手势（s）
    private static let swipeIdleGap: TimeInterval = 0.25
    /// 上一个滚动事件的时间戳（判新手势用）
    private var swipeLastEventTimestamp: TimeInterval = 0

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.level = .screenSaver
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isReleasedWhenClosed = false
        self.animationBehavior = .none
        self.hidesOnDeactivate = false
        // 固定深色外观 + 白字（灵动岛风格，不随系统深浅模式变化）
        self.appearance = NSAppearance(named: .darkAqua)
        // 双指左右滑动切模块：local monitor 在事件分发前拿到 scrollWheel，
        // 不受卡片内 SwiftUI 滚动视图是否吃掉事件的影响（面板隐藏时直接放行）
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScrollWheel(event) ?? event
        }
    }

    deinit {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 面板布局决策结果（present / switchModule / refit 共用）
    private struct PanelLayout {
        let width: CGFloat
        let height: CGFloat
        /// 卡片尺寸（含卡片内边距）
        let card: CGSize
        /// 内容布局高（含卡片内边距，即渲染端 `.frame(height:)` 的值；超出卡片高时靠 scale 缩小）
        let contentHeight: CGFloat
        /// 内容等比缩小系数（≤1，仅当固定部分都装不下时 <1）
        let scale: CGFloat
        /// 是否采用紧凑密度（与渲染端 NotchContentView.compactMode 对齐）
        let compact: Bool
        /// 遮罩肩弧造成的左右侧墙内缩（渲染端据此避让左右箭头按钮）
        let sideInset: CGFloat
    }

    /// 尺寸决策：面板尺寸随内容自适应——卡片取模块自然尺寸（宽 = 模块自然列宽 + 内边距，
    /// 高 = 内容自然高），面板 = 卡片 + 可见外边距（含遮罩侧墙内缩）+ 顶部刘海条。
    /// 仅保留屏幕边界：卡片高超过「屏幕高 − 80 − 刘海顶部条」时压缩（日历日程列表滚动 /
    /// 资源切紧凑密度 / 仍装不下才整体等比缩小）。
    private static func computeLayout(screen: NSScreen, notchSize: CGSize,
                                      model: NotchCalendarViewModel,
                                      module: NotchContentView.Module?) -> PanelLayout {
        let maxCardH = max(1, screen.frame.height - 80
                              - notchSize.height
                              - NotchContentView.switcherGap
                              - NotchContentView.outerVPadding)
        // 面板宽还要给左右遮罩侧墙内缩（≈14）+ 可见外边距留余量
        let hMargin = NotchContentView.outerHPadding
        let maxCardW = max(1, screen.frame.width - 16 - hMargin * 2 - 32)

        // 空状态（无启用模块）：提示卡片固定尺寸（缩成小条不好点）
        guard let module else {
            let card = CGSize(width: min(300, maxCardW), height: min(150, maxCardH))
            return Self.makeLayout(card: card, contentHeight: card.height, scale: 1, compact: false,
                                   notchSize: notchSize, screen: screen)
        }

        let hPadding = NotchContentView.cardPadding
        let cardW = min(NotchContentView.naturalColumnWidth(for: module) + hPadding * 2, maxCardW)
        let columnW = max(1, cardW - hPadding * 2)

        func measure(compact: Bool, collapseDayEvents: Bool = false) -> CGFloat {
            NotchContentView.measureCardSize(module: module, columnWidth: columnW,
                                             dayListMaxHeight: module == .calendar && !collapseDayEvents ? 2000 : nil,
                                             collapseDayEvents: collapseDayEvents,
                                             compact: compact, model: model).height
        }

        /// 内容布局高（含卡片内边距，即渲染端 `.frame(height:)` 的值）；超出上限时缩放兜底
        let contentHeight: CGFloat
        let compact: Bool
        let scale: CGFloat
        switch module {
        case .calendar:
            let full = measure(compact: false)
            let fixed = measure(compact: false, collapseDayEvents: true)
            if fixed < maxCardH {
                // 固定部分装得下：日程全部展开；列表超出上限时在卡片内滚动
                contentHeight = min(full, maxCardH)
                compact = false
                scale = 1
            } else {
                // 连固定部分都超上限：先切紧凑密度，仍超才整体等比缩小
                let compactFixed = measure(compact: true, collapseDayEvents: true)
                contentHeight = compactFixed
                compact = true
                scale = min(1, maxCardH / max(1, compactFixed))
            }
        case .resources:
            let natural = measure(compact: false)
            if natural <= maxCardH {
                contentHeight = natural
                compact = false
                scale = 1
            } else {
                let compactNatural = measure(compact: true)
                contentHeight = compactNatural
                compact = true
                scale = min(1, maxCardH / max(1, compactNatural))
            }
        case .music:
            let natural = measure(compact: false)
            contentHeight = natural
            compact = false
            scale = min(1, maxCardH / max(1, natural))
        }
        let cardH = min(maxCardH, contentHeight)
        return Self.makeLayout(card: CGSize(width: cardW, height: cardH),
                               contentHeight: contentHeight, scale: scale, compact: compact,
                               notchSize: notchSize, screen: screen)
    }

    /// 面板尺寸 = 卡片 + 可见外边距（与底部同值）+ 顶部刘海条；宽高都钳制进屏幕，水平居中刘海。
    /// 遮罩的左右侧墙相对窗口边缘内缩（肩弧半径），可见黑边只剩内缩以外的部分，
    /// 所以面板宽要把内缩额外补上，否则卡片会紧贴可见边缘。
    /// 切换箭头放在顶部条左上角，不占用卡片左右的留白；面板宽还有下限（刘海 + 左侧箭头区），
    /// 保证窄卡片（正在播放）时两个箭头也不被刘海挡住。
    private static func makeLayout(card: CGSize, contentHeight: CGFloat, scale: CGFloat,
                                   compact: Bool, notchSize: CGSize, screen: NSScreen) -> PanelLayout {
        let height = Self.clamp(card.height + notchSize.height
                                    + NotchContentView.switcherGap + NotchContentView.outerVPadding,
                                notchSize.height + 8, screen.frame.height - 80)
        // 侧墙内缩随面板宽变化（半径 ∝ 宽），迭代两次即收敛；
        // 同时保证左侧够放两个箭头（+ 与刘海的最小间距），窄卡片面板据此加宽
        let hMargin = NotchContentView.outerHPadding
        let arrowReach = hMargin + NotchContentView.arrowBlockWidth + Self.arrowNotchClearance
        var width = card.width + hMargin * 2
        for _ in 0..<3 {
            let sideInset = NotchShapeContainerView.sideInset(width: width, height: height,
                                                              referenceWidth: notchSize.width)
            let natural = card.width + (hMargin + sideInset) * 2
            let arrowsMin = notchSize.width + (arrowReach + sideInset) * 2
            width = max(natural, arrowsMin)
        }
        width = Self.clamp(width, notchSize.width + 24, screen.frame.width - 16)
        let sideInset = NotchShapeContainerView.sideInset(width: width, height: height,
                                                          referenceWidth: notchSize.width)
        return PanelLayout(width: width, height: height, card: card,
                           contentHeight: contentHeight, scale: scale, compact: compact,
                           sideInset: sideInset)
    }

    /// 悬停延时到期 / 单击热区后展示：顶边贴屏幕顶、水平居中于刘海、尺寸由内容决定。
    /// 每次 present 重建 contentView（模型重置到今天，同时取最新内容设置）。
    /// 展开走单段液体弹簧（见类文档）；打断续接走 isVisible 分支单段重定向。
    func present(hotspotTL: CGRect, notchTL: CGRect, screen: NSScreen,
                 model: NotchCalendarViewModel, module: NotchContentView.Module?,
                 onNavigateModule: @escaping (Int) -> Void) {
        lastScreen = screen
        lastNotchSize = notchTL.size
        lastNotchTL = notchTL
        lastModel = model
        displayedModule = module
        currentSlide = nil
        slideDriver.progress = 1
        springAnimator.cancelSlide()
        self.onNavigateModule = onNavigateModule

        let layout = Self.computeLayout(screen: screen, notchSize: notchTL.size,
                                        model: model, module: module)
        lastLayout = layout
        contentView = makeContentView(model: model, layout: layout)
        // 注意：这里不 setContentSize —— 它是瞬时几何赋值，打断路径上会把窗口尺寸直接
        // 跳到终值（原点锚定、另一侧瞬移），产生整块平移感（DEV-023）；尺寸交给弹簧 setFrame

        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let finalFrame = Self.expandedFrame(notchTL: notchTL, screen: screen, layout: layout, unionMaxY: unionMaxY)
        targetFrame = finalFrame
        let finalState = NotchShapeState.full(frame: finalFrame)
        if isVisible {
            // 收起动画被打断（快速反复进出）/ 可见时改尺寸：从当前形状单段重定向到终形态
            invalidateShadow()
            springAnimator.animate(to: finalState, contentAlpha: 1)
        } else {
            let startState = Self.miniState(notchTL: notchTL, unionMaxY: unionMaxY)
            apply(startState, display: false)
            applyContentAlpha(0)
            alphaValue = 1
            orderFront(nil)
            invalidateShadow()
            springAnimator.animate(to: finalState, contentAlpha: 1)
        }
    }

    /// 收起：单段弹簧（宽度领先收拢、高度跟上，三宽 + 高同时缩回迷你刘海），
    /// 动画结束才 orderOut，全程不透明。控制器状态在 hidePanel 即时更新，期间再 present
    /// 会以单段重定向无缝续接展开（在途 completion 作废，orderOut 不会执行）。
    func dismiss(notchTL: CGRect) {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let notchState = Self.miniState(notchTL: notchTL, unionMaxY: unionMaxY)
        targetFrame = notchState.frame
        springAnimator.animate(to: notchState, tuning: NotchSpringAnimator.collapseTuning,
                               lead: 2) { [weak self] in
            self?.orderOut(nil)
        }
    }

    /// 终点 frame：顶边贴屏幕顶（盖住刘海）、水平居中于刘海、钳制进屏幕左右各 8pt
    private static func expandedFrame(notchTL: CGRect, screen: NSScreen, layout: PanelLayout,
                                      unionMaxY: CGFloat) -> NSRect {
        let x = Self.clamp(notchTL.midX - layout.width / 2,
                           screen.frame.minX + 8, screen.frame.maxX - layout.width - 8)
        return NSRect(x: x, y: unionMaxY - layout.height, width: layout.width, height: layout.height)
    }

    /// 迷你刘海形状：顶边贴屏幕顶、左右各收 startInset、底部收 startInset
    /// （比真刘海小一圈，完全藏在刘海硬件后不可见）
    private static func miniState(notchTL: CGRect, unionMaxY: CGFloat) -> NotchShapeState {
        let width = max(4, notchTL.width - startInset * 2)
        let height = max(4, notchTL.height - startInset)
        return NotchShapeState(centerX: notchTL.midX, topY: unionMaxY,
                               topWidth: width, neckWidth: width, bottomWidth: width, height: height)
    }

    /// 切换模块（左右箭头 / 双指左右滑动）：卡片按 step 方向滑动过渡（旧卡滑出 / 新卡滑入），
    /// 面板尺寸同时按新模块内容弹簧变形。step = -1 上一张（旧卡向右出、新卡自左入），+1 反向
    func switchModule(to module: NotchContentView.Module, step: Int) {
        guard let screen = lastScreen, let model = lastModel, displayedModule != module else { return }
        ZSLog("Notch switch: from=\(String(describing: displayedModule)) to=\(module) step=\(step)")
        let fromModule = displayedModule
        let fromLayout = lastLayout
        displayedModule = module
        let layout = Self.computeLayout(screen: screen, notchSize: lastNotchSize, model: model, module: module)
        lastLayout = layout
        if let fromModule, let fromLayout {
            // 行程/裁切宽度在切换时冻结：两卡较宽者 + 24 / 两卡较宽者
            let width = max(layout.card.width, fromLayout.card.width)
            currentSlide = NotchContentView.CardSlide(from: fromModule,
                                                      step: step < 0 ? -1 : 1,
                                                      fromCard: fromLayout.card,
                                                      fromContentHeight: fromLayout.contentHeight,
                                                      fromScale: fromLayout.scale,
                                                      travel: width + 24,
                                                      viewportWidth: width)
            slideDriver.progress = 0
        } else {
            currentSlide = nil
            slideDriver.progress = 1
        }
        contentView = makeContentView(model: model, layout: layout)
        applyLayoutFrame(layout, screen: screen)
        invalidateShadow()
        guard currentSlide != nil else { return }
        // 与面板形状弹簧同一个 120Hz 时钟：临界阻尼、零过冲
        springAnimator.animateSlide(from: 0, to: 1) { [weak self] in
            self?.finishSlide()
        }
    }

    /// 日程加载/切换后重测内容布局：尺寸变化时只换 hosting 的 rootView（保留在途滑动动画）并弹簧变形
    func refit(model: NotchCalendarViewModel) {
        guard let screen = lastScreen, let module = displayedModule else { return }
        let layout = Self.computeLayout(screen: screen, notchSize: lastNotchSize, model: model, module: module)
        defer { lastLayout = layout }
        if let last = lastLayout,
           abs(layout.scale - last.scale) <= 0.001, layout.compact == last.compact,
           abs(layout.width - last.width) <= 0.5, abs(layout.height - last.height) <= 0.5,
           abs(layout.card.height - last.card.height) <= 0.5,
           abs(layout.card.width - last.card.width) <= 0.5,
           abs(layout.contentHeight - last.contentHeight) <= 0.5 {
            return
        }
        updateContentView(model: model, layout: layout)
        applyLayoutFrame(layout, screen: screen)
        invalidateShadow()
    }

    /// 可见面板切换尺寸：只能走弹簧重定向（DEV-023 禁止在途 setFrame），并同步命中区域用的目标 frame
    private func applyLayoutFrame(_ layout: PanelLayout, screen: NSScreen) {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let frame = Self.expandedFrame(notchTL: lastNotchTL, screen: screen,
                                       layout: layout, unionMaxY: unionMaxY)
        targetFrame = frame
        let state = NotchShapeState.full(frame: frame)
        guard isVisible else {
            apply(state, display: false)
            applyContentAlpha(1)
            return
        }
        springAnimator.animate(to: state, contentAlpha: 1)
    }

    // MARK: - 形状应用（弹簧每帧调用）

    /// 应用一帧形状：窗口 frame = 形状包围盒，遮罩容器换顶栏/细颈/鼓包三条外包络宽
    fileprivate func apply(_ state: NotchShapeState, display: Bool) {
        setFrame(state.frame, display: display)
        shapeContainer?.applyProfile(topWidth: state.topWidth, neckWidth: state.neckWidth,
                                     bottomWidth: state.bottomWidth)
    }

    /// 内容视图当前透明度（弹簧段内过渡的起点）
    fileprivate var contentAlpha: CGFloat { contentHosting?.alphaValue ?? 1 }

    /// 内容视图透明度：只作用在 hosting 上，黑底形状始终不透明（DEV-022）
    fileprivate func applyContentAlpha(_ alpha: CGFloat) {
        contentHosting?.alphaValue = alpha
    }

    /// 滑动弹簧每帧回写进度（SwiftUI 两个卡片包装视图只观察这个值做位移）
    fileprivate func applySlideProgress(_ progress: CGFloat) {
        slideDriver.progress = progress
    }

    /// 滑动落定：进度钉到 1，清掉旧卡并只换 hosting 的 rootView（不重建 hosting）
    fileprivate func finishSlide() {
        slideDriver.progress = 1
        guard currentSlide != nil, let model = lastModel, let layout = lastLayout else { return }
        currentSlide = nil
        updateContentView(model: model, layout: layout)
    }

    /// 按面板当前状态（displayedModule / currentSlide / slideDriver）构造内容视图
    private func rootContentView(model: NotchCalendarViewModel, layout: PanelLayout) -> NotchContentView {
        NotchContentView(model: model,
                         displayWidth: layout.width,
                         displayHeight: layout.height,
                         notchHeight: lastNotchSize.height,
                         displayModule: displayedModule,
                         onNavigateModule: { [weak self] step in
                             self?.onNavigateModule?(step)
                         },
                         sideWallInset: layout.sideInset,
                         cardSize: layout.card,
                         cardContentHeight: layout.contentHeight,
                         cardScale: layout.scale,
                         compactMode: layout.compact,
                         slide: currentSlide,
                         slideDriver: slideDriver)
    }

    /// 只换 hosting 的 rootView：保留 SwiftUI 身份与在途滑动动画（refit / 滑动进度推进用）
    private func updateContentView(model: NotchCalendarViewModel, layout: PanelLayout) {
        guard let hosting = contentHosting as? NSHostingView<NotchContentView> else {
            contentView = makeContentView(model: model, layout: layout)
            return
        }
        hosting.rootView = rootContentView(model: model, layout: layout)
    }

    /// 背景（纯黑或液态玻璃）直接铺在遮罩容器底（遮罩裁出刘海形），内容以 autoresizing 跟随。
    ///
    /// 结构红线（DEV-024）：hosting 必须以 addSubview + autoresizingMask 跟随容器，
    /// 绝不能赋给玻璃 contentView、绝不能对 hosting 用 Auto Layout 约束——
    /// SwiftUI 固定 .frame 尺寸会经约束链反向钳制窗口尺寸，setFrame 的宽高
    /// 被静默锁死（只有原点生效），「从刘海生长」就退化成全尺寸面板平移。
    private func makeContentView(model: NotchCalendarViewModel, layout: PanelLayout) -> NSView {
        let hosting = NSHostingView(rootView: rootContentView(model: model, layout: layout))
        let container = NotchShapeContainerView(referenceNotchWidth: lastNotchSize.width,
                                                barHeight: max(0, lastNotchSize.height - Self.startInset),
                                                initialSize: CGSize(width: layout.width, height: layout.height),
                                                glassBackground: SettingsStore.shared.notchGlassBackground)
        container.addSubview(hosting)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // 弹簧每帧据这两个引用换形状参数 / 淡入内容（旧容器随 contentView 释放）
        shapeContainer = container
        contentHosting = hosting
        return container
    }

    private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }

    // MARK: - 双指左右滑动

    /// 手势累积逻辑：只认非惯性的触控板事件；`.began` 清累积并按位移锁轴（横向明显占优才算），
    /// 横向累积超阈值切一张并锁死到手势结束（一次滑动不连翻）；纵向滚动/惯性全部原样放行。
    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isVisible, onNavigateModule != nil else { return event }
        guard event.window === self || frame.contains(NSEvent.mouseLocation) else { return event }

        // 手势结束先清状态：手指抬起时 `.ended` 常与 momentumPhase 同时出现，
        // 不能先被惯性过滤挡掉，否则累积量会带进下一次手势（反向滑动会被残值拖反）
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            swipeAccumulatedX = 0
            swipeAccumulatedY = 0
            swipeIsHorizontal = nil
            swipeDidTrigger = false
            return event
        }
        // 惯性阶段（手指抬起后的余滑）不参与，避免一次顺滑拖出多张
        guard event.momentumPhase == [] else { return event }

        // 手势起点：触控板带 phase（.began/.mayBegin）；传统滚轮/鼠标没有 phase，用事件间隔判定
        // 新手势必须清累积：否则上一手势的残值会把这次反向滑动的符号拖反
        let newGesture: Bool
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
            newGesture = true
        } else if event.phase == [] {
            newGesture = event.timestamp - swipeLastEventTimestamp > Self.swipeIdleGap
        } else {
            newGesture = false
        }
        swipeLastEventTimestamp = event.timestamp
        if newGesture {
            swipeAccumulatedX = 0
            swipeAccumulatedY = 0
            swipeIsHorizontal = nil
            swipeDidTrigger = false
        }
        guard !swipeDidTrigger else { return event }

        // 方向归一：系统会按「自然滚动」设置翻转 scrollingDeltaX，
        // 用 isDirectionInvertedFromDevice 翻到同一基准后再判方向。
        // 本机实测（自然滚动开）：双指左滑累积为正、右滑为负。
        let fingerSign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * fingerSign
        let dy = event.scrollingDeltaY * fingerSign
        // 方向反转：先丢掉旧累积，避免上一段/上一手势的残值在反方向先触发一次
        if swipeAccumulatedX != 0, dx != 0, (swipeAccumulatedX > 0) != (dx > 0) {
            swipeAccumulatedX = 0
            swipeAccumulatedY = 0
            swipeIsHorizontal = nil
        }
        swipeAccumulatedX += dx
        swipeAccumulatedY += dy
        if swipeIsHorizontal == nil {
            let absX = abs(swipeAccumulatedX)
            let absY = abs(swipeAccumulatedY)
            guard max(absX, absY) >= Self.swipeAxisLockThreshold else { return event }
            swipeIsHorizontal = absX > absY
        }
        guard swipeIsHorizontal == true, abs(swipeAccumulatedX) >= Self.swipeTriggerDistance else {
            return event
        }
        swipeDidTrigger = true
        // 双指左滑（归一后 > 0）= 上一张（与顶部左箭头同向）；右滑 = 下一张
        let step = swipeAccumulatedX > 0 ? -1 : 1
        ZSLog("Notch swipe: raw dx=\(event.scrollingDeltaX) inverted=\(event.isDirectionInvertedFromDevice) acc=\(swipeAccumulatedX) step=\(step)")
        onNavigateModule?(step)
        return event
    }
}

/// 灵动岛形状几何（窗口坐标）：窗口 = 形状包围盒（宽 = 三条宽度里的最大值），
/// 形状在窗口内水平居中；centerX/topY 是窗口顶边中点的锚点（DEV-027，位置永不做 origin 弹簧）。
/// 三条宽度都是「外包络宽」：顶栏（刘海条）/ 细颈（水滴股）/ 底部鼓包，
/// 外包络内的侧墙再由肩弧半径内缩（见遮罩路径）。终形态三者相等 = 等比放大的刘海形；
/// 当前的展开/收起动画让三者始终相等（形状全程是等比刘海形），非相等的细颈/鼓包是形状能力。
private struct NotchShapeState {
    var centerX: CGFloat
    var topY: CGFloat
    var topWidth: CGFloat
    var neckWidth: CGFloat
    var bottomWidth: CGFloat
    var height: CGFloat

    /// 窗口宽 = 形状最大横向跨度（鼓包在细颈阶段不会超出顶栏，取最大值只是兜底）
    var windowWidth: CGFloat { max(topWidth, max(neckWidth, bottomWidth)) }

    var frame: NSRect {
        NSRect(x: centerX - windowWidth / 2, y: topY - height, width: windowWidth, height: height)
    }

    /// 弹簧分量顺序：centerX, topY, topWidth, neckWidth, bottomWidth, height
    func component(_ index: Int) -> CGFloat {
        switch index {
        case 0: return centerX
        case 1: return topY
        case 2: return topWidth
        case 3: return neckWidth
        case 4: return bottomWidth
        default: return height
        }
    }

    /// 终形态（三宽相等 = 刘海形）
    static func full(frame: NSRect) -> NotchShapeState {
        NotchShapeState(centerX: frame.midX, topY: frame.maxY,
                        topWidth: frame.width, neckWidth: frame.width,
                        bottomWidth: frame.width, height: frame.height)
    }
}

/// 刘海形遮罩容器：顶部两角凹形肩弧（矩形角位补月牙黑，外侧背景呈圆角）、底部两角外凸圆角，
/// 半径随容器宽度相对刘海宽
/// 等比放大（弹簧每帧 setFrame 触发 layout 重建路径，动画全程保持「当前大小的刘海」）。
/// 形状不止是窗口 frame：`applyProfile` 额外给定顶栏/细颈/鼓包三条外包络宽，
/// 路径据此长出「细颈 + 底部鼓包」（水滴/沙漏），窗口 frame 只是包围盒。
/// 本视图提供纯黑底色或液态玻璃背景并做形状裁剪，hosting 由外部铺满。
private final class NotchShapeContainerView: NSView {
    private let referenceWidth: CGFloat
    /// 顶栏（刘海条）高度：顶栏以下才会出现细颈/鼓包
    private let barHeight: CGFloat
    private let maskLayer: CAShapeLayer
    /// 液态玻璃背景（旧系统回退磨砂）；关闭时保持纯黑底
    private let glassBackground: Bool
    private let backdrop: NSView?
    /// 当前形状外包络宽（插件每帧经 applyProfile 更新；nil = 退化为整宽刘海形）
    private var profile: (top: CGFloat, neck: CGFloat, bottom: CGFloat)?

    /// initialSize：创建时用已知面板终尺寸立即生成遮罩路径，
    /// 避免首次 orderFront 在 layout() 之前露出一帧方形内容
    init(referenceNotchWidth: CGFloat, barHeight: CGFloat, initialSize: CGSize,
         glassBackground: Bool) {
        self.referenceWidth = max(1, referenceNotchWidth)
        self.barHeight = max(0, barHeight)
        self.glassBackground = glassBackground
        self.backdrop = glassBackground ? PanelGlassBackground.make(cornerRadius: 0) : nil
        self.maskLayer = CAShapeLayer()
        // 弹簧 120Hz 改 path/frame 时禁用隐式动画，避免遮罩滞后于窗口几何
        maskLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        super.init(frame: NSRect(origin: .zero, size: initialSize))
        wantsLayer = true
        layer?.backgroundColor = glassBackground ? NSColor.clear.cgColor : NSColor.black.cgColor
        if let backdrop {
            backdrop.frame = bounds
            backdrop.autoresizingMask = [.width, .height]
            addSubview(backdrop)
        }
        layer?.mask = maskLayer
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // AppKit 重建 backing layer 时重申底色/遮罩（常态下 init 已设好）
        layer?.backgroundColor = glassBackground ? NSColor.clear.cgColor : NSColor.black.cgColor
        layer?.mask = maskLayer
    }

    // 弹簧每帧 setFrame 改变 bounds 时 AppKit 触发 layout()，重建遮罩跟随当前尺寸
    override func layout() {
        super.layout()
        updateMask()
    }

    /// 更新形状外包络宽（弹簧每帧调用；高度始终取当前 bounds，跟随窗口 frame）
    func applyProfile(topWidth: CGFloat, neckWidth: CGFloat, bottomWidth: CGFloat) {
        profile = (topWidth, neckWidth, bottomWidth)
        updateMask()
    }

    /// 遮罩圆角：底角外凸圆角 + 顶部肩弧同源，半径随面板宽相对刘海宽等比放大
    private static func radii(width: CGFloat, height: CGFloat,
                              referenceWidth: CGFloat) -> (corner: CGFloat, shoulder: CGFloat) {
        let scale = width / max(1, referenceWidth)
        let corner = min(NotchPanel.cornerBase * scale, height / 2)
        // 肩弧不能吃掉整个高度/宽度
        return (corner, min(corner, height / 3, width / 6))
    }

    /// 左右可见边缘相对窗口边缘的内缩量（= 顶部肩弧半径）：
    /// 面板尺寸决策据此补足可见外边距，否则卡片会贴在遮罩侧墙上看不见留白
    static func sideInset(width: CGFloat, height: CGFloat, referenceWidth: CGFloat) -> CGFloat {
        radii(width: width, height: height, referenceWidth: referenceWidth).shoulder
    }

    private func updateMask() {
        maskLayer.frame = bounds
        maskLayer.path = Self.notchShapePath(size: bounds.size, barHeight: barHeight,
                                             topWidth: profile?.top ?? bounds.width,
                                             neckWidth: profile?.neck ?? bounds.width,
                                             bottomWidth: profile?.bottom ?? bounds.width,
                                             referenceWidth: referenceWidth)
    }

    /// 刘海形路径（层坐标 y 向上，形状在窗口内水平居中）：
    /// - 顶边 = 顶栏外包络宽、与屏幕顶边齐平（盖住真刘海，和屏幕顶边连成一条线）；
    /// - 顶部两角 = 矩形角位上的月牙形黑色填充（凹形肩弧，弧心在角点正下方）：
    ///   黑色在上面铺满整个角位，再沿凹弧收细到内缩 `s` 的竖直侧墙，
    ///   使面板外侧背景在角上呈圆角（右上 ╭ / 左上 ╮），和真刘海肩部（屏幕顶边
    ///   绕开刘海侧壁的倒角）同形；
    /// - 顶栏下缘 = 凹圆角收细到细颈（水位拉丝），细颈竖直向下；
    /// - 细颈 → 底部鼓包 = 两端切向竖直的三次贝塞尔（三宽相等时自动退化为直线）；
    /// - 底部两角 = 外凸圆角，越靠近细股越圆（细颈阶段近乎半圆的水滴尖）。
    private static func notchShapePath(size: CGSize, barHeight: CGFloat,
                                       topWidth: CGFloat, neckWidth: CGFloat,
                                       bottomWidth: CGFloat,
                                       referenceWidth: CGFloat) -> CGPath {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let cx = width / 2

        // 三条外包络宽（细颈/鼓包不会超过顶栏）
        let topW = min(max(topWidth, 4), width)
        let neckW = min(max(neckWidth, 4), topW)
        let botW = min(max(bottomWidth, 4), topW)

        // 顶部肩弧半径（随顶栏宽相对刘海宽等比放大，且不吃掉整个高度/宽度）
        let shoulder = min(NotchPanel.cornerBase * topW / max(1, referenceWidth),
                           height / 3, topW / 6)
        // 外包络宽 → 侧墙相对中心的距离（外包络内再内缩一个肩弧半径，窄形状按宽度收窄）
        func wall(_ envelope: CGFloat) -> CGFloat {
            envelope / 2 - max(0, min(shoulder, envelope / 2 - 1))
        }
        let topWall = wall(topW)
        let neckWall = wall(neckW)
        let botWall = wall(botW)

        // 底部圆角：窄成细股时趋近半圆（水滴尖），扩到接近终宽时回到常规圆角
        let fullyRound = botWall
        let cornerAtFinal = min(NotchPanel.cornerBase * botW / max(1, referenceWidth), fullyRound)
        let narrowness = 1 - min(1, botW / max(1, topW))
        let bottomRadius = cornerAtFinal + (fullyRound - cornerAtFinal) * narrowness

        // 顶栏下缘 → 身体；身体最低处不低于底角圆心（迷你刘海/段1-2 高度 = 顶栏高时身体为空）
        let barH = min(max(0, barHeight), height)
        let bodyTop = max(0, height - barH)
        let bodyLimit = max(bodyTop, bottomRadius)
        let fillet = min(12, max(0, (bodyLimit - bottomRadius) * 0.5), barH * 0.7)
        // 鼓包只占下半段：细颈竖直延伸到该高度才开始向外扩（沙漏的腰）
        let flareStart = bottomRadius + max(0, bodyLimit - fillet - bottomRadius) * 0.38
        let flareSpan = max(0, flareStart - bottomRadius)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - topW / 2, y: height))            // 顶边左端（屏幕顶边）
        // 顶左肩弧：(cx-topW/2, h) → 内缩 shoulder 的侧墙，弧心 (cx-topW/2, h-shoulder)
        path.addArc(center: CGPoint(x: cx - topW / 2, y: height - shoulder), radius: shoulder,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: cx - topWall, y: bodyLimit))        // 顶栏左墙
        // 顶栏下缘的凹圆角 → 细颈（左）
        path.addCurve(to: CGPoint(x: cx - neckWall, y: bodyLimit - fillet),
                      control1: CGPoint(x: cx - topWall, y: bodyLimit - fillet * 0.55),
                      control2: CGPoint(x: cx - neckWall, y: bodyLimit - fillet * 0.45))
        path.addLine(to: CGPoint(x: cx - neckWall, y: flareStart))      // 细颈左墙
        // 细颈 → 底部鼓包（左）
        path.addCurve(to: CGPoint(x: cx - botWall, y: bottomRadius),
                      control1: CGPoint(x: cx - neckWall, y: flareStart - flareSpan * 0.42),
                      control2: CGPoint(x: cx - botWall, y: bottomRadius + flareSpan * 0.42))
        path.addArc(center: CGPoint(x: cx - botWall + bottomRadius, y: bottomRadius),
                    radius: bottomRadius,
                    startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)  // 底左角
        path.addLine(to: CGPoint(x: cx + botWall - bottomRadius, y: 0))            // 底边
        path.addArc(center: CGPoint(x: cx + botWall - bottomRadius, y: bottomRadius),
                    radius: bottomRadius,
                    startAngle: .pi * 3 / 2, endAngle: .pi * 2, clockwise: false) // 底右角
        // 底部鼓包 → 细颈（右）
        path.addCurve(to: CGPoint(x: cx + neckWall, y: flareStart),
                      control1: CGPoint(x: cx + botWall, y: bottomRadius + flareSpan * 0.42),
                      control2: CGPoint(x: cx + neckWall, y: flareStart - flareSpan * 0.42))
        path.addLine(to: CGPoint(x: cx + neckWall, y: bodyLimit - fillet))          // 细颈右墙
        // 细颈 → 顶栏下缘（右）
        path.addCurve(to: CGPoint(x: cx + topWall, y: bodyLimit),
                      control1: CGPoint(x: cx + neckWall, y: bodyLimit - fillet * 0.45),
                      control2: CGPoint(x: cx + topWall, y: bodyLimit - fillet * 0.55))
        path.addLine(to: CGPoint(x: cx + topWall, y: height - shoulder))            // 顶栏右墙
        // 顶右肩弧：内缩侧墙 → 顶边右端，弧心 (cx+topW/2, h-shoulder)
        path.addArc(center: CGPoint(x: cx + topW / 2, y: height - shoulder), radius: shoulder,
                    startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()                                            // 顶边 → 左端
        return path
    }
}

/// iOS 风格弹簧动画驱动器（驱动形状状态 + 窗口 frame，透明度恒定、不参与动画）。
/// 六分量 = 锚点 centerX / 锚点 topY / 顶栏宽 / 细颈宽 / 底部鼓包宽 / 高：每帧由锚点与尺寸反推
/// 窗口 origin（x = centerX - 宽/2、y = topY - 高），尺寸过冲时围绕最终顶边中点
/// 对称放大/收回，位置不整体平移（DEV-027）；窗口宽 = 三条宽度里的最大值（形状包围盒）。
/// macOS 对窗口 frame 没有公开的弹簧动画 API（NSAnimationContext 仅支持贝塞尔曲线，
/// animator() 可动画属性的限制见 PITFALLS_DEV.md DEV-016），这里在主线程用定时器对弹簧
/// 微分方程做半隐式欧拉积分后直接 setFrame。response + dampingFraction 语义同 UIKit，
/// dampingFraction < 1 带过冲回弹。
/// 多段编排：`animate(legs:)` 顺序播放若干段，每段有自己的目标形状、六分量调参、
/// 引导分量与交接进度；引导分量位移进度达阈值时以当前值/速度无缝续接到下一段
/// （无停顿、无中间回弹）。当前的展开/收起都是单段（`animate(to:)`）：六分量共用同一套
/// response/dampingFraction，靠「宽度领先、高度滞后」拉开层次，尺寸过冲直接由阻尼比 < 1
/// 给出（一次回弹，没有中途换道）。
/// 「刘海生长/缩回」全程必须不透明：任何 alpha 淡入淡出都会让早期生长不可见、
/// 被感知成「从一侧滑入」（DEV-022），形状渐变本身就是全部视觉效果；
/// 唯一例外是内容视图（hosting）在自己的段里淡入——黑底形状始终不透明。
/// 动画进行中再次 animate：各分量以当前值/速度为起点重定向（展开↔收起互相打断无缝续接），
/// 旧动画未执行的交接与 completion 作废。
private final class NotchSpringAnimator {
    /// 分量弹簧调参（response + 阻尼比），顺序对齐 springs：centerX, topY, 顶栏宽, 细颈宽,
    /// 鼓包宽, 高。过冲量见下方各 tuning 的实测注释（宽 ≈ +3%、高 ≈ +1%）。
    struct SpringTuning {
        let response: TimeInterval
        let dampingFraction: CGFloat
    }
    /// 展开/重定向到终形态：宽高同时起跳、宽度领先、高度慢半拍（底缘跟着坠下来），
    /// 锚点临界阻尼零回弹（DEV-027），尺寸分量轻微欠阻尼、各自只过冲一次就回落。
    /// 实测（120Hz 半隐式欧拉模拟，迷你刘海 168×26 → 终形态 353×250）：
    /// 宽 response 0.32 / ζ0.70 → 峰值 +3.0%、0.37s 落定；
    /// 高 response 0.36 / ζ0.78 → 峰值 +0.9%、0.45s 落定。
    /// 三宽恒同参 → 形状全程是等比放大的刘海形（不会长出细颈/鼓包）。
    static let expandTuning: [SpringTuning] = [
        .init(response: 0.32, dampingFraction: 1.0),    // centerX：锚点零回弹
        .init(response: 0.32, dampingFraction: 1.0),    // topY：锚点零回弹
        .init(response: 0.32, dampingFraction: 0.70),   // 顶栏宽：先铺开，峰值 +3%
        .init(response: 0.32, dampingFraction: 0.70),   // 细颈宽（恒等于顶栏宽）
        .init(response: 0.32, dampingFraction: 0.70),   // 鼓包宽（恒等于顶栏宽）
        .init(response: 0.36, dampingFraction: 0.78),   // 高：慢半拍跟上，峰值 +1%
    ]
    /// 收起/重定向到更小尺寸：全部临界阻尼（收拢不该回弹；迷你刘海藏在硬件后，过冲也看不见），
    /// 宽度更快折回、高度跟上，≈0.4s 收干净
    static let collapseTuning: [SpringTuning] = [
        .init(response: 0.30, dampingFraction: 1.0),    // centerX：锚点零回弹
        .init(response: 0.30, dampingFraction: 1.0),    // topY：锚点零回弹
        .init(response: 0.30, dampingFraction: 1.0),    // 顶栏宽
        .init(response: 0.30, dampingFraction: 1.0),    // 细颈宽
        .init(response: 0.30, dampingFraction: 1.0),    // 鼓包宽
        .init(response: 0.34, dampingFraction: 1.0),    // 高
    ]

    /// 一段编排：目标是形状状态；lead = 引导分量下标（0 centerX / 1 topY / 2 顶栏宽 /
    /// 3 细颈宽 / 4 鼓包宽 / 5 高），该分量位移进度达 handoffProgress 即无缝续接下一段
    /// （1 = 最后一段，靠落定结束）；contentAlpha 非空时本段把内容视图透明度过渡到该值。
    struct Leg {
        let target: NotchShapeState
        let tuning: [SpringTuning]
        let lead: Int
        let handoffProgress: CGFloat
        var contentAlpha: CGFloat?

        init(target: NotchShapeState, tuning: [SpringTuning], lead: Int,
             handoffProgress: CGFloat, contentAlpha: CGFloat? = nil) {
            self.target = target
            self.tuning = tuning
            self.lead = lead
            self.handoffProgress = handoffProgress
            self.contentAlpha = contentAlpha
        }
    }

    /// settle 阈值：收紧到 0.25pt / 2pt·s⁻¹，避免尾部带速急停的微顿
    private static let valueEpsilon: CGFloat = 0.25
    private static let velocityEpsilon: CGFloat = 2
    /// 内容淡入在引导分量位移进度到该比例时完成（宽度 response 0.32 下 ≈ 0.1s）
    private static let contentFadeProgress: CGFloat = 0.6
    /// 动画帧跟踪（`ZEROFLOW_NOTCH_TRACE=1`）：每 50ms 打一行形状分量到日志，
    /// 用来数值检查有没有停顿/反向/顿挫，不靠肉眼
    private static let traceEnabled = ProcessInfo.processInfo.environment["ZEROFLOW_NOTCH_TRACE"] == "1"
    private var traceStart: CFTimeInterval = 0
    private var traceLast: CFTimeInterval = 0
    private var traceFrames = 0

    private struct Spring {
        var value: CGFloat
        var velocity: CGFloat
        let target: CGFloat
        let stiffness: CGFloat
        let damping: CGFloat
        let valueEpsilon: CGFloat
        let velocityEpsilon: CGFloat

        init(value: CGFloat, velocity: CGFloat, target: CGFloat, response: TimeInterval,
             dampingFraction: CGFloat, valueEpsilon: CGFloat, velocityEpsilon: CGFloat) {
            self.value = value
            self.velocity = velocity
            self.target = target
            // k = (2π/response)²，c = 2ζ√k（response/dampingFraction 同 UIKit 语义）
            let k = pow(2 * CGFloat.pi / max(0.01, CGFloat(response)), 2)
            self.stiffness = k
            self.damping = 2 * dampingFraction * sqrt(k)
            self.valueEpsilon = valueEpsilon
            self.velocityEpsilon = velocityEpsilon
        }

        /// 半隐式欧拉一步（dt 远小于稳定域 2/ω，帧率抖动不发散）
        func stepped(dt: CGFloat) -> Spring {
            var s = self
            let force = -stiffness * (s.value - target) - damping * s.velocity
            s.velocity += force * dt
            s.value += s.velocity * dt
            return s
        }

        var settled: Bool {
            abs(value - target) < valueEpsilon && abs(velocity) < velocityEpsilon
        }
    }

    /// 分量顺序：centerX, topY, topWidth, neckWidth, bottomWidth, height（位置 = 锚点，origin 每帧反推）
    private var springs: [Spring]?
    private var completion: (() -> Void)?
    /// 卡片滑动进度弹簧（与形状共用同一个 120Hz 时钟：response 0.32 / ζ1.0，临界阻尼零过冲）
    private var slideSpring: Spring?
    private var slideCompletion: (() -> Void)?
    /// 卡片滑动是否在途（连点保护用）
    var isSliding: Bool { slideSpring != nil }
    private var timer: Timer?
    private weak var panel: NotchPanel?

    /// 后续待播的段
    private var legs: [Leg] = []
    /// 正在播放的段（含引导分量与交接阈值）
    private var currentLeg: Leg?
    /// 当前段引导分量的起点值（算位移进度用）
    private var legStartValue: CGFloat = 0
    /// 当前段开始时内容视图的透明度（本段指定 contentAlpha 时按进度过渡）
    private var legStartAlpha: CGFloat = 1

    init(panel: NotchPanel) {
        self.panel = panel
    }

    deinit {
        timer?.invalidate()
    }

    /// 启动多段编排（只驱动形状与窗口 frame）。必须主线程调用（setFrame）。
    /// 打断：以各分量当前值/速度重定向到第一段的目标，旧 completion 作废。
    func animate(legs newLegs: [Leg], completion: (() -> Void)? = nil) {
        guard panel != nil, let first = newLegs.first else { return }
        self.completion = nil // 被打断动画的收尾作废
        legs = Array(newLegs.dropFirst())
        traceStart = 0
        traceFrames = 0
        startLeg(first)
        self.completion = completion
        startTimerIfNeeded()
    }

    /// 单段重定向（终形态收尾/收起/尺寸变化）
    func animate(to target: NotchShapeState, tuning: [SpringTuning] = NotchSpringAnimator.expandTuning,
                 lead: Int = 2, contentAlpha: CGFloat? = nil,
                 completion: (() -> Void)? = nil) {
        animate(legs: [Leg(target: target, tuning: tuning, lead: lead,
                           handoffProgress: 1, contentAlpha: contentAlpha)], completion: completion)
    }

    /// 启动卡片滑动进度弹簧（与形状弹簧同一个时钟、同一帧起跳；临界阻尼零过冲）
    func animateSlide(from: CGFloat, to: CGFloat, completion: (() -> Void)? = nil) {
        slideSpring = Spring(value: from, velocity: 0, target: to,
                             response: 0.32, dampingFraction: 1.0,
                             valueEpsilon: 0.002, velocityEpsilon: 0.02)
        slideCompletion = completion
        startTimerIfNeeded()
    }

    /// 取消在途滑动（present 重建内容时用；completion 作废，不回写进度）
    func cancelSlide() {
        slideSpring = nil
        slideCompletion = nil
    }

    /// 开始一段：以当前值/速度重建六分量弹簧（首段=打断续接，后续段=无缝交接）
    private func startLeg(_ leg: Leg) {
        currentLeg = leg
        rebuildSprings(target: leg.target, tuning: leg.tuning)
        legStartValue = springs?[min(max(leg.lead, 0), 5)].value ?? 0
        legStartAlpha = panel?.contentAlpha ?? 1
        if leg.contentAlpha != nil {
            panel?.applyContentAlpha(legStartAlpha)
        }
    }

    /// 以当前值/速度重建六分量弹簧（打断续接与段间交接共用；不动 completion）
    private func rebuildSprings(target: NotchShapeState, tuning: [SpringTuning]) {
        guard let panel else { return }
        let frame = panel.frame
        let previous = springs?.count == 6 ? springs : nil

        func make(_ index: Int, _ initial: CGFloat, _ target: CGFloat) -> Spring {
            let tune = tuning[min(max(index, 0), tuning.count - 1)]
            if let previous {
                // 打断续接：沿用该分量当前的值与速度
                return Spring(value: previous[index].value, velocity: previous[index].velocity,
                              target: target, response: tune.response,
                              dampingFraction: tune.dampingFraction,
                              valueEpsilon: Self.valueEpsilon, velocityEpsilon: Self.velocityEpsilon)
            }
            return Spring(value: initial, velocity: 0, target: target, response: tune.response,
                          dampingFraction: tune.dampingFraction,
                          valueEpsilon: Self.valueEpsilon, velocityEpsilon: Self.velocityEpsilon)
        }

        springs = [
            make(0, frame.midX, target.centerX),
            make(1, frame.maxY, target.topY),
            make(2, frame.width, target.topWidth),
            make(3, frame.width, target.neckWidth),
            make(4, frame.width, target.bottomWidth),
            make(5, frame.height, target.height),
        ]
        startTimerIfNeeded()
    }

    /// 引导分量本段的位移进度（0…1；目标差值可忽略时视为已到位）
    private func progress(of leg: Leg, in springs: [Spring]) -> CGFloat {
        let index = min(max(leg.lead, 0), 5)
        let travel = leg.target.component(index) - legStartValue
        guard abs(travel) > 0.5 else { return 1 }
        return (springs[index].value - legStartValue) / travel
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        var t: Timer?
        t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { t?.invalidate(); return }
            self.tick()
        }
        // .common：面板内按钮按下等事件跟踪期间动画不冻结
        RunLoop.main.add(t!, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let panel else {
            stopTimer()
            return
        }
        let dt: CGFloat = 1 / 120
        var allSettled = true

        if var springs {
            for i in springs.indices {
                if !springs[i].settled {
                    springs[i] = springs[i].stepped(dt: dt)
                }
                if springs[i].settled {
                    springs[i].value = springs[i].target
                    springs[i].velocity = 0
                } else {
                    allSettled = false
                }
            }
            self.springs = springs
            panel.apply(NotchShapeState(centerX: springs[0].value, topY: springs[1].value,
                                        topWidth: springs[2].value, neckWidth: springs[3].value,
                                        bottomWidth: springs[4].value, height: springs[5].value),
                        display: true)
            if Self.traceEnabled { trace(springs) }
        }

        // 卡片滑动进度：与形状同一帧推进（形状先落定时计时器也不能停，见 allSettled）
        if var slide = slideSpring {
            if !slide.settled {
                slide = slide.stepped(dt: dt)
            }
            if slide.settled {
                slideSpring = nil
                panel.applySlideProgress(slide.target)
                let completion = slideCompletion
                slideCompletion = nil
                completion?()
            } else {
                slideSpring = slide
                panel.applySlideProgress(slide.value)
                allSettled = false
            }
        }

        if let leg = currentLeg, let springs {
            let legProgress = progress(of: leg, in: springs)
            // 内容视图透明度：引导分量走完 contentFadeProgress 行程即完全不透明（≈0.1s）——
            // 展开起手就能看到内容随形状长出来；黑底形状始终不透明（DEV-022）
            if let alphaTarget = leg.contentAlpha {
                let p = min(1, max(0, legProgress / Self.contentFadeProgress))
                panel.applyContentAlpha(legStartAlpha + (alphaTarget - legStartAlpha) * p)
            }
            // 段间交接：引导分量进度达阈值 → 立即以当前值/速度续接下一段（无停顿无回弹）
            if leg.handoffProgress < 1, !legs.isEmpty, legProgress >= leg.handoffProgress {
                startLeg(legs.removeFirst())
                return // 交接当帧弹簧已重建，不参与落定判定
            }
        }

        if allSettled {
            stopTimer()
            let completion = self.completion
            self.completion = nil
            completion?()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        springs = nil
        slideSpring = nil
        slideCompletion = nil
        legs = []
        currentLeg = nil
    }

    /// 逐帧打形状分量与帧间隔（`ZEROFLOW_NOTCH_TRACE=1`）：用来数值核对节奏、
    /// 过冲幅度和有没有主线程卡顿（dt 尖峰），不靠肉眼
    private func trace(_ springs: [Spring]) {
        let now = CFAbsoluteTimeGetCurrent()
        if traceStart == 0 {
            traceStart = now
            traceFrames = 0
            traceLast = now
            ZSLog(String(format: "notch trace start target topW=%.1f neckW=%.1f botW=%.1f h=%.1f",
                         springs[2].target, springs[3].target, springs[4].target, springs[5].target))
        }
        traceFrames += 1
        let ms = (now - traceStart) * 1000
        let dt = (now - traceLast) * 1000
        traceLast = now
        ZSLog(String(format: "notch trace f=%d t=%.0fms dt=%.1f topW=%.1f h=%.1f a=%.2f",
                     traceFrames, ms, dt, springs[2].value, springs[5].value,
                     panel?.contentAlpha ?? -1))
    }
}
