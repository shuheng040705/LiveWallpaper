import WebKit
import XCTest
@testable import LiveWallpaper

final class WebWallpaperHotspotsTests: XCTestCase {
    @MainActor
    func testLive2DNamedHitsUseOnlyTheVisibleModelInThePaintedCanvas() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The private app has no global instance to discover. Like Pixi, it invokes the
        // registered Application plugins after its renderer and stage are available.
        let framework = """
            window.PIXI = { Application: class {
                static plugins = [];
                static registerPlugin(plugin) { this.plugins.push(plugin); }
                constructor(canvas) {
                    this.renderer = {view:canvas, screen:{width:100, height:50}};
                    this.stage = {children:[]};
                    for (const p of PIXI.Application.plugins) p.init.call(this);
                }
            }, live2d: { Live2DModel: class {
                hitTest(x,y) { return x > 53 && x < 57 && y > 23 && y < 27 ? ['face'] : []; }
            }}};
            """
        let html = """
            <!doctype html><style>body{margin:0}
            #c{position:absolute;left:12px;top:14px;width:200px;height:100px;padding:6px;border:4px solid;
               transform:scale(1.5);transform-origin:top left}
            #other{position:absolute;left:350px;top:0;width:45px;height:50px}
            #cover{position:absolute;left:180px;top:95px;width:28px;height:22px}</style>
            <canvas id=c width=600 height=300></canvas><canvas id=other></canvas><button id=cover disabled hidden>X</button>
            <script src="framework.js"></script><script>
            window.getterReads = 0;
            (function() {
                const app = new PIXI.Application(c), model = new PIXI.live2d.Live2DModel();
                Object.defineProperty(model,'hitTest',{get(){getterReads++;throw Error();}});
                app.stage.children.push({visible:true,children:[model]});
                window.showBranch = value => { app.stage.children[0].visible = value; };
                Object.defineProperty(window,'privateController',{enumerable:true,get(){getterReads++;throw Error();}});
            })();
            </script>
            """
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data(framework.utf8).write(to: folder.appendingPathComponent("framework.js"))
        let panel = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 400, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.orderBack(nil)
        let renderer = WebRenderer()
        defer { renderer.stop(); panel.close() }
        renderer.attach(to: try XCTUnwrap(panel.contentView))
        let web = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? WebWallpaperView }.first)
        renderer.load(WallpaperItem(id: folder.lastPathComponent, folderURL: folder, title: "Model fixture",
                                    type: .web, fileName: "index.html", previewName: nil, tags: []))
        let deadline = Date().addingTimeInterval(8)
        while (try? await web.evaluateJavaScript("typeof showBranch === 'function'") as? Bool) != true {
            guard Date() < deadline else { return XCTFail("Model fixture did not load") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        func regions(_ x: CGFloat, _ y: CGFloat) async -> [CGRect] {
            await withCheckedContinuation { c in
                WebWallpaperHotspots.read(in: web, at: CGPoint(x: x / 400, y: y / 200)) { c.resume(returning: $0) }
            }
        }
        let hit = await regions(192, 104)
        let region = try XCTUnwrap(hit.first)
        XCTAssertTrue(region.contains(CGPoint(x: 192.0/400, y: 104.0/200)))
        XCTAssertLessThanOrEqual(region.width * 400, 2.001)
        XCTAssertLessThanOrEqual(region.height * 200, 2.001)
        for (x, y) in [(100,100), (370,20), (14,18)] {
            let miss = await regions(CGFloat(x), CGFloat(y))
            XCTAssertTrue(miss.isEmpty)
        }
        _ = try await web.evaluateJavaScript("showBranch(false)")
        let hidden = await regions(192, 104)
        XCTAssertTrue(hidden.isEmpty)
        _ = try await web.evaluateJavaScript("showBranch(true); cover.hidden = false")
        let covered = await regions(192, 104)
        XCTAssertTrue(covered.isEmpty)
        let reads = try await web.evaluateJavaScript("getterReads") as? Int
        XCTAssertEqual(reads, 0)
    }

    @MainActor
    func testStandardTargetsAndNativeInputAcrossLocalDocuments() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let html = #"""
        <!doctype html><style>
          * {box-sizing:border-box} body {margin:0} #art {position:absolute;inset:0;width:100%;height:100%}
          #tool {position:absolute;left:5px;top:5px} #widget {position:absolute;left:5px;top:50px}
          iframe {position:absolute;left:130px;top:50px;width:120px;height:80px;box-sizing:content-box;
                  border:4px solid orange;padding:2px;transform:scale(1.25);transform-origin:top left}
          #opaque {left:300px;top:5px;width:40px;height:40px}
        </style>
        <canvas id="art"></canvas><button id="tool">Action</button><div id="widget"></div>
        <iframe id="local" src="inner.html"></iframe><iframe id="opaque" sandbox srcdoc="<button>opaque</button>"></iframe>
        <script>
          window.actions = [];
          art.addEventListener('pointerdown', e => { if(e.clientX>280) actions.push('drawing') });
          tool.onclick = () => actions.push('tool');
          const shadow = widget.attachShadow({mode:'open'});
          shadow.innerHTML='<span role="switch" style="display:block;width:60px;height:20px">Switch</span><button disabled>Unavailable</button>';
          shadow.firstChild.addEventListener('click', () => actions.push('switch'));
        </script>
        """#
        let inner = #"""
        <!doctype html><style>body{margin:0} #nested{position:absolute;left:14px;top:8px;width:70px;height:50px;border:2px solid pink}</style>
        <iframe id="nested" srcdoc="<style>body{margin:0}button{margin:4px}</style><button onclick='top.actions.push(&quot;frame&quot;)'>Go</button>"></iframe>
        """#
        try Data(html.utf8).write(to: folder.appendingPathComponent("index.html"))
        try Data(inner.utf8).write(to: folder.appendingPathComponent("inner.html"))
        let panel = NSPanel(contentRect: CGRect(x: -4000, y: -4000, width: 400, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.orderBack(nil)
        let renderer = WebRenderer()
        defer { renderer.stop(); panel.close() }
        renderer.attach(to: try XCTUnwrap(panel.contentView))
        let web = try XCTUnwrap(panel.contentView?.subviews.compactMap { $0 as? WebWallpaperView }.first)
        renderer.load(WallpaperItem(id: folder.lastPathComponent, folderURL: folder, title: "Input fixture", type: .web,
                                    fileName: "index.html", previewName: nil, tags: []))
        let deadline = Date().addingTimeInterval(8)
        while (try? await web.evaluateJavaScript("!!window.local?.contentDocument?.getElementById('nested')?.contentDocument?.querySelector('button')") as? Bool) != true {
            guard Date() < deadline else { return XCTFail("Local wallpaper frames did not load") }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x / 400, y: y / 200) }
        func captures(_ p: CGPoint) async -> Bool {
            await withCheckedContinuation { continuation in
                WebWallpaperHotspots.read(in: web, at: p) { continuation.resume(returning: $0.contains { $0.contains(p) }) }
            }
        }
        func clicked(_ p: CGPoint) async -> Bool {
            await withCheckedContinuation { continuation in
                web.send(.down, at: p)
                web.send(.up, at: p) { value, _ in continuation.resume(returning: value as? Bool == true) }
            }
        }
        let artwork = point(310, 160), switchPoint = point(25, 59), nestedButton = point(177, 90)
        let disabled = point(30, 80), opaque = point(323, 25), blank = point(75, 155)
        for p in [point(23, 15), switchPoint, nestedButton] {
            let priority = await captures(p)
            XCTAssertTrue(priority, "Expected a standard interactive target at \(p)")
        }
        for p in [artwork, disabled, opaque, blank] {
            let priority = await captures(p)
            XCTAssertFalse(priority, "Desktop click should pass through at \(p)")
        }
        for p in [disabled, opaque] {
            let sent = await clicked(p)
            XCTAssertFalse(sent, "Disabled control or sandbox frame received a gesture")
        }
        for p in [artwork, switchPoint, nestedButton] {
            let sent = await clicked(p)
            XCTAssertTrue(sent, "Native input rejected at \(p)")
        }
        let eventsDeadline = Date().addingTimeInterval(3)
        while (try await web.evaluateJavaScript("actions.length") as? Int) != 3 && Date() < eventsDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let actions = try await web.evaluateJavaScript("actions") as? [String]
        XCTAssertEqual(actions, ["drawing", "switch", "frame"])

        _ = try await web.evaluateJavaScript("local.style.transform = 'rotate(90deg) scale(1.25)'; document.body.style.height = '400px'; scrollTo(0, 20)")
        let rotatedAndScrolled = await captures(point(90, 77))
        XCTAssertTrue(rotatedAndScrolled, "Frame hit testing must use local viewport coordinates after transforms and scrolling")
        _ = try await web.evaluateJavaScript("scrollTo(0, 0); art.style.cursor = 'pointer'")
        let hinted = await captures(artwork)
        XCTAssertTrue(hinted)
        _ = try await web.evaluateJavaScript("art.style.cursor = 'default'")
        let cleared = await captures(artwork)
        XCTAssertFalse(cleared)
    }
}
