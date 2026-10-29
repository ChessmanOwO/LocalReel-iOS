import Foundation
import YouTubeKit
import WebKit

struct VideoResolver {
    static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"

    /// Both the app and extension use this path. Loading a dynamic page is internal;
    /// no browser screen or video playback is required from the user.
    @MainActor
    func resolveAutomatically(_ url: URL) async throws -> ResolvedVideo {
        do { return try await resolve(url) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard SharedLink.isSupported(url), SharedLink.platform(url) != "YouTube",
                  url.pathExtension.lowercased() != "mp4" else { throw error }
            return try await AutomaticPageResolver().resolve(url)
        }
    }

    func resolve(_ url: URL) async throws -> ResolvedVideo {
        guard SharedLink.isSupported(url) else { throw LocalReelError(message: "Hãy dán liên kết HTTPS của video hoặc file MP4.") }
        if SharedLink.platform(url) == "YouTube" { return try await youtube(url) }
        if url.pathExtension.lowercased() == "mp4" {
            return ResolvedVideo(title: url.deletingPathExtension().lastPathComponent, variants: [MediaVariant(id: "direct", video: url, audio: nil, height: 0, bitrate: 0)])
        }
        var request = URLRequest(url: url)
        request.setValue(Self.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("vi,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 45
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              SharedLink.safeHTTPS(http.url ?? url) else { throw LocalReelError(message: "Trang nguồn chưa cho phép truy cập video này.") }
        let html = String(decoding: data, as: UTF8.self)
        let result = PageMediaParser.parse(html: html, sourceURL: response.url ?? url)
        guard !result.variants.isEmpty else {
            throw LocalReelError(message: "Không tìm thấy nguồn video công khai trên trang này. Video có thể cần đăng nhập hoặc trang nguồn đã đổi cách phát. Thử liên kết trực tiếp của Reel/video.")
        }
        return result
    }

    private func youtube(_ url: URL) async throws -> ResolvedVideo {
        guard let id = SharedLink.videoID(url), id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            throw LocalReelError(message: "Không nhận diện được mã video YouTube trong liên kết.")
        }
        let video = YouTube(videoID: id, methods: [.local])
        do {
            let streams = try await video.streams
            try Task.checkCancellation()
            let metadata = try? await video.metadata
            let audios = streams.filter { $0.includesAudioTrack && !$0.includesVideoTrack && $0.fileExtension == .m4a && $0.isNativelyPlayable }
            let audio = audios.max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            var variants: [MediaVariant] = []
            for stream in streams where stream.includesVideoTrack && stream.fileExtension == .mp4 && stream.isNativelyPlayable {
                guard SharedLink.safeHTTPS(stream.url) else { continue }
                if !stream.includesAudioTrack && audio == nil { continue }
                variants.append(MediaVariant(id: "youtube-\(stream.itag)", video: stream.url,
                    audio: stream.includesAudioTrack ? nil : audio?.url, height: stream.videoResolution ?? 0, bitrate: stream.bitrate ?? 0,
                    headers: ["User-Agent": Self.agent]))
            }
            guard !variants.isEmpty else { throw LocalReelError(message: "YouTube chưa cung cấp luồng MP4 tương thích với iPhone cho video này.") }
            return ResolvedVideo(title: metadata?.title ?? "YouTube \(id)", variants: variants.sorted { ($0.height, $0.bitrate) > ($1.height, $1.bitrate) })
        } catch is CancellationError { throw CancellationError() }
        catch let error as LocalReelError { throw error }
        catch {
            throw LocalReelError(message: "Không lấy được nguồn YouTube trên iPhone: \(error.localizedDescription)")
        }
    }
}

// Parses metadata from the source page. No downloader server or third-party API.
enum PageMediaParser {
    static func parse(html: String, sourceURL: URL) -> ResolvedVideo {
        var variants: [MediaVariant] = []
        var seen = Set<String>()
        func add(_ value: String, height: Int = 0, audio: URL? = nil) {
            let decoded = unescape(value)
            guard let url = URL(string: decoded), SharedLink.safeHTTPS(url), seen.insert(decoded).inserted else { return }
            variants.append(MediaVariant(id: "page-\(variants.count)", video: url, audio: audio, height: height, bitrate: 0,
                headers: ["User-Agent": VideoResolver.agent, "Referer": sourceURL.absoluteString]))
        }
        let tags = captures(#"(?is)<meta\b[^>]*>"#, in: html)
        var title = "Video \(SharedLink.platform(sourceURL))"
        var canonical = sourceURL
        for tag in tags {
            let attrs = attributes(tag)
            let key = attrs["property"] ?? attrs["name"] ?? ""
            let content = unescape(attrs["content"] ?? "")
            if key == "og:title", !content.isEmpty { title = content }
            if key == "og:url", let url = URL(string: content), SharedLink.isSupported(url) { canonical = url }
            if ["og:video", "og:video:url", "og:video:secure_url"].contains(key) { add(content) }
        }
        let identity = facebookID(canonical)
        let scripts = captures(#"(?is)<script\b[^>]*(?:type=["']application/(?:ld\+)?json["']|id=["'](?:__UNIVERSAL_DATA_FOR_REHYDRATION__|SIGI_STATE)["'])[^>]*>(.*?)</script>"#, in: html, group: 1)
        var scopes: [[String: Any]] = []
        func collectScopes(_ value: Any) {
            if let dict = value as? [String: Any] {
                let id = dict["id"].map { String(describing: $0) } ?? dict["video_id"].map { String(describing: $0) }
                if identity == nil || id == identity { scopes.append(dict); return }
                for child in dict.values { collectScopes(child) }
            } else if let list = value as? [Any] { for child in list { collectScopes(child) } }
        }
        for script in scripts {
            if let data = script.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: data) { collectScopes(value) }
        }
        let mediaKeys = ["browser_native_hd_url", "playable_url_quality_hd", "browser_native_sd_url", "playable_url", "contentUrl", "video_url", "downloadAddr", "playAddr", "play_url", "download_url", "playUrl", "masterUrl", "backupUrl"]
        func inspect(_ value: Any, context: String = "") {
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if mediaKeys.contains(key), let text = child as? String {
                        let height = (dict["height"] as? Int) ?? (dict["videoHeight"] as? Int) ?? 0
                        add(text, height: max(height, 0))
                    }
                    if key == "dash_manifest", let text = child as? String {
                        let manifest = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("&lt;") ? unescape(text) : text
                        for var variant in DASHMediaParser.parse(manifest) where seen.insert(variant.video.absoluteString).inserted {
                            variant.headers = ["User-Agent": VideoResolver.agent, "Referer": sourceURL.absoluteString]
                            variants.append(variant)
                        }
                    }
                    if ["url_list", "urlList"].contains(key), context.lowercased().contains("play") || context.lowercased().contains("download") {
                        for text in child as? [String] ?? [] { add(text) }
                    }
                    if let text = child as? String, mediaKeys.contains(key) { add(text) }
                    if child is [String: Any] || child is [Any] { inspect(child, context: context + "." + key) }
                }
            } else if let list = value as? [Any] { for child in list { inspect(child, context: context) } }
        }
        for scope in scopes { inspect(scope) }
        // Public pages can put video metadata in plain script assignments instead of JSON script tags.
        // For Facebook with a known ID, avoid matching unrelated recommended videos across the whole page.
        if identity == nil || SharedLink.platform(sourceURL) != "Facebook" {
            for key in mediaKeys {
                for value in captures("\"" + key + #""\s*:\s*"((?:\\.|[^"\\])*)""#, in: html, group: 1) {
                    if let data = ("[\"" + value + "\"]").data(using: .utf8),
                       let strings = try? JSONSerialization.jsonObject(with: data) as? [String], let text = strings.first { add(text) }
                }
            }
        }
        return ResolvedVideo(title: title, variants: variants.sorted { $0.height > $1.height })
    }

    static func facebookID(_ url: URL) -> String? {
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value { return value }
        let parts = url.pathComponents
        if let index = parts.firstIndex(where: { ["reel", "videos"].contains($0) }), parts.count > index + 1 { return parts[index + 1] }
        return nil
    }
    static func captures(_ pattern: String, in text: String, group: Int = 0) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: group), in: text) else { return nil }
            return String(text[range])
        }
    }
    static func attributes(_ tag: String) -> [String: String] {
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(["'])(.*?)\2"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
            if let key = Range(match.range(at: 1), in: tag), let value = Range(match.range(at: 3), in: tag) { result[String(tag[key]).lowercased()] = String(tag[value]) }
        }
        return result
    }
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// Short-lived, non-persistent WebKit context for pages whose metadata arrives via JS.
/// Never clicks buttons, starts playback, imports login cookies or accepts a TLS bypass.
@MainActor
final class AutomaticPageResolver: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var navigationError: Error?
    private var pageFinished = false
    private var sourceURL: URL?

    static let captureScript = #"""
    (() => {
      const captured = [];
      let total = 0;
      const keep = text => {
        if (typeof text !== 'string' || text.length > 2000000) return;
        if (!/browser_native_|playable_url|dash_manifest|video_url|playAddr|downloadAddr|playUrl|masterUrl|contentUrl/.test(text)) return;
        if (captured.includes(text)) return;
        captured.push(text); total += text.length;
        while (captured.length > 6 || total > 4000000) total -= captured.shift().length;
      };
      Object.defineProperty(window, '__localreelPayloads', { get: () => captured.slice() });
      const read = async response => {
        if (!response.body) return;
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let bytes = 0, text = '';
        try {
          while (true) {
            const part = await reader.read();
            if (part.done) { text += decoder.decode(); keep(text); return; }
            bytes += part.value.byteLength;
            if (bytes > 2000000) { await reader.cancel(); return; }
            text += decoder.decode(part.value, {stream:true});
          }
        } finally { reader.releaseLock(); }
      };
      const originalFetch = window.fetch;
      window.fetch = function(...args) {
        return originalFetch.apply(this, args).then(response => {
          const type = response.headers.get('content-type') || '';
          const length = Number(response.headers.get('content-length'));
          if (/json|text/.test(type) && (!length || (Number.isFinite(length) && length <= 2000000))) {
            read(response.clone()).catch(() => {});
          }
          return response;
        });
      };
      const send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function(...args) {
        this.addEventListener('load', () => {
          try { if (!this.responseType || this.responseType === 'text') keep(this.responseText); } catch (_) {}
        });
        return send.apply(this, args);
      };
    })();
    """#

    static let snapshotScript = #"""
    (() => ({html: document.documentElement ? document.documentElement.outerHTML.slice(0,8000000) : '',
      payloads: window.__localreelPayloads || []}))()
    """#

    func resolve(_ source: URL) async throws -> ResolvedVideo {
        guard SharedLink.isSupported(source), SharedLink.hosts.contains(source.host?.lowercased() ?? "") else {
            throw LocalReelError(message: "Liên kết không thuộc nền tảng được hỗ trợ.")
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.allowsInlineMediaPlayback = false
        config.userContentController.addUserScript(WKUserScript(source: Self.captureScript,
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // Supply a mobile viewport even though this lookup is never presented on screen.
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.customUserAgent = VideoResolver.agent
        web.navigationDelegate = self
        webView = web
        sourceURL = source
        navigationError = nil
        pageFinished = false
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeAllUserScripts()
            webView = nil
            sourceURL = nil
        }
        web.load(URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20))
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            try await Task.sleep(for: .milliseconds(500))
            try Task.checkCancellation()
            if let navigationError { throw navigationError }
            guard let current = web.url, Self.samePlatform(source, current) else { continue }
            // A page can provide metadata before navigation completes. Poll without playing it.
            if let snapshot = (try? await web.evaluateJavaScript(Self.snapshotScript)) as? [String: Any] {
                let html = snapshot["html"] as? String ?? ""
                let payloads = snapshot["payloads"] as? [String] ?? []
                let result = PageMediaParser.parse(html: Self.metadataHTML(html, payloads: payloads), sourceURL: current)
                if !result.variants.isEmpty { return result }
            }
            if pageFinished && Self.needsAuthentication(current) { break }
        }
        try Task.checkCancellation()
        if web.url.map(Self.needsAuthentication) == true {
            throw LocalReelError(message: "Nguồn yêu cầu đăng nhập. Bản này chỉ tự tải nội dung công khai truy cập được; không cần mở hay phát trang nguồn để thử lại.")
        }
        throw LocalReelError(message: "App đã tự kiểm tra trang và dữ liệu tải động nhưng chưa lấy được nguồn video. Bài có thể bị hạn chế, đã xóa hoặc nền tảng đổi cách cung cấp video. Không tạo file tải giả; hãy kiểm tra liên kết hoặc thử lại sau.")
    }

    static func samePlatform(_ source: URL, _ destination: URL) -> Bool {
        SharedLink.safeHTTPS(destination) && SharedLink.hosts.contains(destination.host?.lowercased() ?? "") &&
            SharedLink.platform(source) == SharedLink.platform(destination)
    }
    private static func needsAuthentication(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/login") || path.contains("/accounts/login") || path.contains("/checkpoint")
    }
    static func metadataHTML(_ html: String, payloads: [String]) -> String {
        var result = String(html.prefix(8_000_000))
        for payload in payloads.prefix(6) where payload.utf8.count <= 2_000_000 {
            for line in payload.components(separatedBy: .newlines) {
                let json = line.replacingOccurrences(of: "for (;;);", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard json.first == "{" || json.first == "[",
                      let data = json.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
                result += "<script type=\"application/json\">" + json.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive) + "</script>"
            }
        }
        return result
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let allowed = navigationAction.request.url.map { url in
            guard SharedLink.safeHTTPS(url) else { return false }
            if navigationAction.targetFrame == nil { return false }
            if navigationAction.targetFrame?.isMainFrame == true {
                return sourceURL.map { Self.samePlatform($0, url) } ?? false
            }
            return true
        } ?? false
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pageFinished = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = LocalReelError(message: "Không tải được dữ liệu trang nguồn. Kiểm tra mạng và thử lại.")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = LocalReelError(message: "Không kết nối được trang nguồn. Kiểm tra mạng hoặc thử lại sau.")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        navigationError = LocalReelError(message: "iOS đã dừng bộ tìm nguồn để giải phóng tài nguyên. Hãy thử lại trong app chính.")
    }
}

final class DASHMediaParser: NSObject, XMLParserDelegate {
    private var currentHeight = 0
    private var currentBitrate = 0
    private var currentMime = ""
    private var adaptationMime = ""
    private var buffer = ""
    private var collecting = false
    private var representations: [(url: URL, height: Int, bitrate: Int, mime: String)] = []
    static func parse(_ xml: String) -> [MediaVariant] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let delegate = DASHMediaParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        let audio = delegate.representations.filter { $0.mime == "audio/mp4" }.max { $0.bitrate < $1.bitrate }
        guard let audio else { return [] }
        return delegate.representations.filter { $0.mime == "video/mp4" }.map {
            MediaVariant(id: "dash-\($0.height)-\($0.bitrate)", video: $0.url, audio: audio.url, height: $0.height, bitrate: $0.bitrate)
        }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "AdaptationSet" { adaptationMime = attributes["mimeType"] ?? "" }
        if name == "Representation" {
            currentHeight = Int(attributes["height"] ?? "0") ?? 0
            currentBitrate = Int(attributes["bandwidth"] ?? "0") ?? 0
            currentMime = attributes["mimeType"] ?? adaptationMime
        }
        if name == "BaseURL" { collecting = true; buffer = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { buffer += string } }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "BaseURL" {
            collecting = false
            if let url = URL(string: buffer.trimmingCharacters(in: .whitespacesAndNewlines)), SharedLink.safeHTTPS(url) {
                representations.append((url, currentHeight, currentBitrate, currentMime))
            }
        }
        if name == "AdaptationSet" { adaptationMime = "" }
    }
}
