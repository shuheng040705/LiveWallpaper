import Foundation
import Combine

extension Notification.Name {
    static let workshopRemoveLocal = Notification.Name("LiveWallpaper.workshopRemoveLocal")
    static let steamSubscriptionsDidChange = Notification.Name("LiveWallpaper.steamSubscriptionsDidChange")
}

/// 工坊卡片与详情共用同一份状态，成功订阅后下载，成功退订后停止下载并卸载。
@MainActor
final class WorkshopSubscriptions: ObservableObject {
    static let shared = WorkshopSubscriptions()
    enum Operation { case subscribing, unsubscribing, removing }

    struct Environment {
        var subscribe: (String, @escaping (SteamSubscription.Outcome) -> Void) -> Void
        var unsubscribe: (String, @escaping (SteamSubscription.Outcome) -> Void) -> Void
        var authorize: (String, @escaping (Bool) -> Void) -> Void
        var download: (WorkshopWallpaper) -> Void
        var discard: (String, @escaping () -> Void) -> Void
        var removeLocal: (String, @escaping (String?) -> Void) -> Void
        var installed: (String) -> Bool
        var knownSubscriptions: () -> Set<String>
        var recordSubscription: (String, Bool) -> Void

        static var live: Environment {
            Environment(
                subscribe: SteamSubscription.subscribe, unsubscribe: SteamSubscription.unsubscribe,
                authorize: { id, completion in
                    SteamWebSession.shared.clearAuthenticationCookies {
                        SteamWebLoginWindowController.shared.authorize(workshopID: id, completion: completion)
                    }
                },
                download: { item in
                    WorkshopAcquisition.start(id: item.id, title: item.title,
                                              sizeBytes: item.sizeBytes, subscriptionConfirmed: true)
                },
                discard: { id, completion in WorkshopDownloader.shared.discard(id: id, completion: completion) },
                removeLocal: { id, completion in
                    NotificationCenter.default.post(name: .workshopRemoveLocal, object: nil,
                                                    userInfo: ["id": id, "completion": completion])
                },
                installed: SteamSubscriptions.isInstalled,
                knownSubscriptions: SteamSubscriptionRegistry.knownSubscribedIDs,
                recordSubscription: { id, subscribed in
                    if subscribed { SteamSubscriptionRegistry.markSubscribed(id) }
                    else { SteamSubscriptionRegistry.markUnsubscribed(id) }
                }
            )
        }
    }

    @Published private(set) var subscribedIDs: Set<String> = []
    @Published private(set) var operations: [String: Operation] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var overrides: [String: Bool] = [:]
    private let environment: Environment

    init(environment: Environment = .live) {
        self.environment = environment
        subscribedIDs = environment.knownSubscriptions()
    }

    func refresh() {
        var ids = environment.knownSubscriptions()
        for (id, subscribed) in overrides {
            if subscribed { ids.insert(id) } else { ids.remove(id) }
        }
        subscribedIDs = ids
    }

    func isSubscribed(_ item: WorkshopWallpaper) -> Bool {
        overrides[item.id] ?? (subscribedIDs.contains(item.id) || item.isSubscribed == true)
    }

    func toggle(_ item: WorkshopWallpaper) {
        guard WallpaperUninstallPolicy.isSteamWorkshopID(item.id), operations[item.id] == nil else { return }
        errors[item.id] = nil
        let subscribing = !isSubscribed(item)
        operations[item.id] = subscribing ? .subscribing : .unsubscribing
        transact(item, subscribing: subscribing, authorizedOnce: false)
    }

    func retryDownload(_ item: WorkshopWallpaper) {
        guard operations[item.id] == nil else { return }
        errors[item.id] = nil
        if item.isSubscribed == true { confirmedWebsiteChange(item, subscribed: true) }
        else if isSubscribed(item) { environment.download(item) }
        else { toggle(item) }
    }

    func recoverMissingWebsiteDownload(_ item: WorkshopWallpaper) {
        let recorded = WorkshopDownloader.shared.jobs.contains { $0.id == item.id && $0.state != .done }
        if recoverMissingWebsiteDownload(item, hasDownloadRecord: recorded || SteamSubscriptionRegistry.skipsAutomaticDownload(item.id)) {
            Log.write("Steam 工坊：已确认订阅，补下载 " + item.id)
        }
    }

    /// Recover a previously missed subscription only from an authenticated item response.
    /// An existing transfer or explicit local cancellation keeps its own retry policy.
    @discardableResult
    func recoverMissingWebsiteDownload(_ item: WorkshopWallpaper, hasDownloadRecord: Bool) -> Bool {
        guard item.isSubscribed == true, !hasDownloadRecord, overrides[item.id] == nil,
              operations[item.id] == nil, !environment.installed(item.id) else { return false }
        confirmedWebsiteChange(item, subscribed: true)
        return true
    }

    /// Steam has confirmed the change, so only the local registry, transfer and files need updating.
    func confirmedWebsiteChange(_ item: WorkshopWallpaper, subscribed: Bool) {
        guard WallpaperUninstallPolicy.isSteamWorkshopID(item.id) else { return }
        errors[item.id] = nil
        overrides[item.id] = subscribed
        environment.recordSubscription(item.id, subscribed)
        if subscribed { subscribedIDs.insert(item.id) } else { subscribedIDs.remove(item.id) }

        // An earlier unsubscribe still owns the download worker. Its completion will use the latest state.
        guard operations[item.id] != .removing else { return }
        if subscribed {
            operations[item.id] = nil
            if !environment.installed(item.id) { environment.download(item) }
        } else {
            operations[item.id] = .removing
            environment.discard(item.id) { [weak self] in
                guard let self else { return }
                if self.overrides[item.id] == true { self.finishRemoval(item, error: nil) }
                else { self.removeLocal(item) }
            }
        }
    }

    /// 删除文件失败时，Steam 已经退订，保留一个只重试本地卸载的入口。
    func retryRemoval(_ item: WorkshopWallpaper) {
        guard operations[item.id] == nil else { return }
        operations[item.id] = .removing
        errors[item.id] = nil
        removeLocal(item)
    }

    private func transact(_ item: WorkshopWallpaper, subscribing: Bool, authorizedOnce: Bool) {
        let action = subscribing ? environment.subscribe : environment.unsubscribe
        action(item.id) { [weak self] result in
            guard let self, self.operations[item.id] == (subscribing ? .subscribing : .unsubscribing) else { return }
            switch result {
            case .success:
                self.confirmedWebsiteChange(item, subscribed: subscribing)
            case .authenticationRequired:
                guard !authorizedOnce else {
                    self.fail(item.id, "Steam 网页授权尚未生效，请重新登录后重试")
                    return
                }
                self.environment.authorize(item.id) { [weak self] success in
                    guard let self, self.operations[item.id] == (subscribing ? .subscribing : .unsubscribing) else { return }
                    if success { self.transact(item, subscribing: subscribing, authorizedOnce: true) }
                    else { self.fail(item.id, "已取消 Steam 授权，订阅与本地文件保持原状") }
                }
            case .failure(let message): self.fail(item.id, message)
            }
        }
    }

    private func removeLocal(_ item: WorkshopWallpaper) {
        environment.removeLocal(item.id) { [weak self] error in
            self?.finishRemoval(item, error: error)
        }
    }

    private func finishRemoval(_ item: WorkshopWallpaper, error: String?) {
        operations[item.id] = nil
        if overrides[item.id] == true {
            if !environment.installed(item.id) { environment.download(item) }
        } else if let error {
            errors[item.id] = "已取消订阅，本地卸载失败：\(error)"
        }
    }

    private func fail(_ id: String, _ message: String) {
        operations[id] = nil
        errors[id] = message
    }
}
