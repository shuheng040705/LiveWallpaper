import XCTest
@testable import LiveWallpaper

final class PreferencesStorePathTests: XCTestCase {
    func testDefaultCandidatesUseTheSuppliedHomeDirectory() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        let paths = PreferencesStore.defaultLibraryCandidates(homeDirectory: home).map(\.path)

        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("/Users/tester/") })
        XCTAssertFalse(paths.contains { $0.contains("/Users/a55555/") })
    }

    func testDetectionFallsBackToExistingNativeSteamDirectory() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LiveWallpaper-PreferencesStorePathTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let native = PreferencesStore.defaultLibraryCandidates(homeDirectory: home)[1]
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)

        let detected = PreferencesStore.detectedDefaultLibraryRoot(homeDirectory: home)

        XCTAssertEqual(detected.standardizedFileURL, native.standardizedFileURL)
    }
}
