import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperMediaTests: XCTestCase {
    @MainActor
    func testStalledNativeLoopReloadsOnlyDuringActivePlayback() async throws {
        _ = NSApplication.shared
        let view = WKWebView()
        let result = try await view.evaluateJavaScript("""
        (() => {
            let hidden = false;
            Object.defineProperty(document, 'hidden', {get: () => hidden});
            const timers = [];
            window.setTimeout = fn => timers.push(fn);
            \(WebWallpaperMedia.script)

            // State reported by WebKit when a local WebM stops after a native repeat.
            let time = 32, frames = 600, paused = false, loads = 0, plays = 0;
            const video = document.createElement('video');
            document.body.appendChild(video);
            Object.defineProperties(video, {
                currentSrc: {value: 'lwwp://wp/files/clip.webm'}, duration: {value: 32},
                currentTime: {get: () => time}, paused: {get: () => paused}
            });
            video.loop = true;
            video.playbackRate = 4;
            video.getVideoPlaybackQuality = () => ({totalVideoFrames:frames});
            video.load = () => { loads++; video.playbackRate = video.defaultPlaybackRate; };
            video.play = () => { plays++; return Promise.resolve(); };
            const sample = () => video.dispatchEvent(new Event('timeupdate'));
            const tick = () => timers.shift()?.();
            const results = [];

            sample(); tick();
            results.push(loads, plays);
            sample(); time = 0.1; frames++; tick();
            results.push(loads);                       // native rewind succeeded
            time = 32; sample(); paused = true; tick();
            results.push(loads);                       // author paused while timer was armed
            paused = false; sample(); window.__lwSetHostMediaPaused(true); tick();
            results.push(loads);                       // host suspended playback at the tail
            window.__lwSetHostMediaPaused(false); sample();
            hidden = true; tick(); results.push(loads); // Stage Manager can report a playing desktop hidden
            hidden = false; video.loop = false; sample(); tick(); results.push(loads);
            video.loop = true; sample(); tick(); results.push(loads, plays, video.playbackRate);
            return results;
        })()
        """)
        XCTAssertEqual(result as? [Int], [1, 1, 1, 1, 1, 2, 2, 3, 3, 4])
    }

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
