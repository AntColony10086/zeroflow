import Foundation

/// 一条剪贴板历史。文本直接内联；图片以 PNG 落盘（`clipboard-images/<id>.png`），
/// 条目只记文件名与像素尺寸，避免历史 JSON 体积随图片膨胀。
struct ClipboardItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text
        case image
    }

    let id: UUID
    let kind: Kind
    /// 文本内容；图片条目为空串
    let text: String
    /// 图片文件名（仅 image 条目）
    let imageFileName: String?
    let pixelWidth: Int
    let pixelHeight: Int
    /// 文本按 UTF-8 字节、图片按 PNG 文件大小
    let byteCount: Int
    let sourceAppName: String
    let createdAt: Date
    /// 内容哈希（文本哈希原文、图片哈希 PNG 字节），用于去重置顶
    let contentHash: String

    /// 列表未展开时显示的单行文本：换行/制表符替换为空格后交给 UI 截断
    var singleLineText: String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
