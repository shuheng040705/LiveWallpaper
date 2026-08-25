import XCTest
@testable import LiveWallpaper

final class VideoPlaybackResolverTests: XCTestCase {
    func testCacheNameIsStableAndFilesystemSafe() {
        XCTAssertEqual(
            VideoPlaybackResolver.cacheFileName(
                itemID: "3773793721/bad:name",
                fileSize: 11_622_029,
                modified: 1_753_900_000.9
            ),
            "3773793721_bad_name-11622029-1753900000.mp4"
        )
    }

    func testCacheNameChangesWhenSourceChanges() {
        let original = VideoPlaybackResolver.cacheFileName(
            itemID: "3773793721", fileSize: 100, modified: 200
        )
        XCTAssertNotEqual(
            original,
            VideoPlaybackResolver.cacheFileName(
                itemID: "3773793721", fileSize: 101, modified: 200
            )
        )
        XCTAssertNotEqual(
            original,
            VideoPlaybackResolver.cacheFileName(
                itemID: "3773793721", fileSize: 100, modified: 201
            )
        )
    }
}
