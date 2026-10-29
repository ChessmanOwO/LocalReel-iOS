import Foundation
import XCTest
@testable import LocalReel
final class NetworkRegressionTests: XCTestCase {
    func testVideoSourcesAndLocalNetworkRejection() {
        XCTAssertNotNil(SharedLink.find(in: "https://www.youtube.com/shorts/jNQXAC9IVRw"))
        XCTAssertNotNil(SharedLink.find(in: "https://www.facebook.com/reel/123/"))
        XCTAssertNil(SharedLink.find(in: "https://youtube.com.attacker.test/watch?v=jNQXAC9IVRw"))
        XCTAssertNil(SharedLink.find(in: "https://127.0.0.1/video.mp4"))
    }
}

extension NetworkRegressionTests {

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

extension NetworkRegressionTests {

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
