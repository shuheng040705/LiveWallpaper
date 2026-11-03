import XCTest
import WebKit
@testable import LiveWallpaper

final class WorkshopWebCompatibilityTests: XCTestCase, WKNavigationDelegate {
    private var loaded: XCTestExpectation?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.fulfill()
    }

    func testDropdownUsesViewportCoordinatesAfterScrollingAndResize() throws {
        let config = WKWebViewConfiguration()
        WorkshopWebCompatibility.install(into: config.userContentController)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: config)
        web.navigationDelegate = self
        loaded = expectation(description: "Local Steam menu fixture loaded")
        web.loadHTMLString("""
        <html><style>body { height: 3000px } dialog { padding: 0 }
        .menu { position: absolute; left: 50px; top: 130px; width: 200px; height: 150px }</style>
        <body><dialog><div class="menu" role="listbox">Everyone</div></dialog>
        <script>document.querySelector('dialog').showModal();</script></body></html>
        """, baseURL: URL(string: "https://steamcommunity.com/"))
        wait(for: [loaded!], timeout: 10)

        func checkGeometry(width: Double, height: Double) {
            let checked = expectation(description: "Menu geometry")
            web.evaluateJavaScript("""
            window.scrollTo(0, 300);
            var d = document.querySelector('dialog').getBoundingClientRect();
            var m = document.querySelector('.menu').getBoundingClientRect();
            [d.x, d.y, d.width, d.height, m.x, m.y];
            """) { result, error in
                XCTAssertNil(error)
                guard let values = result as? [Double], values.count == 6 else {
                    XCTFail("No menu geometry"); checked.fulfill(); return
                }
                for (actual, expected) in zip(values, [0, 0, width, height, 50, 130]) {
                    XCTAssertEqual(actual, expected, accuracy: 1)
                }
                checked.fulfill()
            }
            wait(for: [checked], timeout: 5)
        }
        checkGeometry(width: 1200, height: 800)
        web.frame.size = NSSize(width: 900, height: 600)
        checkGeometry(width: 900, height: 600)
    }
}
