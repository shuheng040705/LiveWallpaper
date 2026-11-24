import XCTest
@testable import LiveWallpaper

final class WorkshopInstallCacheTests: XCTestCase {
    func testOfflineRepairOnlyRemovesMissingInstalledItemsAndKeepsResumeData() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let workshop = root.appendingPathComponent("steamapps/workshop")
        try fm.createDirectory(at: workshop.appendingPathComponent("content/431960/200"), withIntermediateDirectories: true)
        let downloads = workshop.appendingPathComponent("downloads")
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let partial = downloads.appendingPathComponent("state_431960_431960_300.patch")
        let data = Data("resume".utf8)
        try data.write(to: partial)
        let manifest = workshop.appendingPathComponent("appworkshop_431960.acf")
        let text = """
        "AppWorkshop"
        {
            "WorkshopItemsInstalled"
            {
                "100"
                {
                    "size" "42"
                }
                "200"
                {
                    "size" "20"
                }
            }
            "WorkshopItemDetails"
            {
                "100"
                {
                    "manifest" "11"
                }
                "200"
                {
                    "manifest" "22"
                }
                "300"
                {
                    "manifest" "33"
                    "BytesDownloaded" "5"
                }
            }
            "Unknown" "preserve"
        }
        """.replacingOccurrences(of: "\n", with: "\r\n")
        try text.write(to: manifest, atomically: true, encoding: .utf8)
        try WorkshopInstallCache.repairManifest(in: root, appID: "431960")
        let migrated = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertFalse(CrossOverSteamClient.parseManifestItemState(migrated, id: "100").isKnown)
        XCTAssertTrue(CrossOverSteamClient.parseManifestItemState(migrated, id: "200").isInstalledRecord)
        XCTAssertTrue(CrossOverSteamClient.parseManifestItemState(migrated, id: "300").isKnown)
        XCTAssertTrue(migrated.contains("\"BytesDownloaded\" \"5\""))
        XCTAssertTrue(migrated.contains("\"Unknown\" \"preserve\""))
        XCTAssertEqual(try Data(contentsOf: partial), data)
        try WorkshopInstallCache.repairManifest(in: root, appID: "431960")
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), migrated)
    }

    func testLibraryAndSteamHaveIndependentWritableFilesAfterInstallation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("steam-cache")
        let target = root.appendingPathComponent("library-item")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let file = "scene.pkg"
        let baseline = Data([1, 2, 3])
        try baseline.write(to: source.appendingPathComponent(file))
        try WorkshopInstallCache.copyToLibrary(from: source.path, to: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(file)), baseline)
        try Data([4]).write(to: target.appendingPathComponent(file))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(file)), baseline)
    }
}
