import JavaScriptCore
import XCTest
@testable import LiveWallpaper

final class WebCardTouchHotspotsTests: XCTestCase {
    func testExactRotatedHitExcludesFullScreenFallbackAndDisabledRoles() throws {
        let js = try XCTUnwrap(JSContext())
        js.exceptionHandler = { _, error in XCTFail(error?.toString() ?? "CardTouch script failed") }
        js.evaluateScript("""
        const window = this, location = {protocol:'lwwp:',host:'wp'}, innerWidth = 100, innerHeight = 100;
        class HTMLCanvasElement { getClientRects() { return [{}]; } }
        const canvas = new HTMLCanvasElement(), hints = new HTMLCanvasElement();
        const document = {querySelectorAll: () => [canvas,hints]};
        const getComputedStyle = e => ({display:'block',visibility:'visible',pointerEvents:e===hints?'none':'auto'});
        let enabled = true;
        const diamond = [[50,25],[75,50],[50,75],[25,50]];
        const backdrop = [[0,0],[100,0],[100,100],[0,100]];
        const inside = (x,y) => Math.abs(x-50)+Math.abs(y-50) <= 25;
        window.__rt5 = {
            touch: () => [{index:3,enabled:true},{index:5,enabled}],
            quad: id => (id===5?diamond:backdrop).map(([x,y])=>({x,y})),
            hitTest: (x,y) => enabled && inside(x,y) ? 5 : 3
        };
        """)
        js.evaluateScript(WebCardTouchHotspots.script)
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(50,50,canvas)")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(50,26,canvas)")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(26,26,canvas)")?.toBool(), false)
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(0,0,canvas)")?.toBool(), false)
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(50,50,hints) === null")?.toBool(), true)
        // A rotated target can span the full viewport in both axes and still leave
        // the corners outside its author-defined quad.
        js.evaluateScript("diamond.splice(0, 4, [50,0], [100,50], [50,100], [0,50])")
        XCTAssertEqual(js.evaluateScript("__lwCardTouchHit(50,50,canvas)")?.toBool(), true)
        XCTAssertEqual(js.evaluateScript("enabled=false; __lwCardTouchHit(50,50,canvas)")?.toBool(), false)
    }
}
