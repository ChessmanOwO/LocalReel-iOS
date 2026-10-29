import XCTest
import AVFoundation
@testable import LocalReelCore

final class OnDeviceTests: XCTestCase {
    func testSharedLinksAndYouTubeIDs() throws {
        for text in ["https://youtu.be/jNQXAC9IVRw", "https://www.youtube.com/shorts/jNQXAC9IVRw", "https://www.youtube.com/watch?v=jNQXAC9IVRw"] {
            XCTAssertEqual(SharedLink.videoID(try XCTUnwrap(URL(string: text))), "jNQXAC9IVRw")
            XCTAssertNotNil(SharedLink.find(in: "Chia sẻ: \(text)"))
        }
        for text in ["https://youtube.com.attacker.test/watch?v=jNQXAC9IVRw", "http://youtu.be/jNQXAC9IVRw", "https://127.0.0.1/video.mp4", "https://user:pass@example.com/video.mp4"] {
            XCTAssertNil(SharedLink.find(in: text))
        }
    }
    func testHTMLMetadataAttributeOrderAndEscapedQuery() {
        let html = #"<meta content='A &amp; B' property='og:title'><meta content='https://cdn.example/video.mp4?a=1&amp;b=2' property='og:video'>"#
        let result = PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.instagram.com/reel/abc/")!)
        XCTAssertEqual(result.title, "A & B")
        XCTAssertEqual(result.variants.first?.video.absoluteString, "https://cdn.example/video.mp4?a=1&b=2")
    }
    func testFacebookDoesNotSelectRecommendedVideo() {
        let html = #"<script type="application/json">{"items":[{"id":"999","browser_native_hd_url":"https://cdn.example/wrong.mp4"},{"id":"123","browser_native_sd_url":"https://cdn.example/right.mp4"}]}</script>"#
        let result = PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.facebook.com/reel/123/")!)
        XCTAssertEqual(result.variants.map(\.video.lastPathComponent), ["right.mp4"])
    }
    func testDASHSeparateTracksAndEscapes() {
        let xml = #"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation height="1080" bandwidth="4000000"><BaseURL>https://cdn.example/video.mp4?a=1&amp;b=2</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation bandwidth="128000"><BaseURL>https://cdn.example/audio.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"#
        let result = DASHMediaParser.parse(xml)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.height, 1080)
        XCTAssertEqual(result.first?.audio?.lastPathComponent, "audio.m4a")
        XCTAssertEqual(result.first?.video.query, "a=1&b=2")
    }
    func testInvalidMediaAndUnsupportedPageAreNotSuccess() {
        let html = #"<meta property="og:video" content="file:///etc/passwd"><meta property="og:video" content="https://192.168.1.1/video.mp4">"#
        XCTAssertTrue(PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.instagram.com/reel/test/")!).variants.isEmpty)
        XCTAssertTrue(PageMediaParser.parse(html: "login required", sourceURL: URL(string: "https://www.facebook.com/reel/123/")!).variants.isEmpty)
    }
    func testJobRoundTrip() throws {
        var job = LocalJob(sourceURL: URL(string: "https://youtu.be/jNQXAC9IVRw")!)
        job.state = .complete; job.filename = "LocalReel-\(job.id).mp4"
        let restored = try JSONDecoder().decode(LocalJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(job.id, restored.id)
        XCTAssertEqual(job.filename, restored.filename)
        XCTAssertEqual(restored.state, .complete)
    }
}

extension OnDeviceTests {
    @MainActor
    func testExportSeparateLocalTracks() async throws {
        guard let directory = ProcessInfo.processInfo.environment["LOCALREEL_MEDIA_FIXTURE"] else { throw XCTSkip("Local media fixtures not supplied") }
        let root = URL(fileURLWithPath: directory)
        let output = root.appendingPathComponent("native-output.mp4")
        try? FileManager.default.removeItem(at: output)
        try await VideoPipeline().export(inputs: [root.appendingPathComponent("video.mp4"), root.appendingPathComponent("audio.m4a")], output: output) { _ in }
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        XCTAssertGreaterThan((try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0, 0)
    }
    func testLiveSourceExtraction() async throws {
        guard let raw = ProcessInfo.processInfo.environment["LOCALREEL_LIVE_SOURCE"], let url = URL(string: raw) else { throw XCTSkip("No live source requested") }
        let resolved = try await VideoResolver().resolve(url)
        XCTAssertFalse(resolved.variants.isEmpty)
        XCTAssertTrue(resolved.variants.allSatisfy { SharedLink.safeHTTPS($0.video) })
        print("ONDEVICE_SOURCE_OK variants=\(resolved.variants.count) heights=\(Set(resolved.variants.map(\.height)).sorted())")
    }
}

extension OnDeviceTests {
    @MainActor
    func testLiveDownloadAndNativeMP4() async throws {
        guard let raw = ProcessInfo.processInfo.environment["LOCALREEL_LIVE_DOWNLOAD"], let url = URL(string: raw),
              let directory = ProcessInfo.processInfo.environment["LOCALREEL_MEDIA_FIXTURE"] else { throw XCTSkip("No live download requested") }
        let resolved = try await VideoResolver().resolve(url)
        let variant = try XCTUnwrap(resolved.variants.max { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) })
        let root = URL(fileURLWithPath: directory)
        let pipeline = VideoPipeline(transferRoot: root.appendingPathComponent("transfers"), videoRoot: root.appendingPathComponent("downloaded"))
        let output = try await pipeline.run(variant, id: UUID().uuidString) { _ in }
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(video.isEmpty)
        XCTAssertFalse(audio.isEmpty)
        print("NATIVE_DOWNLOAD_OK bytes=\((try output.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)")
    }
}

extension OnDeviceTests {
    func testFacebookJSONDASHRetainsXMLQueryEscapes() throws {
        let xml = #"<MPD><Period><AdaptationSet mimeType="video/mp4"><Representation height="1080"><BaseURL>https://cdn.example/v.mp4?a=1&amp;b=2</BaseURL></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation><BaseURL>https://cdn.example/a.m4a</BaseURL></Representation></AdaptationSet></Period></MPD>"#
        let json = String(decoding: try JSONSerialization.data(withJSONObject: ["id":"123", "dash_manifest":xml]), as: UTF8.self)
        let html = "<script type=\"application/json\">" + json + "</script>"
        let resolved = PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.facebook.com/reel/123/")!)
        XCTAssertEqual(resolved.variants.count, 1)
        XCTAssertEqual(resolved.variants.first?.video.query, "a=1&b=2")
        XCTAssertEqual(resolved.variants.first?.audio?.lastPathComponent, "a.m4a")
    }
}

extension OnDeviceTests {

    func testInstagramVideoURLFromInlineScript() {
        let html = #"<script>window.data={"video_url":"https:\/\/cdn.example\/video.mp4?a=1\u0026b=2"};</script>"#
        let result = PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.instagram.com/reel/abc/")!)
        XCTAssertEqual(result.variants.first?.video.absoluteString, "https://cdn.example/video.mp4?a=1&b=2")
    }
    func testExplicitMetadataHeightAndNoGuessedHDResolution() {
        let html = #"<script type="application/json">{"items":[{"id":"123","browser_native_hd_url":"https://cdn.example/v.mp4","height":720}]}</script>"#
        let source = URL(string: "https://www.facebook.com/reel/123/")!
        XCTAssertEqual(PageMediaParser.parse(html: html, sourceURL: source).variants.first?.height, 720)
        let noHeight = html.replacingOccurrences(of: ",\"height\":720", with: "")
        XCTAssertEqual(PageMediaParser.parse(html: noHeight, sourceURL: source).variants.first?.height, 0)
    }
    @MainActor
    func testAutomaticCapturedPayloadKeepsRequestedFacebookIdentity() {
        let payload = #"for (;;);{"items":[{"id":"999","browser_native_hd_url":"https://cdn.example/wrong.mp4"},{"id":"123","browser_native_sd_url":"https://cdn.example/right.mp4"}]}"#
        let html = AutomaticPageResolver.metadataHTML("<html></html>", payloads: [payload, "not JSON"])
        let result = PageMediaParser.parse(html: html, sourceURL: URL(string: "https://www.facebook.com/reel/123/")!)
        XCTAssertEqual(result.variants.map(\.video.lastPathComponent), ["right.mp4"])
    }
    @MainActor
    func testAutomaticNavigationRejectsOtherPlatformAndPrivateHosts() {
        let source = URL(string: "https://fb.watch/abc/")!
        XCTAssertTrue(AutomaticPageResolver.samePlatform(source, URL(string: "https://www.facebook.com/reel/123/")!))
        for raw in ["https://www.instagram.com/reel/abc/", "https://facebook.com.attacker.test/", "https://127.0.0.1/", "http://www.facebook.com/reel/123/"] {
            XCTAssertFalse(AutomaticPageResolver.samePlatform(source, URL(string: raw)!))
        }
    }
}

extension OnDeviceTests {

    func testLegacyJobDoesNotClaimPhotosWasSaved() throws {
        var old = LocalJob(sourceURL: URL(string: "https://youtu.be/jNQXAC9IVRw")!)
        old.state = .complete
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "photosSaved")
        let restored = try JSONDecoder().decode(LocalJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.photosSaved)
    }
    func testPhotosSaveStateAndReceiptRoundTrip() throws {
        var job = LocalJob(sourceURL: URL(string: "https://youtu.be/jNQXAC9IVRw")!)
        job.state = .savingPhotos
        XCTAssertTrue(job.state.isRunning)
        XCTAssertNotEqual(job.state, .complete)
        job.state = .complete; job.photosSaved = true
        let restored = try JSONDecoder().decode(LocalJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(restored.photosSaved, true)
        XCTAssertEqual(restored.state.label, "Lưu thành công")
    }
}
