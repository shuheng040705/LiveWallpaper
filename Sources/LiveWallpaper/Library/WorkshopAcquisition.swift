import Foundation

/// 所有“下载/订阅”入口共用的编排器。
///
/// - CrossOver Steam 在线：先完成社区订阅，再让该客户端优先下载；
/// - 20 秒没有接管：WorkshopDownloader 自动回退常驻 SteamCMD；
/// - Steam 不在线：SteamCMD 立即开始，订阅事务并行补齐；
/// - 工坊网页已经确认订阅：不重复 POST，只选择下载后端。
enum WorkshopAcquisition {
    static func start(
        id: String,
        title: String,
        sizeBytes: Int64 = 0,
        subscriptionConfirmed: Bool = false
    ) {
        precondition(Thread.isMainThread)
        guard id.allSatisfy(\.isNumber), id.count >= 6 else { return }
        let destination = PreferencesStore.shared.libraryRoot.appendingPathComponent(id, isDirectory: true)
        guard !LocalWallpaperProbe.isReady(at: destination) else { return }

        let downloader = WorkshopDownloader.shared
        let clientAvailable = downloader.isCrossOverSteamAvailable
        let currentSteamID = SteamWebSession.shared.steamID64

        if subscriptionConfirmed {
            SteamSubscriptionRegistry.markSubscribed(id)
            downloader.enqueue(
                id: id,
                title: title,
                sizeBytes: sizeBytes,
                preferSteamClient: clientAvailable,
                expectedSteamID64: currentSteamID
            )
            return
        }

        if clientAvailable {
            // 先放一个可见占位任务，避免社区请求/网页授权期间按钮看起来“点了没反应”。
            downloader.enqueue(
                id: id,
                title: title,
                sizeBytes: sizeBytes,
                preferSteamClient: true,
                expectedSteamID64: currentSteamID,
                waitForSubscription: true
            )
            subscribeThenRelease(id: id)
        } else {
            // Steam 客户端不在线时不让网页事务阻塞本地下载。
            downloader.enqueue(id: id, title: title, sizeBytes: sizeBytes)
            subscribeBestEffort(id: id)
        }
    }

    private static func subscribeThenRelease(id: String) {
        SteamSubscription.subscribe(id: id) { outcome in
            switch outcome {
            case .success:
                SteamWebSession.shared.refresh { _ in
                    WorkshopDownloader.shared.beginReservedDownload(
                        id: id,
                        preferSteamClient: true,
                        expectedSteamID64: SteamWebSession.shared.steamID64
                    )
                }
            case .authenticationRequired:
                SteamWebSession.shared.clearAuthenticationCookies {
                    SteamWebLoginWindowController.shared.authorize(workshopID: id) { authorized in
                        if authorized {
                            subscribeThenRelease(id: id)
                        } else {
                            Log.write("WorkshopAcquisition \(id): 用户取消 Steam 网页授权，回退 SteamCMD")
                            WorkshopDownloader.shared.beginReservedDownload(
                                id: id,
                                preferSteamClient: false,
                                expectedSteamID64: nil
                            )
                        }
                    }
                }
            case .failure(let message):
                // 网络超时可能发生在 Steam 已接受请求之后；仍先观察客户端 20 秒，避免双写。
                Log.write("WorkshopAcquisition \(id): 订阅响应不确定，先观察 Steam 客户端 — \(message)")
                WorkshopDownloader.shared.beginReservedDownload(
                    id: id,
                    preferSteamClient: true,
                    expectedSteamID64: SteamWebSession.shared.steamID64
                )
            }
        }
    }

    /// SteamCMD 路线不依赖网页 Cookie；订阅失败不能让已经开始的本地下载倒退。
    private static func subscribeBestEffort(id: String) {
        SteamSubscription.subscribe(id: id) { outcome in
            switch outcome {
            case .success:
                Log.write("WorkshopAcquisition \(id): 已同步 Steam 订阅")
            case .authenticationRequired:
                SteamWebSession.shared.clearAuthenticationCookies {
                    SteamWebLoginWindowController.shared.authorize(workshopID: id) { authorized in
                        if authorized { subscribeBestEffort(id: id) }
                    }
                }
            case .failure(let message):
                Log.write("WorkshopAcquisition \(id): 本地下载继续，Steam 订阅暂未同步 — \(message)")
            }
        }
    }
}
