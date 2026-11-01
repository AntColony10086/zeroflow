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

/// 灵动岛面板内容：顶部条（刘海两侧的模块切换药丸）+ 单个内容模块卡片
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
    /// 刘海尺寸：顶部条高度与中空占位宽（面板水平居中于刘海，占位即与之对齐）
    var notchWidth: CGFloat = 0
    var notchHeight: CGFloat = 0
    /// 正式渲染时显示的模块；nil = 空状态（无启用模块）
    var displayModule: Module? = nil
    /// 点击顶部切换药丸回调
    var onSelectModule: ((Module) -> Void)? = nil
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

    @ObservedObject private var resources = SystemResourceMonitor.shared
    @ObservedObject private var music = NowPlayingMonitor.shared

    private let accent = Color.accentColor
    private static let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    /// 面板内容内边距（测量与尺寸决策共用）；水平方向 = 卡片到面板「可见」边缘的留白
    /// （遮罩左右侧墙还会内缩，NotchPanel 算面板宽时会额外补上）
    static let outerHPadding: CGFloat = 16
    static let outerVPadding: CGFloat = 16
    /// 水平可见外边距：不小于刘海高度（留白至少一个刘海高）
    static func outerHMargin(notchHeight: CGFloat) -> CGFloat {
        max(outerHPadding, notchHeight)
    }
    /// 顶部条与内容卡槽的间距（渲染与尺寸决策共用）
    static let switcherGap: CGFloat = 8
    /// 顶部条样式：药丸与刘海边缘的间距 / 药丸间距 / 药丸高
    private static let switcherInset: CGFloat = 8
    private static let pillGap: CGFloat = 6
    private static let pillHeight: CGFloat = 18
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

    /// 内容模块（固定顺序；一次只显示一个，可全部启用，靠顶部药丸切换）
    enum Module: CaseIterable {
        case calendar
        case resources
        case music
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

    static func title(for module: Module) -> String {
        switch module {
        case .calendar: return L10n.tr("日历")
        case .resources: return L10n.tr("系统资源")
        case .music: return L10n.tr("正在播放")
        }
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
        moduleView(module)
            .padding(.horizontal, Self.cardPadding)
            .padding(.vertical, Self.cardVPadding)
            .background(cardBackground)
    }

    /// 正式渲染：顶部条 + 内容卡槽（刘海以下区域），底部留可见外边距
    private var renderBody: some View {
        VStack(spacing: Self.switcherGap) {
            moduleSwitcher
            contentSlot
        }
        .padding(.horizontal, outerInset)
        .padding(.bottom, Self.outerVPadding)
        .frame(width: displayWidth, height: displayHeight, alignment: .top)
    }

    /// 渲染时的左右内边距 = (面板宽 − 卡片宽) / 2（已含遮罩侧墙内缩，保证卡片与可见边缘留白）；
    /// 屏幕宽度钳制时退回基础外边距
    private var outerInset: CGFloat {
        let base = Self.outerHMargin(notchHeight: notchHeight)
        guard let displayWidth else { return base }
        return max(base, (displayWidth - cardSize.width) / 2)
    }

    @ViewBuilder private var contentSlot: some View {
        if let module = displayModule {
            renderedCard(module)
        } else {
            // 空状态：卡片固定尺寸（内容只有一行提示+按钮，缩成小条不好点）
            emptyState
                .padding(.vertical, Self.cardVPadding)
                .frame(width: max(1, cardSize.width), height: max(1, cardSize.height))
                .background(cardBackground)
                .frame(height: cardSlotHeight)
        }
    }

    /// 正式渲染时的列宽：卡片内宽（宽度方向不额外缩放，内容按此重排）
    private func effectiveColumnWidth(_ natural: CGFloat) -> CGFloat {
        if let override = columnWidthOverride { return max(1, override) }
        guard displayWidth != nil else { return natural }
        return Self.columnWidth(forCardWidth: cardSize.width)
    }

    @ViewBuilder private func moduleView(_ module: Module) -> some View {
        switch module {
        case .calendar: calendarColumn
        case .resources: resourcesColumn
        case .music: musicColumn
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
        moduleView(module)
            .padding(.horizontal, Self.cardPadding)
            .padding(.vertical, Self.cardVPadding)
            .frame(height: max(1, cardContentHeight), alignment: .center)
            .scaleEffect(cardScale, anchor: .center)
            .frame(width: max(1, cardSize.width), height: max(1, cardSize.height), alignment: .center)
            .background(cardBackground)
            .frame(height: cardSlotHeight)
    }

    /// 顶部条：刘海两侧的模块切换药丸（≥2 个启用模块才显示）。面板水平居中于刘海，
    /// 左右两组各占一半宽、分别贴向中心并留出半刘海宽的空档；中空区域被硬件刘海遮挡。
    /// 单模块时顶部条仅占位（内容区保持在刘海以下）
    @ViewBuilder private var moduleSwitcher: some View {
        let modules = Self.enabledModules
        if modules.count > 1 {
            let mid = (modules.count + 1) / 2
            HStack(spacing: 0) {
                HStack(spacing: Self.pillGap) {
                    ForEach(modules[..<mid], id: \.self) { modulePill($0) }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, notchWidth / 2 + Self.switcherInset)
                HStack(spacing: Self.pillGap) {
                    ForEach(modules[mid...], id: \.self) { modulePill($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, notchWidth / 2 + Self.switcherInset)
            }
            .frame(height: max(notchHeight, Self.pillHeight), alignment: .center)
        } else {
            Color.clear.frame(height: notchHeight)
        }
    }

    private func modulePill(_ module: Module) -> some View {
        let selected = module == displayModule
        return Button {
            onSelectModule?(module)
        } label: {
            Text(Self.title(for: module))
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundColor(selected ? .white : .primary.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(minWidth: 36, minHeight: Self.pillHeight)
                .background(Capsule().fill(selected
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(Color.primary.opacity(0.10))))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(onSelectModule == nil)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
            .fill(Color.primary.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
    }

    private var calendarColumn: some View {
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
        .frame(width: effectiveColumnWidth(Self.calendarColumnWidth))
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
    private var resourcesColumn: some View {
        let inner = effectiveColumnWidth(Self.resourcesColumnWidth)
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

    private var musicColumn: some View {
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
        .frame(width: effectiveColumnWidth(Self.musicColumnWidth))
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
/// 面板 = 卡片 + 可见外边距（水平 ≥ 刘海高、竖直 16，左右额外补遮罩侧墙内缩 ≈14）+ 顶部刘海条
/// （仅保留屏幕边界，日程多时卡片向下生长、到上限后列表滚动）。
/// 动画（NotchSpringAnimator 只驱动 frame，全程不透明：形状渐变本身就是全部视觉效果，
/// 无透明度渐变，DEV-022）：
/// - 展开两段连续：段1 横向拉到 80% 终宽（临界阻尼无回弹，高度停在迷你刘海高）→
///   引导分量进度达 handoffProgress 时以当前值/速度无缝续接段2 纵向+剩余横向
///   （无停顿，视觉上是一段连续运动，仅终点一次过冲：宽/高均达 ~105% 再回弹到 100%）；
/// - 位置以最终窗口的顶边中点（centerX/topY）为锚点，尺寸过冲时左右/上下对称外扩，
///   窗口整体不发生平移（DEV-027）；
/// - 收起镜像两段：段1 高度收到刘海高（临界阻尼）→ 无缝续接段2 横向收拢回迷你刘海
///   → 动画结束才 orderOut；
/// - 打断续接（DEV-023）：弹簧以当前值/速度重定向，在途 handoff/completion 作废。
/// 起点/收起终点的迷你刘海 = 比真刘海小一圈（顶边贴屏幕顶、左右/底各内缩），
/// 完全藏在刘海硬件后不可见。
final class NotchPanel: NSPanel {
    /// 圆角基准：刘海宽 180pt 时的目测半径（四角同半径），随面板宽度相对刘海宽等比放大
    static let referenceNotchWidth: CGFloat = 180
    static let cornerBase: CGFloat = 7
    /// 迷你刘海相对真刘海的内缩（左右/底部；顶边贴屏幕顶）
    static let startInset: CGFloat = 6
    /// 段1 横向目标宽度比例（终宽的 80%），到位前以 handoff 无缝续接剩余横向+纵向
    static let stageOneWidthFraction: CGFloat = 0.8
    /// 段1 引导分量（展开=宽度/收起=高度）位移进度达到该比例即交接下一段
    static let handoffProgress: CGFloat = 0.85
    private lazy var springAnimator = NotchSpringAnimator(panel: self)
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
    private var onSelectModule: ((NotchContentView.Module) -> Void)?
    private var lastLayout: PanelLayout?

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
        let hMargin = NotchContentView.outerHMargin(notchHeight: notchSize.height)
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

    /// 面板尺寸 = 卡片 + 可见外边距 + 顶部刘海条；宽高都钳制进屏幕，水平居中刘海。
    /// 遮罩的左右侧墙相对窗口边缘内缩（肩弧半径），可见黑边只剩内缩以外的部分，
    /// 所以面板宽要把内缩额外补上，否则卡片会紧贴可见边缘。
    private static func makeLayout(card: CGSize, contentHeight: CGFloat, scale: CGFloat,
                                   compact: Bool, notchSize: CGSize, screen: NSScreen) -> PanelLayout {
        let height = Self.clamp(card.height + notchSize.height
                                    + NotchContentView.switcherGap + NotchContentView.outerVPadding,
                                notchSize.height + 8, screen.frame.height - 80)
        // 侧墙内缩随面板宽变化（半径 ∝ 宽），迭代两次即收敛
        let hMargin = NotchContentView.outerHMargin(notchHeight: notchSize.height)
        var width = card.width + hMargin * 2
        for _ in 0..<2 {
            let sideInset = NotchShapeContainerView.sideInset(width: width, height: height,
                                                              referenceWidth: notchSize.width)
            width = card.width + (hMargin + sideInset) * 2
        }
        width = Self.clamp(width, notchSize.width + 24, screen.frame.width - 16)
        return PanelLayout(width: width, height: height, card: card,
                           contentHeight: contentHeight, scale: scale, compact: compact)
    }

    /// 悬停延时到期 / 单击热区后展示：顶边贴屏幕顶、水平居中于刘海、尺寸由内容决定。
    /// 每次 present 重建 contentView（模型重置到今天，同时取最新内容设置）。
    /// 两段连续展开见类文档；打断续接走 isVisible 分支单段重定向。
    func present(hotspotTL: CGRect, notchTL: CGRect, screen: NSScreen,
                 model: NotchCalendarViewModel, module: NotchContentView.Module?,
                 onSelectModule: @escaping (NotchContentView.Module) -> Void) {
        lastScreen = screen
        lastNotchSize = notchTL.size
        lastNotchTL = notchTL
        lastModel = model
        displayedModule = module
        self.onSelectModule = onSelectModule

        let layout = Self.computeLayout(screen: screen, notchSize: notchTL.size,
                                        model: model, module: module)
        lastLayout = layout
        contentView = makeContentView(model: model, layout: layout)
        // 注意：这里不 setContentSize —— 它是瞬时几何赋值，打断路径上会把窗口尺寸直接
        // 跳到终值（原点锚定、另一侧瞬移），产生整块平移感（DEV-023）；尺寸交给弹簧 setFrame

        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let finalFrame = Self.expandedFrame(notchTL: notchTL, screen: screen, layout: layout, unionMaxY: unionMaxY)
        targetFrame = finalFrame
        if isVisible {
            // 收起动画被打断（快速反复进出）：从当前 frame/速度单段重定向到终点
            invalidateShadow()
            springAnimator.animate(to: finalFrame)
        } else {
            let startFrame = Self.miniNotchFrame(notchTL: notchTL, unionMaxY: unionMaxY)
            setFrame(startFrame, display: false)
            alphaValue = 1
            orderFront(nil)
            invalidateShadow()
            // 两段连续（中途不停顿、无中间回弹，全程不透明 DEV-022）：段1 横向拉到
            // 80% 终宽（临界阻尼，高度停在迷你刘海高）→ 宽度进度达 handoffProgress
            // 时以当前值/速度无缝续接段2 纵向+剩余横向（仅终点一次过冲）。
            // 面板较窄（80% 终宽 ≤ 迷你刘海宽）时无横向段，直接单段展开
            let stageOneWidth = finalFrame.width * Self.stageOneWidthFraction
            if stageOneWidth > startFrame.width + 1 {
                let stageOne = NSRect(x: notchTL.midX - stageOneWidth / 2,
                                      y: unionMaxY - startFrame.height,
                                      width: stageOneWidth, height: startFrame.height)
                springAnimator.animate(to: stageOne,
                                       handoff: .init(targetFrame: finalFrame,
                                                      progress: Self.handoffProgress))
            } else {
                springAnimator.animate(to: finalFrame)
            }
        }
    }

    /// 收起（镜像展开的两段连续弹簧）：段1 高度收到刘海高（临界阻尼无回弹、宽度不动）→
    /// 进度达 handoffProgress 时无缝续接段2 横向收拢回迷你刘海，动画结束才 orderOut。
    /// 全程不透明。控制器状态在 hidePanel 即时更新，期间再 present 会以单段重定向
    /// 无缝续接展开（在途 handoff/completion 作废，orderOut 不会执行）。
    func dismiss(notchTL: CGRect) {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let notchFrame = Self.miniNotchFrame(notchTL: notchTL, unionMaxY: unionMaxY)
        targetFrame = notchFrame
        let stageOne = NSRect(x: frame.midX - frame.width / 2, y: unionMaxY - notchFrame.height,
                              width: frame.width, height: notchFrame.height)
        springAnimator.animate(to: stageOne, collapse: true,
                               handoff: .init(targetFrame: notchFrame,
                                              progress: Self.handoffProgress)) { [weak self] in
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

    /// 迷你刘海：顶边贴屏幕顶、左右各收 startInset、底部收 startInset
    /// （比真刘海小一圈，完全藏在刘海硬件后不可见）
    private static func miniNotchFrame(notchTL: CGRect, unionMaxY: CGFloat) -> NSRect {
        NSRect(x: notchTL.midX - (notchTL.width - startInset * 2) / 2,
               y: unionMaxY - notchTL.height + startInset,
               width: notchTL.width - startInset * 2,
               height: notchTL.height - startInset)
    }

    /// 顶部药丸切换模块：面板尺寸按新模块内容弹簧变形，并重建 contentView
    func switchModule(to module: NotchContentView.Module) {
        guard let screen = lastScreen, let model = lastModel, displayedModule != module else { return }
        displayedModule = module
        let layout = Self.computeLayout(screen: screen, notchSize: lastNotchSize, model: model, module: module)
        lastLayout = layout
        contentView = makeContentView(model: model, layout: layout)
        applyLayoutFrame(layout, screen: screen)
        invalidateShadow()
    }

    /// 日程加载/切换后重测内容布局：尺寸变化时重建 contentView 并弹簧变形
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
        contentView = makeContentView(model: model, layout: layout)
        applyLayoutFrame(layout, screen: screen)
        invalidateShadow()
    }

    /// 可见面板切换尺寸：只能走弹簧重定向（DEV-023 禁止在途 setFrame），并同步命中区域用的目标 frame
    private func applyLayoutFrame(_ layout: PanelLayout, screen: NSScreen) {
        let unionMaxY = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }.maxY
        let frame = Self.expandedFrame(notchTL: lastNotchTL, screen: screen,
                                       layout: layout, unionMaxY: unionMaxY)
        targetFrame = frame
        guard isVisible else {
            setFrame(frame, display: false)
            return
        }
        springAnimator.animate(to: frame)
    }

    /// 纯黑背景直接铺在遮罩容器底（遮罩裁出刘海形），内容以 autoresizing 跟随。
    ///
    /// 结构红线（DEV-024）：hosting 必须以 addSubview + autoresizingMask 跟随容器，
    /// 绝不能赋给玻璃 contentView、绝不能对 hosting 用 Auto Layout 约束——
    /// SwiftUI 固定 .frame 尺寸会经约束链反向钳制窗口尺寸，setFrame 的宽高
    /// 被静默锁死（只有原点生效），「从刘海生长」就退化成全尺寸面板平移。
    private func makeContentView(model: NotchCalendarViewModel, layout: PanelLayout) -> NSView {
        let hosting = NSHostingView(rootView: NotchContentView(model: model,
                                                               displayWidth: layout.width,
                                                               displayHeight: layout.height,
                                                               notchWidth: lastNotchSize.width,
                                                               notchHeight: lastNotchSize.height,
                                                               displayModule: displayedModule,
                                                               onSelectModule: { [weak self] module in
                                                                   self?.onSelectModule?(module)
                                                               },
                                                               cardSize: layout.card,
                                                               cardContentHeight: layout.contentHeight,
                                                               cardScale: layout.scale,
                                                               compactMode: layout.compact))
        let container = NotchShapeContainerView(referenceNotchWidth: lastNotchSize.width,
                                                initialSize: CGSize(width: layout.width, height: layout.height))
        container.addSubview(hosting)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        return container
    }

    private static func clamp(_ value: CGFloat, _ minValue: CGFloat, _ maxValue: CGFloat) -> CGFloat {
        guard maxValue >= minValue else { return minValue }
        return min(max(value, minValue), maxValue)
    }
}

/// 刘海形遮罩容器：顶部两角凹形肩弧（矩形角位补月牙黑，外侧背景呈圆角）、底部两角外凸圆角，
/// 半径随容器宽度相对刘海宽
/// 等比放大（弹簧每帧 setFrame 触发 layout 重建路径，动画全程保持「当前大小的刘海」）。
/// 本视图提供纯黑底色并做形状裁剪，hosting 由外部铺满。
private final class NotchShapeContainerView: NSView {
    private let referenceWidth: CGFloat
    private let maskLayer: CAShapeLayer

    /// initialSize：创建时用已知面板终尺寸立即生成遮罩路径，
    /// 避免首次 orderFront 在 layout() 之前露出一帧方形内容
    init(referenceNotchWidth: CGFloat, initialSize: CGSize) {
        self.referenceWidth = max(1, referenceNotchWidth)
        self.maskLayer = CAShapeLayer()
        // 弹簧 120Hz 改 path/frame 时禁用隐式动画，避免遮罩滞后于窗口几何
        maskLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        super.init(frame: NSRect(origin: .zero, size: initialSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = maskLayer
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // AppKit 重建 backing layer 时重申底色/遮罩（常态下 init 已设好）
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.mask = maskLayer
    }

    // 弹簧每帧 setFrame 改变 bounds 时 AppKit 触发 layout()，重建遮罩跟随当前尺寸
    override func layout() {
        super.layout()
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
        let radii = Self.radii(width: bounds.width, height: bounds.height,
                               referenceWidth: referenceWidth)
        maskLayer.frame = bounds
        maskLayer.path = Self.notchShapePath(width: bounds.width, height: bounds.height,
                                             cornerRadius: radii.corner, shoulderRadius: radii.shoulder)
    }

    /// 刘海形路径（层坐标 y 向上）：
    /// - 顶边 = 面板满宽且与屏幕顶边齐平（盖住真刘海，和屏幕顶边连成一条线）；
    /// - 顶部两角 = 矩形角位上的月牙形黑色填充（凹形肩弧，弧心在角点正下方）：
    ///   黑色在上面铺满整个角位，再沿凹弧收细到内缩 `s` 的竖直侧墙，
    ///   使面板外侧背景在角上呈圆角（右上 ╭ / 左上 ╮），和真刘海肩部（屏幕顶边
    ///   绕开刘海侧壁的倒角）同形；
    /// - 底部两角 = 外凸圆角。
    private static func notchShapePath(width: CGFloat, height: CGFloat,
                                       cornerRadius r: CGFloat, shoulderRadius s: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: height))                        // 顶边左端（屏幕顶边）
        // 顶左肩弧：(0,h) → (s, h-s)，弧心 (0,h-s)，水平切顶边/竖直切左墙
        path.addArc(center: CGPoint(x: 0, y: height - s), radius: s,
                    startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: s, y: r))                          // 左墙（内缩 s）
        path.addArc(center: CGPoint(x: s + r, y: r), radius: r,
                    startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)  // 底左角
        path.addLine(to: CGPoint(x: width - s - r, y: 0))              // 底边
        path.addArc(center: CGPoint(x: width - s - r, y: r), radius: r,
                    startAngle: .pi * 3 / 2, endAngle: .pi * 2, clockwise: false) // 底右角
        path.addLine(to: CGPoint(x: width - s, y: height - s))         // 右墙（内缩 s）
        // 顶右肩弧：(w-s, h-s) → (w, h)，弧心 (w,h-s)
        path.addArc(center: CGPoint(x: width, y: height - s), radius: s,
                    startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()                                            // 顶边 → (0,h)
        return path
    }
}

/// iOS 风格弹簧动画驱动器（只驱动 NotchPanel 的窗口 frame，透明度恒定、不参与动画）。
/// 四分量 = 锚点 centerX / 锚点 topY / width / height：每帧由锚点与尺寸反推 origin
/// （x = centerX - width/2、y = topY - height），尺寸过冲时窗口围绕最终顶边中点
/// 对称放大/收回，位置不发生整体平移（DEV-027）。
/// macOS 对窗口 frame 没有公开的弹簧动画 API（NSAnimationContext 仅支持贝塞尔曲线，
/// animator() 可动画属性的限制见 PITFALLS_DEV.md DEV-016），这里在主线程用定时器对弹簧
/// 微分方程做半隐式欧拉积分后直接 setFrame。response + dampingFraction 语义同 UIKit，
/// dampingFraction < 1 带过冲回弹。分量差异化调参：终点段/打断续接用
/// expandTuning/collapseTuning，段1 引导段用 stageOneExpandTuning/stageOneCollapseTuning。
/// 「刘海生长/缩回」全程必须不透明：任何 alpha 淡入淡出都会让早期生长不可见、
/// 被感知成「从一侧滑入」（DEV-022），形状渐变本身就是全部视觉效果。
/// 动画进行中再次 animate：各分量以当前值/速度为起点重定向（展开↔收起互相打断无缝续接），
/// 旧动画未执行的 handoff 与 completion 作废。
private final class NotchSpringAnimator {
    /// 分量弹簧调参（response + 阻尼比），顺序对齐 springs：centerX, topY, width, height。
    /// 灵动岛式液体拉伸：宽先冲出（带过冲）、高慢半拍平滑下填、锚点临界阻尼零回弹；
    /// 单一组参数（四分量同步、阻尼比 0.72 过冲仅 ~4%）会被感知成线性生长。
    /// 过冲量实测（含交接初速，非静止起跳的理论值）：width ζ=0.47 ≈ 105%，
    /// height ζ=0.66 ≈ 105%。
    /// 单一分量调参；嵌在 file-private 类里，类型仅本文件可见
    struct SpringTuning {
        let response: TimeInterval
        let dampingFraction: CGFloat
    }
    /// 展开段2/重定向（终点段：宽先冲出带过冲、高慢半拍跟上）
    private static let expandTuning: [SpringTuning] = [
        .init(response: 0.32, dampingFraction: 1.0),    // centerX：锚点零回弹
        .init(response: 0.32, dampingFraction: 1.0),    // topY：锚点零回弹
        .init(response: 0.38, dampingFraction: 0.47),   // width：先冲出，~105%
        .init(response: 0.52, dampingFraction: 0.66),   // height：慢半拍跟上，~105%
    ]
    /// 收起段2/重定向（终点段：宽度更快折回，更利落）
    private static let collapseTuning: [SpringTuning] = [
        .init(response: 0.32, dampingFraction: 1.0),    // centerX：锚点零回弹
        .init(response: 0.32, dampingFraction: 1.0),    // topY：锚点零回弹
        .init(response: 0.32, dampingFraction: 0.47),   // width：更快收拢，~105%
        .init(response: 0.52, dampingFraction: 0.66),   // height：~105%
    ]
    /// 段1 引导段（handoff 交接前）：临界阻尼无回弹——先横拉/先纵收本身不带过冲，
    /// 回弹只留给交接后的终点段；本段静止分量的参数无实际作用
    static let stageOneExpandTuning: [SpringTuning] = [
        .init(response: 0.32, dampingFraction: 1.0),    // centerX
        .init(response: 0.32, dampingFraction: 1.0),    // topY
        .init(response: 0.34, dampingFraction: 1.0),    // width：横向拉开（临界阻尼）
        .init(response: 0.52, dampingFraction: 1.0),    // height（本段不动）
    ]
    static let stageOneCollapseTuning: [SpringTuning] = [
        .init(response: 0.32, dampingFraction: 1.0),    // centerX
        .init(response: 0.32, dampingFraction: 1.0),    // topY
        .init(response: 0.32, dampingFraction: 1.0),    // width（本段不动）
        .init(response: 0.36, dampingFraction: 1.0),    // height：纵向先收（临界阻尼）
    ]
    /// settle 阈值：收紧到 0.25pt / 2pt·s⁻¹，避免尾部带速急停的微顿
    private static let valueEpsilon: CGFloat = 0.25
    private static let velocityEpsilon: CGFloat = 2

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

    /// 分量顺序：centerX, topY, width, height（位置 = 锚点，origin 每帧反推）
    private var springs: [Spring]?
    private var completion: (() -> Void)?
    private var timer: Timer?
    private weak var panel: NotchPanel?

    /// 中途交接（两段连续动画）：段1 引导分量位移进度达 progress 时，
    /// 以当前值/速度无缝重定向到 targetFrame（无停顿、无中间回弹）
    struct Handoff {
        let targetFrame: NSRect
        let progress: CGFloat
    }
    private var pendingHandoff: Handoff?
    private var handoffCollapse = false
    /// 引导分量（展开=宽度 / 收起=高度）段1 起点/目标值，tick 里按位移进度判定交接时机
    private var handoffStartValue: CGFloat = 0
    private var handoffLegTarget: CGFloat = 0

    init(panel: NotchPanel) {
        self.panel = panel
    }

    deinit {
        timer?.invalidate()
    }

    /// 启动/重定向动画（只驱动窗口 frame）。必须主线程调用（setFrame）。
    /// collapse = 收起方向（宽度弹簧响应更快，折回更利落）。
    /// handoff 非空时为两段连续动画：段1 用临界阻尼引导段调参弹向 targetFrame，
    /// 引导分量进度达 handoff.progress 时无缝续接到交接目标（默认终点段调参）。
    func animate(to targetFrame: NSRect, collapse: Bool = false,
                 handoff: Handoff? = nil, completion: (() -> Void)? = nil) {
        guard let panel else { return }
        self.completion = nil // 被打断动画的收尾作废
        pendingHandoff = nil

        let tuning: [SpringTuning]
        if handoff != nil {
            tuning = collapse ? Self.stageOneCollapseTuning : Self.stageOneExpandTuning
        } else {
            tuning = collapse ? Self.collapseTuning : Self.expandTuning
        }
        rebuildSprings(target: targetFrame, tuning: tuning)

        if let handoff {
            pendingHandoff = handoff
            handoffCollapse = collapse
            handoffStartValue = collapse ? panel.frame.height : panel.frame.width
            handoffLegTarget = collapse ? targetFrame.height : targetFrame.width
        }
        self.completion = completion
        startTimerIfNeeded()
    }

    /// 以当前值/速度重建四分量弹簧（打断续接与 handoff 交接共用；不动 completion）
    private func rebuildSprings(target: NSRect, tuning: [SpringTuning]) {
        guard let panel else { return }
        let frame = panel.frame
        let previous = springs?.count == 4 ? springs : nil

        func make(_ index: Int, _ initial: CGFloat, _ target: CGFloat) -> Spring {
            if let previous {
                // 打断续接：沿用该分量当前的值与速度
                return Spring(value: previous[index].value, velocity: previous[index].velocity,
                              target: target, response: tuning[index].response,
                              dampingFraction: tuning[index].dampingFraction,
                              valueEpsilon: Self.valueEpsilon, velocityEpsilon: Self.velocityEpsilon)
            }
            return Spring(value: initial, velocity: 0, target: target, response: tuning[index].response,
                          dampingFraction: tuning[index].dampingFraction,
                          valueEpsilon: Self.valueEpsilon, velocityEpsilon: Self.velocityEpsilon)
        }

        springs = [
            make(0, frame.midX, target.midX),
            make(1, frame.maxY, target.maxY),
            make(2, frame.width, target.width),
            make(3, frame.height, target.height),
        ]
        startTimerIfNeeded()
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
        guard let panel, var springs else {
            stopTimer()
            return
        }
        let dt: CGFloat = 1 / 120
        var allSettled = true
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
        let width = springs[2].value
        let height = springs[3].value
        panel.setFrame(NSRect(x: springs[0].value - width / 2, y: springs[1].value - height,
                              width: width, height: height), display: true)

        // 中途交接：引导分量进度达阈值 → 立即以当前值/速度续接到交接目标（无停顿无回弹）
        if let handoff = pendingHandoff {
            let current = handoffCollapse ? springs[3].value : springs[2].value
            let travel = handoffLegTarget - handoffStartValue
            let progress = abs(travel) > 0.5 ? (current - handoffStartValue) / travel : 1
            if progress >= handoff.progress {
                pendingHandoff = nil
                rebuildSprings(target: handoff.targetFrame,
                               tuning: handoffCollapse ? Self.collapseTuning : Self.expandTuning)
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
        pendingHandoff = nil
    }
}
