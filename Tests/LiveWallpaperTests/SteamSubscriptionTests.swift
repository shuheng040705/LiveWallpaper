import XCTest
import WebKit
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
    @MainActor
    func testStartupAndPollingUseWebKitOnlyAndKeepSessionCookies() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
              loadSnapshot: { XCTFail("Automatic checks must not open the keychain"); return nil },
              saveSnapshot: { _ in XCTFail("Automatic checks must not write the keychain"); return false })
        let empty = await withCheckedContinuation { session.refresh(completion: $0.resume(returning:)) }
        XCTAssertFalse(empty)
        for item in [cookie(name: "sessionid", value: "csrf"), cookie(name: "steamLoginSecure", value: "new")] {
            await browser.httpCookieStore.setCookie(item)
        }
        let loggedIn = await withCheckedContinuation { session.refresh(completion: $0.resume(returning:)) }
        XCTAssertTrue(loggedIn)
        let stored = await browser.httpCookieStore.allCookies()
        XCTAssertEqual(stored.count, 2)
        XCTAssertTrue(stored.allSatisfy { $0.isSecure && $0.expiresDate != nil })
        XCTAssertFalse(session.isChecking)
    }

    @MainActor
    func testExplicitRestoreMergesMissingCookiesAndSurvivesASlowKeychain() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let snapshot = [cookie(name: "sessionid", value: "saved"), cookie(name: "steamLoginSecure", value: "old")]
        await browser.httpCookieStore.setCookie(cookie(name: "steamLoginSecure", value: "new"))
        let arrived = expectation(description: "Worker opened the saved item")
        let release = DispatchSemaphore(value: 0)
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: {
                XCTAssertFalse(Thread.isMainThread)
                arrived.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 4), .success)
                return snapshot
            }, saveSnapshot: { _ in XCTFail("Restore must not overwrite a valid saved item"); return false })
        let restored = Task { await session.restoreForLogin() }
        await fulfillment(of: [arrived], timeout: 2)
        // A silent application refresh returns even while the user is considering an ACL prompt.
        let passive = await withCheckedContinuation { session.refresh(completion: $0.resume(returning:)) }
        XCTAssertFalse(passive)
        release.signal()
        let ok = await restored.value
        XCTAssertTrue(ok)
        let merged = await browser.httpCookieStore.allCookies()
        XCTAssertEqual(SteamSubscription.authenticatedSession(from: merged)?.sessionID, "saved")
        XCTAssertEqual(SteamSubscription.communityLoginCookie(in: merged)?.value, "new")
    }

    @MainActor
    func testLogoutDuringExplicitRestoreDiscardsResultAndRetiresSnapshot() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let snapshot = [cookie(name: "sessionid", value: "old"), cookie(name: "steamLoginSecure", value: "old")]
        let arrived = expectation(description: "Worker started")
        let release = DispatchSemaphore(value: 0)
        let old = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: {
                arrived.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 4), .success)
                return snapshot
            }, saveSnapshot: { _ in XCTFail(); return false })
        let work = Task { await old.restoreForLogin() }
        await fulfillment(of: [arrived], timeout: 2)
        old.updateFromWebsite(cookies: [], afterLogout: true)
        release.signal()
        let restored = await work.value
        XCTAssertFalse(restored)
        let purge = expectation(description: "Remove rejected credentials on explicit access")
        let fresh = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: { snapshot }, saveSnapshot: { cookies in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertTrue(cookies.isEmpty)
                purge.fulfill()
                return false  // a failed deletion must not make old credentials eligible again
            })
        let afterRelaunch = await fresh.restoreForLogin()
        XCTAssertFalse(afterRelaunch)
        await fulfillment(of: [purge], timeout: 2)
        let contents = await browser.httpCookieStore.allCookies()
        XCTAssertTrue(contents.isEmpty)
    }

    @MainActor
    func testDeniedLegacyItemDoesNotPreventWebLoginOrCauseSecondPrompt() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: { nil }, saveSnapshot: { _ in XCTFail("Retry after explicit denial"); return false })
        let restored = await session.restoreForLogin()
        XCTAssertFalse(restored)
        await browser.httpCookieStore.setCookie(cookie(name: "sessionid", value: "csrf"))
        await browser.httpCookieStore.setCookie(cookie(name: "steamLoginSecure", value: "web"))
        let ok = await withCheckedContinuation { session.refresh(completion: $0.resume(returning:)) }
        XCTAssertTrue(ok)
        session.rememberLogin()
    }
    @MainActor
    func testFailedRequestsOnlyClearRejectedLoginAndAllowExplicitBackupOfNewLogin() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let csrf = cookie(name: "sessionid", value: "session-id")
        let old = cookie(name: "steamLoginSecure", value: "old")
        let new = cookie(name: "steamLoginSecure", value: "new")
        let saved = expectation(description: "Explicit login backed up")
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: { XCTFail("Logout must not query the keychain"); return nil },
            saveSnapshot: { cookies in
                XCTAssertFalse(Thread.isMainThread)
                XCTAssertEqual(SteamSubscription.communityLoginCookie(in: cookies)?.value, "new")
                saved.fulfill()
                return true
            })
        for item in [csrf, new, cookie(name: "browserid", value: "device")] { await browser.httpCookieStore.setCookie(item) }
        session.noteRejected(try XCTUnwrap(SteamSubscription.authenticatedSession(from: [csrf, old])))
        await withCheckedContinuation { continuation in session.clearAuthenticationCookies { continuation.resume() } }
        let newer = await browser.httpCookieStore.allCookies()
        XCTAssertEqual(SteamSubscription.communityLoginCookie(in: newer)?.value, "new")
        session.rememberLogin()
        await fulfillment(of: [saved], timeout: 2)

        session.noteRejected(try XCTUnwrap(SteamSubscription.authenticatedSession(from: [csrf, new])))
        session.noteRejected(try XCTUnwrap(SteamSubscription.authenticatedSession(from: [csrf, old])))
        await withCheckedContinuation { continuation in session.clearAuthenticationCookies { continuation.resume() } }
        let remaining = await browser.httpCookieStore.allCookies()
        XCTAssertEqual(remaining.map(\.name), ["browserid"])
    }
}
