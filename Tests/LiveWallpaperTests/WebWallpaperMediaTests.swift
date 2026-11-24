import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperMediaTests: XCTestCase {
    @MainActor
    func testDetachedAudioKeepsAuthoredVolumeAcrossMasterChanges() async throws {
        _ = NSApplication.shared
        let view = WKWebView()
        let script = """
        const rawVolume = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume').get;
        \(WebWallpaperMedia.script)
        const voice = new Audio();
        voice.volume = 0.8;
        voice.play().catch(() => {});
        const levels = [rawVolume.call(voice)];
        window.__lwSetMediaGain(0.5);
        levels.push(rawVolume.call(voice));
        voice.volume = voice.volume / 2;
        levels.push(rawVolume.call(voice));
        window.__lwSetMediaGain(0);
        levels.push(rawVolume.call(voice));
        window.__lwSetMediaGain(1);
        levels.push(rawVolume.call(voice));
        levels
        """
        let result = try await view.evaluateJavaScript(script)
        let levels = try XCTUnwrap(result as? [Double])
        let expected = [0, 0.4, 0.2, 0, 0.4]
        XCTAssertEqual(levels.count, expected.count)
        for (level, target) in zip(levels, expected) {
            XCTAssertEqual(level, target, accuracy: 0.00001)
        }
    }
}
