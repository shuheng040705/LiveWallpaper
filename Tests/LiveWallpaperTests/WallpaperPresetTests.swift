import XCTest
@testable import LiveWallpaper

final class WallpaperPresetTests: XCTestCase {
    func testAudioResponseIsOptInForNewWallpaper() {
        let id = "test-\(UUID().uuidString)"
        let settings = GeneralWallpaperSettings.shared
        defer { settings.reset(id) }

        XCTAssertFalse(settings.audioListen(id))
        settings.setAudioListen(true, id)
        XCTAssertTrue(settings.audioListen(id))
    }

    @MainActor
    func testVideoCoverPositionMovesOnlyTheCroppedAxis() {
        let id = "test-\(UUID().uuidString)"
        let settings = GeneralWallpaperSettings.shared
        defer { settings.reset(id) }
        settings.setAlignment(.cover, id)

        let view = VideoPlayerView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.itemID = id
        view.videoAspect = 2

        settings.setPosition(0, id)
        view.applyScale()
        XCTAssertEqual(view.playerLayer.bounds.width, 200, accuracy: 0.001)
        XCTAssertEqual(view.playerLayer.position.x, 100, accuracy: 0.001)
        XCTAssertEqual(view.playerLayer.position.y, 50, accuracy: 0.001)

        settings.setPosition(100, id)
        view.applyScale()
        XCTAssertEqual(view.playerLayer.position.x, 0, accuracy: 0.001)
        XCTAssertEqual(view.playerLayer.position.y, 50, accuracy: 0.001)
    }

    func testGeneralSnapshotRoundTripAndClamping() {
        let id = "test-\(UUID().uuidString)"
        let settings = GeneralWallpaperSettings.shared
        defer { settings.reset(id) }

        settings.setAlignment(.cover, id)
        settings.setPosition(140, id)
        settings.setBrightness(-20, id)
        settings.setContrast(175, id)
        settings.setSaturation(42, id)

        let snapshot = settings.snapshot(id)
        XCTAssertEqual(snapshot.alignment, GeneralWallpaperSettings.Alignment.cover.rawValue)
        XCTAssertEqual(snapshot.position, 100)
        XCTAssertEqual(snapshot.brightness, 0)
        XCTAssertEqual(snapshot.contrast, 175)
        XCTAssertEqual(snapshot.saturation, 42)

        settings.reset(id)
        settings.apply(snapshot, to: id)
        XCTAssertEqual(settings.snapshot(id), snapshot)
    }

    @MainActor
    func testPresetJSONRestoresGeneralAndCustomProperties() throws {
        let id = "test-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = """
        {
          "title": "Preset Test",
          "type": "scene",
          "general": {
            "properties": {
              "enabled": { "type": "bool", "text": "Enabled", "value": true, "order": 1 },
              "amount": { "type": "slider", "text": "Amount", "value": 0.25, "min": 0, "max": 1, "order": 2 }
            }
          }
        }
        """
        try Data(project.utf8).write(to: folder.appendingPathComponent("project.json"))
        let item = WallpaperItem(id: id, folderURL: folder, title: "Preset Test", type: .scene,
                                 fileName: nil, previewName: nil, tags: [])
        let propertyStore = WallpaperPropertyStore.shared
        let general = GeneralWallpaperSettings.shared
        let presetStore = WallpaperPresetStore.shared
        defer {
            for preset in presetStore.presets(for: id) { presetStore.delete(preset) }
            propertyStore.reset(forID: id, folderURL: folder)
            general.reset(id)
            try? FileManager.default.removeItem(at: folder)
        }

        propertyStore.setValue(.bool(false), forID: id, propertyKey: "enabled")
        propertyStore.setValue(.number(0.75), forID: id, propertyKey: "amount")
        general.setAlignment(.fit, id)
        general.setVolume(31, id)

        let saved = presetStore.saveCurrent(name: "测试预设", item: item)
        let exported = try presetStore.exportData(saved)

        propertyStore.setValue(.bool(true), forID: id, propertyKey: "enabled")
        propertyStore.setValue(.number(0.1), forID: id, propertyKey: "amount")
        general.setAlignment(.stretch, id)
        general.setVolume(99, id)

        let imported = try presetStore.importData(exported, for: item)
        try presetStore.apply(imported, to: item)

        let props = propertyStore.properties(forID: id, folderURL: folder)
        let enabled = try XCTUnwrap(props.first { $0.id == "enabled" })
        let amount = try XCTUnwrap(props.first { $0.id == "amount" })
        XCTAssertEqual(propertyStore.value(forID: id, property: enabled, folderURL: folder), .bool(false))
        XCTAssertEqual(propertyStore.value(forID: id, property: amount, folderURL: folder), .number(0.75))
        XCTAssertEqual(general.alignment(id), .fit)
        XCTAssertEqual(general.volume(id), 31)
    }
}
