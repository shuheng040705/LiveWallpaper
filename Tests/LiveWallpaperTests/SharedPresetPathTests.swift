import Foundation
import XCTest
@testable import LiveWallpaper

final class SharedPresetPathTests: XCTestCase {
    func testDirectoriesAndFilesKeepTheirDeclaredTypesAndStayInsideThePreset() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let item = root.appendingPathComponent("100")
        let album = item.appendingPathComponent("files/album")
        try fm.createDirectory(at: album, withIntermediateDirectories: true)
        let clip = album.appendingPathComponent("song.webm")
        try Data([1]).write(to: clip)
        let external = root.appendingPathComponent("external")
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: album.appendingPathComponent("elsewhere"), withDestinationURL: external)
        let folderPath = "./files//./album/"
        let clipPath = "./files//album/./song.webm"
        let project: [String: Any] = [
            "dependency": "200",
            "preset": ["album": folderPath, "clip": clipPath, "wrongFile": folderPath, "wrongDirectory": clipPath]
        ]
        let descriptor = item.appendingPathComponent("project.json")
        try JSONSerialization.data(withJSONObject: project).write(to: descriptor)
        let preset = try XCTUnwrap(SharedWallpaperPreset(project: project, folder: item))
        let general = preset.general(using: ["general": ["properties": [
            "album": ["type": "directory"], "clip": ["type": "file"],
            "wrongFile": ["type": "file"], "wrongDirectory": ["type": "directory"]
        ]]])
        let props = try XCTUnwrap(general["properties"] as? [String: [String: Any]])
        let url = try XCTUnwrap((props["album"]?["value"] as? String).flatMap(URL.init(string:)))
        XCTAssertEqual(url.path(percentEncoded: false), "/" + WebRenderer.presetFilesPrefix + "files/album/")
        XCTAssertTrue((props["clip"]?["value"] as? String)?.hasSuffix("/files/album/song.webm") == true)
        XCTAssertEqual(props["wrongFile"]?["value"] as? String, "")
        XCTAssertEqual(props["wrongDirectory"]?["value"] as? String, "")
        XCTAssertEqual(LocalWallpaperProbe.state(at: item), .ready)
        XCTAssertEqual(preset.singleVideoURL?.lastPathComponent, clip.lastPathComponent)
        XCTAssertNil(SharedWallpaperPreset.file(folderPath, in: item))
        XCTAssertNil(SharedWallpaperPreset.resource("../external", in: item))
        XCTAssertNil(SharedWallpaperPreset.resource(external.path, in: item))
        XCTAssertNil(SharedWallpaperPreset.resource("files/album/elsewhere", in: item))
        try JSONSerialization.data(withJSONObject: [
            "dependency": "200", "preset": ["album": "files/album/elsewhere"]
        ]).write(to: descriptor)
        XCTAssertEqual(LocalWallpaperProbe.state(at: item), .incomplete)
    }
}
