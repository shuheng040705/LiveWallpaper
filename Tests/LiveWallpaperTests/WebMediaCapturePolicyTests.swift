import XCTest
@testable import LiveWallpaper

final class WebMediaCapturePolicyTests: XCTestCase {
    func testDocumentStartPolicyBlocksModernAndLegacyCaptureEntryPoints() {
        let script = WebMediaCapturePolicy.denialScriptSource
        XCTAssertTrue(script.contains("mediaDevices"))
        XCTAssertTrue(script.contains("getUserMedia"))
        XCTAssertTrue(script.contains("getDisplayMedia"))
        XCTAssertTrue(script.contains("webkitGetUserMedia"))
        XCTAssertTrue(script.contains("NotAllowedError"))
    }

    func testPolicyDoesNotDisableOrdinaryMediaPlaybackOrDeviceEnumeration() {
        let script = WebMediaCapturePolicy.denialScriptSource
        XCTAssertFalse(script.contains("enumerateDevices"))
        XCTAssertFalse(script.contains("HTMLMediaElement"))
        XCTAssertFalse(script.contains("AudioContext"))
    }
}
