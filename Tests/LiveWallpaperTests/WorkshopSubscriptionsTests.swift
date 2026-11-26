import XCTest
@testable import LiveWallpaper

final class WorkshopSubscriptionsTests: XCTestCase {
    private let item = WorkshopWallpaper(id: "1234567890", title: "Fixture")

    @MainActor
    private final class Fixture {
        var events: [String] = []
        var subscribed: Set<String> = []
        var installed = false
        var subscribeResult: SteamSubscription.Outcome = .success("OK")
        var unsubscribeResult: SteamSubscription.Outcome = .success("OK")
        var authorized = true
        var deletionError: String?
        var deferDiscard = false
        var discarded: (() -> Void)?
        var environment: WorkshopSubscriptions.Environment {
            .init(subscribe: { _, done in self.events.append("subscribe"); done(self.subscribeResult) },
                  unsubscribe: { _, done in self.events.append("unsubscribe"); done(self.unsubscribeResult) },
                  authorize: { _, done in self.events.append("authorize"); done(self.authorized) },
                  download: { _ in self.events.append("download") },
                  discard: { _, done in
                      self.events.append("discard")
                      if self.deferDiscard { self.discarded = done } else { done() }
                  },
                  removeLocal: { _, done in self.events.append("remove"); done(self.deletionError) },
                  installed: { _ in self.installed }, knownSubscriptions: { self.subscribed },
                  recordSubscription: { id, value in
                      if value { self.subscribed.insert(id) } else { self.subscribed.remove(id) }
                  })
        }
    }

    @MainActor
    func testSubscribeDownloadsThenSecondClickUnsubscribesAndRemoves() {
        let fixture = Fixture()
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertTrue(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["subscribe", "download"])
        store.toggle(item)
        XCTAssertFalse(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["subscribe", "download", "unsubscribe", "discard", "remove"])
    }

    @MainActor
    func testSubscriptionFailureDoesNotStartDownload() {
        let fixture = Fixture(); fixture.subscribeResult = .failure("Network unavailable")
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertFalse(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["subscribe"])
        XCTAssertNotNil(store.errors[item.id])
    }

    @MainActor
    func testUnsubscribeFailurePreservesSubscriptionAndLocalFiles() {
        let fixture = Fixture(); fixture.subscribed.insert(item.id)
        fixture.unsubscribeResult = .failure("Network unavailable")
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertTrue(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["unsubscribe"])
    }

    @MainActor
    func testRemovalWaitsForWorkerAndRapidClicksAreIgnored() {
        let fixture = Fixture(); fixture.subscribed.insert(item.id); fixture.deferDiscard = true
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        store.toggle(item)
        XCTAssertEqual(fixture.events, ["unsubscribe", "discard"])
        XCTAssertNotNil(store.operations[item.id])
        fixture.discarded?()
        XCTAssertEqual(fixture.events, ["unsubscribe", "discard", "remove"])
        XCTAssertNil(store.operations[item.id])
    }

    @MainActor
    func testExistingLocalWallpaperCanStillSubscribeWithoutRedownloading() {
        let fixture = Fixture(); fixture.installed = true
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertTrue(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["subscribe"])
    }

    @MainActor
    func testCancelledAuthorizationDoesNotChangeSubscriptionOrFiles() {
        let fixture = Fixture(); fixture.subscribed.insert(item.id)
        fixture.unsubscribeResult = .authenticationRequired; fixture.authorized = false
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertTrue(store.isSubscribed(item))
        XCTAssertEqual(fixture.events, ["unsubscribe", "authorize"])
        XCTAssertNil(store.operations[item.id])
    }

    @MainActor
    func testAuthorizationFailureRetriesOnlyOnce() {
        let fixture = Fixture(); fixture.subscribeResult = .authenticationRequired
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertEqual(fixture.events, ["subscribe", "authorize", "subscribe"])
        XCTAssertNil(store.operations[item.id])
        XCTAssertNotNil(store.errors[item.id])
    }

    @MainActor
    func testFailedDeletionCanRetryWithoutSubscribingAgain() {
        let fixture = Fixture(); fixture.subscribed.insert(item.id); fixture.deletionError = "Disk error"
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.toggle(item)
        XCTAssertFalse(store.isSubscribed(item))
        XCTAssertNotNil(store.errors[item.id])
        fixture.deletionError = nil
        store.retryRemoval(item)
        XCTAssertNil(store.errors[item.id])
        XCTAssertEqual(fixture.events, ["unsubscribe", "discard", "remove", "remove"])
    }

    @MainActor
    func testWebsiteConfirmationOnlyRunsLocalActions() {
        let fixture = Fixture()
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.confirmedWebsiteChange(item, subscribed: true)
        store.confirmedWebsiteChange(item, subscribed: false)
        XCTAssertEqual(fixture.events, ["download", "discard", "remove"])
        XCTAssertFalse(store.isSubscribed(item))
    }

    @MainActor
    func testResubscribingWhileWorkerStopsKeepsInstalledCopy() {
        let fixture = Fixture()
        fixture.installed = true
        fixture.deferDiscard = true
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.confirmedWebsiteChange(item, subscribed: false)
        store.confirmedWebsiteChange(item, subscribed: true)
        fixture.discarded?()
        XCTAssertEqual(fixture.events, ["discard"])
        XCTAssertTrue(store.isSubscribed(item))
        XCTAssertNil(store.operations[item.id])
    }

    @MainActor
    func testResubscribingDuringCancelledDownloadRestartsAfterWorkerExits() {
        let fixture = Fixture()
        fixture.deferDiscard = true
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.confirmedWebsiteChange(item, subscribed: false)
        store.confirmedWebsiteChange(item, subscribed: true)
        XCTAssertEqual(fixture.events, ["discard"])
        fixture.discarded?()
        XCTAssertEqual(fixture.events, ["discard", "download"])
    }

    @MainActor
    func testDownloadOfSubscriptionConfirmedByPageSkipsSecondPost() {
        let fixture = Fixture()
        let store = WorkshopSubscriptions(environment: fixture.environment)
        store.confirmedWebsiteChange(item, subscribed: false)
        var subscribedOnSteam = item
        subscribedOnSteam.isSubscribed = true
        store.retryDownload(subscribedOnSteam)
        XCTAssertEqual(fixture.events, ["discard", "remove", "download"])
        XCTAssertTrue(store.isSubscribed(item))
    }
}
