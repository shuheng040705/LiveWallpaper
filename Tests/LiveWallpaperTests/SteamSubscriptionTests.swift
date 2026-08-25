import XCTest
@testable import LiveWallpaper

final class SteamSubscriptionTests: XCTestCase {
    private func cookie(name: String, value: String, domain: String = ".steamcommunity.com") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value,
            .secure: "TRUE"
        ])!
    }

    func testAuthenticatedSessionRequiresBothCommunityCookies() {
        XCTAssertNil(SteamSubscription.authenticatedSession(from: [
            cookie(name: "sessionid", value: "abc")
        ]))
        XCTAssertNil(SteamSubscription.authenticatedSession(from: [
            cookie(name: "sessionid", value: "abc", domain: ".steampowered.com"),
            cookie(name: "steamLoginSecure", value: "secure", domain: ".steampowered.com")
        ]))

        let session = SteamSubscription.authenticatedSession(from: [
            cookie(name: "sessionid", value: "abc"),
            cookie(name: "steamLoginSecure_7656119", value: "secure")
        ])
        XCTAssertEqual(session?.sessionID, "abc")
        XCTAssertEqual(session?.cookies.count, 2)
    }

    func testSecureCookieExposesOnlyURLDecodedSteamID() {
        XCTAssertEqual(
            SteamSubscription.steamID64(fromSecureCookieValue: "76561199240849252%7C%7Csecret-token"),
            "76561199240849252"
        )
        XCTAssertNil(SteamSubscription.steamID64(fromSecureCookieValue: "not-a-steam-id%7C%7Csecret"))
    }

    func testSubscribeResponseClassification() {
        XCTAssertEqual(
            SteamSubscription.classifySubscribeResponse(
                statusCode: 200,
                data: Data(#"{"success":1}"#.utf8),
                error: nil
            ),
            .success("已订阅")
        )
        XCTAssertEqual(
            SteamSubscription.classifySubscribeResponse(
                statusCode: 200,
                data: Data(#"{"success":15}"#.utf8),
                error: nil
            ),
            .failure("Steam 拒绝订阅（错误码 15）")
        )
    }

    func testResponseClassificationSeparatesAuthFromNetworkFailures() {
        let success = Data(#"{"success":1}"#.utf8)
        XCTAssertEqual(SteamSubscription.classifyResponse(statusCode: 200, data: success, error: nil),
                       .success("已取消订阅"))

        let expired = Data(#"{"success":21}"#.utf8)
        XCTAssertEqual(SteamSubscription.classifyResponse(statusCode: 200, data: expired, error: nil),
                       .authenticationRequired)
        XCTAssertEqual(SteamSubscription.classifyResponse(statusCode: 403, data: nil, error: nil),
                       .failure("取消订阅失败（HTTP 403），本地文件未删除"))

        let denied = Data(#"{"success":8}"#.utf8)
        XCTAssertEqual(SteamSubscription.classifyResponse(statusCode: 200, data: denied, error: nil),
                       .failure("Steam 拒绝取消订阅（错误码 8），本地文件未删除"))

        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        guard case .failure(let message) =
                SteamSubscription.classifyResponse(statusCode: 0, data: nil, error: network) else {
            return XCTFail("网络错误应保留为普通失败")
        }
        XCTAssertTrue(message.contains("本地文件未删除"))
    }

    func testKeychainSnapshotKeepsOnlyCommunityAuthenticationCookies() throws {
        let cookies = [
            cookie(name: "sessionid", value: "csrf"),
            cookie(name: "steamLoginSecure_7656119", value: "secure"),
            cookie(name: "browserid", value: "browser"),
            cookie(name: "preferences", value: "not-needed"),
            cookie(name: "sessionid", value: "wrong-domain", domain: ".example.com"),
        ]
        let data = try XCTUnwrap(SteamWebCredentialVault.encodeSnapshot(cookies: cookies))
        let stored = try JSONDecoder().decode([SteamWebCredentialVault.StoredCookie].self, from: data)

        XCTAssertEqual(Set(stored.map(\.name)), Set(["sessionid", "steamLoginSecure_7656119", "browserid"]))
        XCTAssertFalse(stored.contains { $0.value == "not-needed" || $0.value == "wrong-domain" })
    }

    func testRestoredSessionCookieGetsLongLocalRetentionWithoutChangingToken() throws {
        let cookies = [
            cookie(name: "sessionid", value: "csrf-token"),
            cookie(name: "steamLoginSecure", value: "76561199240849252%7C%7Cserver-token"),
        ]
        let data = try XCTUnwrap(SteamWebCredentialVault.encodeSnapshot(cookies: cookies))
        let now = Date()
        let restored = SteamWebCredentialVault.decodeSnapshot(data, now: now)
        let auth = try XCTUnwrap(SteamSubscription.authenticatedSession(from: restored))

        XCTAssertEqual(auth.sessionID, "csrf-token")
        XCTAssertTrue(auth.cookies.contains { $0.value.contains("server-token") })
        XCTAssertTrue(auth.cookies.allSatisfy {
            ($0.expiresDate ?? now) > now.addingTimeInterval(360 * 24 * 60 * 60)
        })
    }

    func testAuthenticatedSessionDropsDuplicateAuthenticationCookies() throws {
        let cookies = [
            cookie(name: "sessionid", value: "canonical"),
            HTTPCookie(properties: [.domain: ".steamcommunity.com", .path: "/detail", .name: "sessionid", .value: "stale"])!,
            cookie(name: "steamLoginSecure", value: "76561199240849252%7C%7Cnew"),
            cookie(name: "steamLoginSecure_old", value: "76561199240849252%7C%7Cold"),
            cookie(name: "browserid", value: "browser")
        ]
        let auth = try XCTUnwrap(SteamSubscription.authenticatedSession(from: cookies))
        XCTAssertEqual(auth.sessionID, "canonical")
        XCTAssertEqual(auth.cookies.count, 2)
        XCTAssertEqual(auth.cookies.filter { $0.name == "sessionid" }.count, 1)
        XCTAssertEqual(auth.cookies.filter { $0.name == "steamLoginSecure" }.count, 1)
    }

    func testVaultCanRetainRememberDeviceCookiesWithoutRejectedAuthPair() throws {
        let data = try XCTUnwrap(SteamWebCredentialVault.encodeSnapshot(cookies: [
            cookie(name: "steamRememberLogin", value: "remember"),
            cookie(name: "browserid", value: "browser")
        ]))
        let restored = SteamWebCredentialVault.decodeSnapshot(data)
        XCTAssertEqual(Set(restored.map(\.name)), Set(["steamRememberLogin", "browserid"]))
        XCTAssertNil(SteamSubscription.authenticatedSession(from: restored))
    }
}
