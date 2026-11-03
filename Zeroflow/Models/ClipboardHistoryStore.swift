import AppKit
import Combine
import CryptoKit

/// 剪贴板历史存储：去重置顶、按设置裁剪条数、JSON 持久化到 Application Support。
/// 图片存 `Application Support/zeroflow/clipboard-images/`，裁剪/清空时同步删除文件。
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    /// 最新在前
    @Published private(set) var items: [ClipboardItem] = []

    /// 单条文本上限（UTF-8 字节）
    static let maxTextBytes = 256 * 1024
    /// 单张图片 PNG 上限
    static let maxImageBytes = 20 * 1024 * 1024

    private let fileManager = FileManager.default
    private let imagesDirectory: URL
    private let historyFile: URL
    /// 编码/写盘放串行后台队列，避免大历史阻塞主线程；顺序由队列保证
    private let ioQueue = DispatchQueue(label: "zeroflow.clipboard-history.io", qos: .utility)
    private let imageCache = NSCache<NSString, NSImage>()

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let baseDirectory = support.appendingPathComponent("zeroflow", isDirectory: true)
        imagesDirectory = baseDirectory.appendingPathComponent("clipboard-images", isDirectory: true)
        historyFile = baseDirectory.appendingPathComponent("clipboard-history.json")
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 写入

    @discardableResult
    func addText(_ text: String, sourceApp: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let bytes = text.utf8.count
        guard bytes <= Self.maxTextBytes else { return false }
        insert(ClipboardItem(id: UUID(),
                             kind: .text,
                             text: text,
                             imageFileName: nil,
                             pixelWidth: 0,
                             pixelHeight: 0,
                             byteCount: bytes,
                             sourceAppName: sourceApp,
                             createdAt: Date(),
                             contentHash: Self.hash(Data(text.utf8))))
        return true
    }

    @discardableResult
    func addImage(pngData: Data, pixelSize: CGSize, sourceApp: String) -> Bool {
        guard !pngData.isEmpty, pngData.count <= Self.maxImageBytes else { return false }
        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let url = imagesDirectory.appendingPathComponent(fileName)
        do {
            try pngData.write(to: url, options: .atomic)
        } catch {
            ZSLog("clipboard: write image failed \(error)")
            return false
        }
        insert(ClipboardItem(id: id,
                             kind: .image,
                             text: "",
                             imageFileName: fileName,
                             pixelWidth: Int(pixelSize.width.rounded()),
                             pixelHeight: Int(pixelSize.height.rounded()),
                             byteCount: pngData.count,
                             sourceAppName: sourceApp,
                             createdAt: Date(),
                             contentHash: Self.hash(pngData)))
        return true
    }

    // MARK: - 读取

    func imageURL(for item: ClipboardItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        return imagesDirectory.appendingPathComponent(name)
    }

    func pngData(for item: ClipboardItem) -> Data? {
        guard let url = imageURL(for: item) else { return nil }
        return try? Data(contentsOf: url)
    }

    func image(for item: ClipboardItem) -> NSImage? {
        guard let url = imageURL(for: item) else { return nil }
        let key = url.lastPathComponent as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    // MARK: - 维护

    /// 按当前「最多保存条数」裁剪（设置页改条数后调用）
    func trimToLimit() {
        trimToLimit(persist: true)
    }

    func clear() {
        for item in items { removeImageFile(for: item) }
        items.removeAll()
        persist()
    }

    // MARK: - 内部

    private func insert(_ item: ClipboardItem) {
        // 同一内容再复制只置顶：先移除旧条目（连同其图片文件）
        let duplicates = items.filter { $0.contentHash == item.contentHash && $0.kind == item.kind }
        if !duplicates.isEmpty {
            items.removeAll { duplicate in duplicates.contains { $0.id == duplicate.id } }
            for duplicate in duplicates { removeImageFile(for: duplicate) }
        }
        items.insert(item, at: 0)
        trimToLimit(persist: false)
        persist()
    }

    private func trimToLimit(persist shouldPersist: Bool) {
        let limit = max(1, min(1000, SettingsStore.shared.clipboardMaxItems))
        guard items.count > limit else { return }
        let removed = items.suffix(items.count - limit)
        items.removeLast(items.count - limit)
        for item in removed { removeImageFile(for: item) }
        if shouldPersist { persist() }
    }

    private func removeImageFile(for item: ClipboardItem) {
        guard let url = imageURL(for: item) else { return }
        imageCache.removeObject(forKey: url.lastPathComponent as NSString)
        try? fileManager.removeItem(at: url)
    }

    private func load() {
        guard let data = try? Data(contentsOf: historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode([ClipboardItem].self, from: data) else {
            ZSLog("clipboard: decode history failed")
            return
        }
        items = stored
        trimToLimit(persist: false)
    }

    private func persist() {
        let snapshot = items
        let url = historyFile
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            } catch {
                ZSLog("clipboard: persist failed \(error)")
            }
        }
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
