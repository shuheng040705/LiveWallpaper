import XCTest
@testable import LiveWallpaper

final class CrossOverSteamClientTests: XCTestCase {
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-CrossOverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    func testManifestRequiresInstalledManifestToMatchLatestManifest() {
        let text = #"""
        "AppWorkshop"
        {
            "WorkshopItemsInstalled"
            {
                "3713659808"
                {
                    "size" "6264363"
                    "manifest" "6566464675599861317"
                }
            }
            "WorkshopItemDetails"
            {
                "3713659808"
                {
                    "manifest" "6566464675599861317"
                    "latest_manifest" "6566464675599861317"
                }
                "9999999999"
                {
                    "manifest" "1"
                    "latest_manifest" "2"
                }
            }
        }
        """#

        let current = CrossOverSteamClient.parseManifestItemState(text, id: "3713659808")
        XCTAssertTrue(current.isKnown)
        XCTAssertTrue(current.recordIsCurrent)
        XCTAssertEqual(current.installedSize, 6_264_363)

        let pending = CrossOverSteamClient.parseManifestItemState(text, id: "9999999999")
        XCTAssertTrue(pending.isKnown)
        XCTAssertFalse(pending.isInstalledRecord)
        XCTAssertFalse(pending.recordIsCurrent)
        XCTAssertFalse(CrossOverSteamClient.parseManifestItemState(text, id: "1234567890").isKnown)
    }

    func testTruncatedKeyValuesBlockIsRejected() {
        XCTAssertNil(CrossOverSteamClient.namedBlock("WorkshopItemsInstalled", in:
            #""WorkshopItemsInstalled" { "123" { "manifest" "1" }"#))
    }

    func testContextDerivesMatchingBottleHelperAndRecentSteamID() throws {
        let home = try temporaryDirectory()
        let steam = home.appendingPathComponent(
            "Library/Application Support/CrossOver/Bottles/TestBottle/drive_c/Program Files (x86)/Steam",
            isDirectory: true
        )
        let library = steam.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data().write(to: steam.appendingPathComponent("steam.exe"))
        let config = steam.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try #""users" { "76561199240849252" { "MostRecent" "1" } }"#
            .data(using: .utf8)!.write(to: config.appendingPathComponent("loginusers.vdf"))

        let helperContents = home.appendingPathComponent(
            "Applications/CrossOver/TestBottle/Steam.app/Contents",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: helperContents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.codeweavers.test.steam",
            "CXHelperAppBottleName": "TestBottle"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: helperContents.appendingPathComponent("Info.plist"))

        let context = CrossOverSteamClient.context(for: library, homeDirectory: home)
        XCTAssertEqual(context?.bottleName, "TestBottle")
        XCTAssertEqual(context?.steamRoot.standardizedFileURL, steam.standardizedFileURL)
        XCTAssertEqual(context?.helperBundleIdentifier, "com.codeweavers.test.steam")
        XCTAssertEqual(context?.steamID64, "76561199240849252")
    }

    func testLocalProbeAndContentSizeRejectHalfInstalledWallpaper() throws {
        let folder = try temporaryDirectory()
        XCTAssertEqual(LocalWallpaperProbe.state(at: folder), .incomplete)

        try #"{"type":"Video","file":"main.mp4"}"#
            .data(using: .utf8)!.write(to: folder.appendingPathComponent("project.json"))
        XCTAssertEqual(LocalWallpaperProbe.state(at: folder), .incomplete)

        try Data(repeating: 7, count: 32).write(to: folder.appendingPathComponent("main.mp4"))
        try Data(repeating: 0, count: 9).write(to: folder.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(LocalWallpaperProbe.state(at: folder), .ready)
        let expected = Int64(32 + Data(#"{"type":"Video","file":"main.mp4"}"#.utf8).count)
        XCTAssertEqual(CrossOverSteamClient.directoryContentSize(folder), expected)
    }

    func testCompletionRequiresMatchingContentSize() {
        let state = CrossOverSteamClient.ManifestItemState(
            isKnown: true,
            isInstalledRecord: true,
            installedManifest: "10",
            latestManifest: "10",
            installedSize: 100
        )
        XCTAssertFalse(CrossOverSteamClient.Observation(
            manifestState: state, projectExists: true, contentSize: 99
        ).isComplete)
        XCTAssertTrue(CrossOverSteamClient.Observation(
            manifestState: state, projectExists: true, contentSize: 100
        ).isComplete)
    }
}
