import Foundation

struct LocalReelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum JobState: String, Codable {
    case queued, extracting, awaitingSelection, downloading, merging, savingPhotos, complete, error, cancelled, paused
    var label: String {
        switch self {
        case .queued: return "Đang chờ"
        case .extracting: return "Đang tìm nguồn trên iPhone"
        case .awaitingSelection: return "Chọn chất lượng"
        case .downloading: return "Đang tải về iPhone"
        case .merging: return "Đang tạo MP4 trên iPhone"
        case .savingPhotos: return "Đang lưu vào Photos…"
        case .complete: return "Lưu thành công"
        case .error: return "Chưa tải được"
        case .cancelled: return "Đã hủy"
        case .paused: return "Đã tạm dừng"
        }
    }
    var isRunning: Bool { [.queued, .extracting, .downloading, .merging, .savingPhotos].contains(self) }
}

struct LocalJob: Codable, Identifiable {
    var id = UUID().uuidString
    let sourceURL: URL
    var title = "Video"
    var state: JobState = .queued
    var progress: Double?
    var received: Int64 = 0
    var expected: Int64?
    var quality = "best"
    var heights: [Int] = []
    var photosSaved: Bool?
    var filename: String?
    var errorMessage: String?
    var note = ""
    var createdAt = Date()
    var platform: String { SharedLink.platform(sourceURL) }
}

struct MediaVariant: Identifiable {
    let id: String
    let video: URL
    let audio: URL?
    let height: Int
    let bitrate: Int
    var headers: [String: String] = [:]
}

struct ResolvedVideo {
    let title: String
    let variants: [MediaVariant]
}

struct TransferUpdate {
    let state: JobState
    let progress: Double?
    var received: Int64 = 0
    var expected: Int64? = nil
    var note: String = ""
}

enum SharedLink {
    static let hosts: Set<String> = ["facebook.com", "www.facebook.com", "m.facebook.com", "web.facebook.com", "fb.watch",
        "instagram.com", "www.instagram.com", "m.instagram.com", "tiktok.com", "www.tiktok.com", "m.tiktok.com",
        "vm.tiktok.com", "vt.tiktok.com", "douyin.com", "www.douyin.com", "v.douyin.com", "www.iesdouyin.com",
        "xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com", "www.xhslink.com", "youtube.com", "www.youtube.com",
        "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtube-nocookie.com"]

    static func find(in text: String) -> String? {
        guard text.utf8.count <= 16_384,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, isSupported(url) else { return nil }
            return url.absoluteString
        }.first
    }
    static func isSupported(_ url: URL) -> Bool {
        guard safeHTTPS(url) else { return false }
        return hosts.contains(url.host!.lowercased()) || url.pathExtension.lowercased() == "mp4"
    }
    static func safeHTTPS(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, !host.contains(":"), host != "localhost", !host.hasSuffix(".local") else { return false }
        let pieces = host.split(separator: ".")
        if pieces.count == 4, pieces.allSatisfy({ Int($0) != nil }) {
            guard let a = Int(pieces[0]), let b = Int(pieces[1]) else { return false }
            return !(a == 0 || a == 10 || a == 127 || a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 || a >= 224)
        }
        return true
    }
    static func platform(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtu") { return "YouTube" }
        if host.contains("facebook") || host == "fb.watch" { return "Facebook" }
        if host.contains("instagram") { return "Instagram" }
        if host.contains("tiktok") { return "TikTok" }
        if host.contains("douyin") { return "Douyin" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "Xiaohongshu" }
        return "MP4"
    }
    static func videoID(_ url: URL) -> String? {
        if url.host == "youtu.be" { return url.pathComponents.dropFirst().first }
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return value }
        let path = url.pathComponents.filter { $0 != "/" }
        if let first = path.first, ["shorts", "embed", "live"].contains(first), path.count > 1 { return path[1] }
        return nil
    }
}
