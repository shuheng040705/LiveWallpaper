import XCTest
import Combine
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

    func testProxyErrorsAndCommunityPagesWithLoginLinksKeepAuthorization() {
        let html = Data("<html><a href='/login/'>Login</a></html>".utf8)
        let workshop = URL(string: "https://steamcommunity.com/sharedfiles/subscribe")
        for code in [200, 403, 502, 503] {
            guard case .failure = SteamSubscription.classifySubscribeResponse(
                statusCode: code, data: html, error: nil, finalURL: workshop
            ) else { return XCTFail("Unexpected authorization loss on HTTP \(code)") }
        }
        XCTAssertEqual(SteamSubscription.classifySubscribeResponse(
            statusCode: 200, data: html, error: nil, finalURL: URL(string: "https://steamcommunity.com/login/home/")
        ), .authenticationRequired)
        guard case .failure = SteamSubscription.classifySubscribeResponse(
            statusCode: 200, data: html, error: nil, finalURL: URL(string: "https://example.org/login/")
        ) else { return XCTFail("Only official login redirects confirm expiry") }
    }

    func testSnapshotHonorsExpiryProvidedBySteam() throws {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        func persistent(_ name: String, _ expiration: Date) throws -> HTTPCookie {
            try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".steamcommunity.com", .path: "/", .name: name, .value: "fixture",
                .secure: "TRUE", .expires: expiration
            ]))
        }
        let data = try XCTUnwrap(SteamWebCredentialVault.encodeSnapshot(cookies: [
            try persistent("steamLoginSecure", now.addingTimeInterval(-10)), try persistent("browserid", future)
        ]))
        let restored = SteamWebCredentialVault.decodeSnapshot(data, now: now)
        XCTAssertEqual(restored.map(\.name), ["browserid"])
        XCTAssertEqual(try XCTUnwrap(restored.first?.expiresDate).timeIntervalSince(future), 0, accuracy: 1)
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
    func testWorkshopRelaunchRestoresOnceAndRemembersSubsequentCookieRotation() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let snapshot = [cookie(name: "sessionid", value: "csrf"), cookie(name: "steamLoginSecure", value: "saved")]
        let read = expectation(description: "One noninteractive query for the first navigation and native request")
        let rotation = expectation(description: "Cookie observer saves Steam's rotated login without a navigation")
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: { XCTFail("Unexpected interactive access"); return nil },
            saveSnapshot: { _ in XCTFail("Unexpected interactive write"); return false },
            loadSilently: { read.fulfill(); return snapshot },
            saveSilently: { cookies in
                if SteamSubscription.communityLoginCookie(in: cookies)?.value == "rotated" { rotation.fulfill() }
                return true
            })
        async let page: Void = session.prepareForWorkshop()
        let restored = await withCheckedContinuation { session.authenticatedSession(completion: $0.resume(returning:)) }
        await page
        XCTAssertEqual(SteamSubscription.communityLoginCookie(in: restored?.cookies ?? [])?.value, "saved")
        let updated = try XCTUnwrap(HTTPCookie(properties: [
            .domain: ".steamcommunity.com", .path: "/", .name: "steamLoginSecure", .value: "rotated",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600)
        ]))
        await browser.httpCookieStore.setCookie(updated)
        await fulfillment(of: [read, rotation], timeout: 4)

        // Also cover Steam removing its login via XHR without a main-frame
        // logout navigation. A subsequent app instance must not replay it.
        let signedOut = expectation(description: "Cookie removal observed")
        let observer = session.$isAuthenticated.removeDuplicates().dropFirst().sink { authenticated in
            if !authenticated { signedOut.fulfill() }
        }
        await browser.httpCookieStore.delete(updated)
        await fulfillment(of: [signedOut], timeout: 4)
        observer.cancel()
        let relaunched = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSilently: { XCTFail("Removed login should stay retired"); return snapshot })
        await relaunched.prepareForWorkshop()
        XCTAssertFalse(relaunched.isAuthenticated)
    }

    @MainActor
    func testMissingCSRFRecoversAfterReconnectWithoutRequestingLogin() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let account = "76561198000000001"
        let login = cookie(name: "steamLoginSecure", value: account + "%7C%7Cfixture")
        let csrf = cookie(name: "sessionid", value: "issued-by-community")
        await browser.httpCookieStore.setCookie(login)
        var attempts = 0
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSnapshot: { XCTFail("Unexpected interactive access"); return nil }, fetchSessionID: { current in
                XCTAssertEqual(current.value, login.value)
                attempts += 1
                return attempts == 1 ? nil : csrf
            })
        let offline = await withCheckedContinuation { session.authenticatedSession(completion: $0.resume(returning:)) }
        XCTAssertNil(offline)
        XCTAssertTrue(session.isAuthenticated)
        XCTAssertEqual(session.steamID64, account)
        let recovered = await withCheckedContinuation { session.authenticatedSession(completion: $0.resume(returning:)) }
        XCTAssertEqual(recovered?.sessionID, csrf.value)
        XCTAssertEqual(recovered?.steamID64, account)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testRememberedWebsiteRecoveryRetriesAfterReconnectAndSharesTheFirstNavigation() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let suite = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = "76561198000000001"
        let login = cookie(name: "steamLoginSecure", value: account + "%7C%7Cfixture")
        let csrf = cookie(name: "sessionid", value: "csrf")
        defaults.set(account, forKey: "steamWebLastAuthenticatedAccount")
        let started = expectation(description: "Official website navigation started")
        var finish: CheckedContinuation<Bool, Never>?
        var attempts = 0
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults, loadWorkshop: {
            attempts += 1
            if attempts == 1 {
                return await withCheckedContinuation { finish = $0; started.fulfill() }
            }
            await browser.httpCookieStore.setCookie(login)
            await browser.httpCookieStore.setCookie(csrf)
            return true
        })
        let launch = Task { await session.resumeRememberedSession() }
        await fulfillment(of: [started], timeout: 3)
        await session.prepareForWorkshop() // Visible navigation can start while the site is offline.
        let settings = Task { await session.resumeRememberedSession() }
        await Task.yield()
        finish?.resume(returning: false)
        await launch.value
        await settings.value
        XCTAssertTrue(session.websiteUnavailable)
        XCTAssertFalse(session.isChecking)
        let auth = await withCheckedContinuation { session.authenticatedSession(completion: $0.resume(returning:)) }
        XCTAssertEqual(auth?.steamID64, account)
        XCTAssertFalse(session.websiteUnavailable)
        XCTAssertEqual(attempts, 2)
        await session.resumeRememberedSession()
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testCommunityCanRenewOnNaturalCookieExpiry() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let suite = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let renewed = expectation(description: "Steam can renew an expired access cookie")
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadWorkshop: { renewed.fulfill(); return true })
        await session.prepareForWorkshop()
        let account = "76561198000000001%7C%7Cfixture"
        let previous = try XCTUnwrap(HTTPCookie(properties: [
            .name: "steamLoginSecure", .value: account, .domain: ".steamcommunity.com", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(-1)
        ]))
        let csrf = try XCTUnwrap(HTTPCookie(properties: [
            .name: "sessionid", .value: "csrf", .domain: ".steamcommunity.com", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(3600)
        ]))
        session.updateFromWebsite(cookies: [csrf, previous], afterLogout: false)
        // Deliver WebKit's removal notification after that observed expiry.
        session.cookiesDidChange(in: browser.httpCookieStore)
        await fulfillment(of: [renewed], timeout: 2)
    }

    @MainActor
    func testNewInstallationAndRevokedSessionSkipWebsiteRenewal() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let suite = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func instance() -> SteamWebSession {
            SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
                loadWorkshop: { XCTFail("Must not reauthenticate automatically"); return false })
        }
        let fresh = instance()
        await fresh.resumeRememberedSession()
        let cookies = [cookie(name: "sessionid", value: "csrf"),
                       cookie(name: "steamLoginSecure", value: "76561198000000001%7C%7Cfixture")]
        for item in cookies { await browser.httpCookieStore.setCookie(item) }
        let auth = await withCheckedContinuation { fresh.authenticatedSession(completion: $0.resume(returning:)) }
        fresh.noteRejected(try XCTUnwrap(auth))
        await withCheckedContinuation { continuation in fresh.clearAuthenticationCookies { continuation.resume() } }
        let next = instance()
        await next.resumeRememberedSession()
        XCTAssertFalse(next.isAuthenticated)
    }

    @MainActor
    func testWorkshopRelaunchHonorsExplicitLogoutWithoutOpeningTheKeychain() async throws {
        let browser = WKWebsiteDataStore.nonPersistent()
        let domain = "SteamSessionTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SteamWebSession(cookieStore: { browser.httpCookieStore }, defaults: defaults,
            loadSilently: { XCTFail("Signed-out sessions must stay retired"); return [] },
            loadWorkshop: { XCTFail("The official website must not renew an explicit logout"); return false })
        defaults.set("76561198000000001", forKey: "steamWebLastAuthenticatedAccount")
        session.updateFromWebsite(cookies: [], afterLogout: true)
        await session.resumeRememberedSession()
        let signedOut = await withCheckedContinuation { session.authenticatedSession(completion: $0.resume(returning:)) }
        XCTAssertNil(signedOut)
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
