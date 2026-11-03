import SwiftUI
import AppKit

/// 面板度量：控制器算窗口尺寸、视图排版共用，避免两处漂移
enum ClipboardPanelMetrics {
    static let listWidth: CGFloat = 360
    static let previewWidth: CGFloat = 460
    static let rowHeight: CGFloat = 34
    static let searchHeight: CGFloat = 44
    static let footerHeight: CGFloat = 28
    static let maxRows = 10
    static let cornerRadius: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    static func rows(for count: Int) -> Int {
        max(1, min(count, maxRows))
    }

    static func height(for count: Int) -> CGFloat {
        searchHeight + CGFloat(rows(for: count)) * rowHeight + footerHeight + 10
    }
}

/// 剪贴板历史面板的展示模型（仅主线程读写）
final class ClipboardViewModel: ObservableObject {
    @Published var items: [ClipboardItem]
    @Published var query = ""
    @Published var selectedIndex = 0
    @Published var previewItem: ClipboardItem?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB]
        return formatter
    }()

    init(items: [ClipboardItem]) {
        self.items = items
    }

    var filteredItems: [ClipboardItem] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return items }
        let imageKeyword = L10n.tr("图片").lowercased()
        return items.filter { item in
            if item.sourceAppName.lowercased().contains(keyword) { return true }
            switch item.kind {
            case .image:
                return imageKeyword.contains(keyword)
            case .text:
                return item.text.lowercased().contains(keyword)
            }
        }
    }

    var selectedItem: ClipboardItem? {
        let list = filteredItems
        guard selectedIndex >= 0, selectedIndex < list.count else { return nil }
        return list[selectedIndex]
    }

    func rowTitle(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            return item.singleLineText
        case .image:
            return "\(L10n.tr("图片")) · \(item.pixelWidth)×\(item.pixelHeight) · \(Self.byteFormatter.string(fromByteCount: Int64(item.byteCount)))"
        }
    }

    static func timeString(for date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func byteString(for item: ClipboardItem) -> String {
        byteFormatter.string(fromByteCount: Int64(item.byteCount))
    }
}

/// 剪贴板历史面板内容：左侧列表（搜索 + 单行记录 + 页脚），右侧仅在展开时出现完整预览
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardViewModel
    var onSelect: (Int) -> Void
    var onHover: (Int) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            if model.previewItem != nil {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: ClipboardPanelMetrics.dividerWidth)
                previewColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: ClipboardPanelMetrics.cornerRadius, style: .continuous))
    }

    // MARK: - 列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchBar
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            if model.filteredItems.isEmpty {
                emptyState
            } else {
                list
            }
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
            footer
        }
        .frame(width: ClipboardPanelMetrics.listWidth)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            TextField(L10n.tr("搜索剪贴板历史"), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.searchHeight)
        .onAppear {
            // 面板刚成为 key window 时设焦点，避免首帧 TextField 尚未挂载
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                        row(item: item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
            }
            .onChange(of: model.selectedIndex) { _ in
                let list = model.filteredItems
                let index = model.selectedIndex
                guard index >= 0, index < list.count else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(list[index].id, anchor: .center)
                }
            }
        }
    }

    private func row(item: ClipboardItem, index: Int) -> some View {
        let selected = index == model.selectedIndex
        return HStack(spacing: 10) {
            thumbnail(for: item)
                .frame(width: 22, height: 22)
                .clipped()
            Text(model.rowTitle(for: item))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(ClipboardViewModel.timeString(for: item.createdAt))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardPanelMetrics.rowHeight - 2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { onHover(index) }
        }
        .onTapGesture { onSelect(index) }
    }

    @ViewBuilder private func thumbnail(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let image = ClipboardHistoryStore.shared.image(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(model.query.isEmpty ? L10n.tr("暂无剪贴板历史") : L10n.tr("没有匹配的记录"))
                .font(.system(size: 12.5))
            Text(model.query.isEmpty
                 ? L10n.tr("复制文本或图片后会出现在这里")
                 : L10n.tr("试试其他关键词"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if AccessibilityPermission.isGranted {
                Text(L10n.tr("↑↓ 选择 · ↵ 粘贴 · esc 关闭"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                Text(L10n.tr("未授予辅助功能权限：选中仅复制到剪贴板"))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Text("\(model.filteredItems.count)")
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.footerHeight)
    }

    // MARK: - 预览

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.previewItem {
                previewHeader(for: item)
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 1)
                previewBody(for: item)
            }
        }
        .frame(width: ClipboardPanelMetrics.previewWidth)
    }

    private func previewHeader(for item: ClipboardItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.sourceAppName.isEmpty ? L10n.tr("未知来源") : item.sourceAppName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(previewSubtitle(for: item))
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(ClipboardViewModel.timeString(for: item.createdAt))
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(height: ClipboardPanelMetrics.searchHeight)
    }

    private func previewSubtitle(for item: ClipboardItem) -> String {
        switch item.kind {
        case .text:
            let lines = item.text.split(separator: "\n", omittingEmptySubsequences: false).count
            return "\(L10n.tr("文本")) · \(lines) \(L10n.tr("行")) · \(ClipboardViewModel.byteString(for: item))"
        case .image:
            return "\(L10n.tr("图片")) · \(item.pixelWidth)×\(item.pixelHeight) · \(ClipboardViewModel.byteString(for: item))"
        }
    }

    @ViewBuilder private func previewBody(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView(.vertical, showsIndicators: true) {
                Text(item.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .image:
            if let image = ClipboardHistoryStore.shared.image(for: item) {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: ClipboardPanelMetrics.previewWidth - 24,
                               maxHeight: CGFloat(ClipboardPanelMetrics.rows(for: model.filteredItems.count)) * ClipboardPanelMetrics.rowHeight + 4)
                        .padding(12)
                }
            } else {
                Text(L10n.tr("图片已不可用"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
