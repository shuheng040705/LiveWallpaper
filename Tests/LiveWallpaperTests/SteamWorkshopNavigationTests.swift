import XCTest
@testable import LiveWallpaper

final class SteamWorkshopNavigationTests: XCTestCase {
    @MainActor
    func testOnlySteamHTTPSOriginsStayInWorkshop() throws {
        let accepted = [
            "https://steamcommunity.com/sharedfiles/filedetails/?id=3840929200",
            "https://steamcommunity.com:443/login/home/",
            "https://login.steampowered.com/jwt/finalizelogin",
        ]
        let rejected = [
            "https://steamcommunity.com.example.org/workshop/",
            "https://othersteamcommunity.com/workshop/",
            "https://steamcommunity.com@outside.example/",
            "https://user@steamcommunity.com/",
            "https://steamcommunity.com:444/workshop/",
            "http://steamcommunity.com/workshop/",
            "file:///tmp/steamcommunity.com",
        ]
        for item in accepted {
            XCTAssertTrue(SteamWorkshopBrowser.isSteamPage(try XCTUnwrap(URL(string: item))), item)
        }
        for item in rejected {
            XCTAssertFalse(SteamWorkshopBrowser.isSteamPage(try XCTUnwrap(URL(string: item))), item)
        }
    }
}
