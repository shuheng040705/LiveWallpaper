import WebKit

/// Coalesce list observations and retry a click if Steam has not recorded it yet.
@MainActor
final class SteamWorkshopListDownloadSync {
    private struct Candidate {
        let token = UUID()
        var attempts = 0
        var due = ContinuousClock.now
    }

    private let lookup: ([String], WKWebView) async -> [WorkshopWallpaper]?
    private let deliver: (WorkshopWallpaper, WKWebView) -> Void
    private var candidates = [String: Candidate]()
    private var worker: Task<Void, Never>?

    init(lookup: @escaping ([String], WKWebView) async -> [WorkshopWallpaper]?,
         deliver: @escaping (WorkshopWallpaper, WKWebView) -> Void) {
        self.lookup = lookup
        self.deliver = deliver
    }

    func offer(_ ids: [String], in webView: WKWebView) {
        for id in ids where candidates[id] == nil { candidates[id] = Candidate() }
        guard worker == nil, !candidates.isEmpty else { return }
        worker = Task { [weak self, weak webView] in
            guard let self else { return }
            guard let webView else { self.reset(); return }
            // Let React finish the current update and combine adjacent JS messages.
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            await drain(in: webView)
        }
    }

    func forget(_ id: String) {
        candidates.removeValue(forKey: id)
    }

    func reset() {
        worker?.cancel()
        worker = nil
        candidates.removeAll()
    }

    private func drain(in webView: WKWebView) async {
        let delays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]
        let store = webView.configuration.websiteDataStore.httpCookieStore
        var account: String?
        while !Task.isCancelled, let next = candidates.values.map(\.due).min() {
            if next > .now {
                // New clicks can arrive while an older check is backing off.
                do { try await Task.sleep(until: min(next, .now + .milliseconds(250)), clock: .continuous) } catch { return }
                continue
            }
            let active = await SteamWorkshopSubscriptionStatus.accountID(in: store)
            guard !Task.isCancelled else { return }
            if let account, active != account { reset(); return }
            account = active
            let ready = candidates.filter { $0.value.due <= .now }.sorted { $0.value.due < $1.value.due }
            // The status endpoint batches a whole page. Smaller retry groups give
            // each missing response a turn in the bounded detail-HTML fallback.
            let batch = ready.prefix(ready.first?.value.attempts == 0 ? 32 : 2)
            let ids = batch.map(\.key)
            let items = active == nil ? [] : await lookup(ids, webView) ?? []
            guard !Task.isCancelled else { return }
            var confirmed = [String: WorkshopWallpaper]()
            for item in items where item.isSubscribed == true { confirmed[item.id] = item }
            for (id, var candidate) in batch where candidates[id]?.token == candidate.token {
                if let item = confirmed[id] {
                    candidates[id] = nil
                    deliver(item, webView)
                } else if candidate.attempts < delays.count {
                    candidate.due = .now + delays[candidate.attempts]
                    candidate.attempts += 1
                    candidates[id] = candidate
                } else {
                    candidates[id] = nil
                }
            }
        }
        if !Task.isCancelled { worker = nil }
    }
}
