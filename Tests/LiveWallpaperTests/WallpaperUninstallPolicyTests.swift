import XCTest
@testable import LiveWallpaper

final class WallpaperUninstallPolicyTests: XCTestCase {
    func testWorkshopIdentityRequiresNumericSteamID() {
        XCTAssertTrue(WallpaperUninstallPolicy.isSteamWorkshopID("3773793721"))
        XCTAssertFalse(WallpaperUninstallPolicy.isSteamWorkshopID("my-local-wallpaper"))
        XCTAssertFalse(WallpaperUninstallPolicy.isSteamWorkshopID("12345"))
        XCTAssertFalse(WallpaperUninstallPolicy.isSteamWorkshopID("123456a"))
    }

    func testSteamFailureNeverAuthorizesAutomaticLocalRemoval() {
        XCTAssertFalse(
            WallpaperUninstallPolicy.mayRemoveLocalFiles(
                requiresSteamUnsubscribe: true,
                unsubscribeSucceeded: false
            )
        )
        XCTAssertFalse(
            WallpaperUninstallPolicy.mayRemoveLocalFiles(
                requiresSteamUnsubscribe: true,
                unsubscribeSucceeded: nil
            )
        )
    }

    func testNumericDownloadWithoutSubscriptionEvidenceDoesNotRequireWebAuthorization() {
        XCTAssertFalse(
            WallpaperUninstallPolicy.requiresSteamUnsubscribe(
                itemID: "3776298580",
                requested: true,
                knownSubscribed: false
            )
        )
        XCTAssertTrue(
            WallpaperUninstallPolicy.requiresSteamUnsubscribe(
                itemID: "3776298580",
                requested: true,
                knownSubscribed: true
            )
        )
    }

    func testLocalWallpaperAndSuccessfulUnsubscribeCanBeRemoved() {
        XCTAssertTrue(
            WallpaperUninstallPolicy.mayRemoveLocalFiles(
                requiresSteamUnsubscribe: false,
                unsubscribeSucceeded: nil
            )
        )
        XCTAssertTrue(
            WallpaperUninstallPolicy.mayRemoveLocalFiles(
                requiresSteamUnsubscribe: true,
                unsubscribeSucceeded: true
            )
        )
    }

    func testOnlyDirectChildrenOfLibraryRootAreSafeRemovalTargets() {
        let root = URL(fileURLWithPath: "/tmp/live-wallpaper-library", isDirectory: true)
        XCTAssertTrue(
            WallpaperUninstallPolicy.isSafeLibraryChild(
                folderURL: root.appendingPathComponent("3773793721", isDirectory: true),
                libraryRoot: root
            )
        )
        XCTAssertFalse(
            WallpaperUninstallPolicy.isSafeLibraryChild(folderURL: root, libraryRoot: root)
        )
        XCTAssertFalse(
            WallpaperUninstallPolicy.isSafeLibraryChild(
                folderURL: root.appendingPathComponent("3773793721/scene", isDirectory: true),
                libraryRoot: root
            )
        )
        XCTAssertFalse(
            WallpaperUninstallPolicy.isSafeLibraryChild(
                folderURL: URL(fileURLWithPath: "/tmp/not-the-library/3773793721"),
                libraryRoot: root
            )
        )
    }
}
