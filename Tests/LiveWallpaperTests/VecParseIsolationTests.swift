import XCTest
@testable import LiveWallpaper

private actor AsyncBarrier {
    private var remaining: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) {
        remaining = count
    }

    func arriveAndWait() async {
        remaining -= 1
        if remaining == 0 {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume()
            }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

final class VecParseIsolationTests: XCTestCase {
    func testConcurrentOverrideScopesDoNotContaminateEachOther() async {
        let taskCount = 32
        let barrier = AsyncBarrier(count: taskCount)
        let results = await withTaskGroup(of: (Int, String?).self, returning: [Int: String?].self) { group in
            for index in 0..<taskCount {
                group.addTask {
                    await VecParse.$overrides.withValue(["shared": .string("wallpaper-\(index)")]) {
                        await barrier.arriveAndWait()
                        let field: [String: Any] = ["user": "shared", "value": "fallback"]
                        return (index, VecParse.unwrap(field) as? String)
                    }
                }
            }

            var collected: [Int: String?] = [:]
            for await (index, value) in group {
                collected[index] = value
            }
            return collected
        }

        for index in 0..<taskCount {
            XCTAssertEqual(results[index]!, "wallpaper-\(index)")
        }
        XCTAssertTrue(VecParse.overrides.isEmpty, "词法作用域结束后不应泄漏任何壁纸覆盖值")
    }

    func testLockedTimeStageUsesTheSuppliedWallpaperSnapshot() throws {
        if ProcessInfo.processInfo.environment["WP_TIME_STAGE"] != nil {
            throw XCTSkip("WP_TIME_STAGE 会有意覆盖壁纸时段设置")
        }

        let morning = ["ts_mode": "locked", "ts_locked_time": "1"]
        let night = ["ts_mode": "locked", "ts_locked_time": "4"]

        XCTAssertEqual(VecParse.effectiveTimeStage(config: morning), 1)
        XCTAssertEqual(VecParse.effectiveTimeStage(config: night), 4)
    }
}
