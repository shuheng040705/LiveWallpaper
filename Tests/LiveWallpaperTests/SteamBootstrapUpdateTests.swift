import Combine
import XCTest
@testable import LiveWallpaper

final class SteamBootstrapUpdateTests: XCTestCase {
    func testTailSkipsPartialHistoricalLinesAndHandlesRotationAndOversizedRecords() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: log) }
        try Data("old incomplete line".utf8).write(to: log)
        var tail = SteamLogTail(url: log)
        func append(_ data: Data) throws {
            let file = try FileHandle(forWritingTo: log)
            defer { try? file.close() }
            _ = try file.seekToEnd()
            try file.write(contentsOf: data)
        }
        try append(Data(" continuation\nnew".utf8))
        XCTAssertEqual(tail.readLines(), [])
        try append(Data(" line\n".utf8))
        XCTAssertEqual(tail.readLines(), ["new line"])
        try append(Data(repeating: 65, count: 70_000) + Data("\nnext\n".utf8))
        XCTAssertEqual(tail.readLines(), [])
        XCTAssertEqual(tail.readLines(), ["next"])
        try Data("rotated\n".utf8).write(to: log, options: .atomic)
        XCTAssertEqual(tail.readLines(), ["rotated"])
        try Data("short\n".utf8).write(to: log)
        XCTAssertEqual(tail.readLines(), ["short"])
    }

    func testOnlyCurrentGrowingProgressExtendsTheDeadlineWithinBudget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("bootstrap.txt")
        try Data("更新完成，正在启动 Steamcmd...\n".utf8).write(to: url)
        let start = Date()
        var update = SteamBootstrapUpdate(log: url, start: start, idleWindow: 3, maximumDuration: 6)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        _ = try file.seekToEnd()
        func append(_ line: String, at second: Double) throws {
            try file.write(contentsOf: Data((line + "\n").utf8))
            update.poll(now: start.addingTimeInterval(second))
        }
        try append("Checking for update on startup", at: 1)
        XCTAssertFalse(update.updating)
        XCTAssertFalse(update.needsRelaunch(afterExit: 0))
        try append("正在下载更新 (已下载 2,322，共 15,851 KB)...", at: 2)
        XCTAssertTrue(update.updating)
        XCTAssertEqual(update.deadline.timeIntervalSince(start), 5, accuracy: 0.001)
        try append("正在下载更新 (已下载 2,322，共 15,851 KB)...", at: 3)
        XCTAssertEqual(update.deadline.timeIntervalSince(start), 5, accuracy: 0.001)
        try append("Downloading update (2,900 of 15,851 KB)...", at: 4)
        XCTAssertEqual(update.deadline.timeIntervalSince(start), 6, accuracy: 0.001)
        try append("更新完成，正在启动 Steamcmd...", at: 5)
        XCTAssertTrue(update.needsRelaunch(afterExit: 0))
        XCTAssertFalse(update.needsRelaunch(afterExit: 1))
        XCTAssertTrue(update.needsRelaunch(afterExit: 42))
    }

    @MainActor
    func testSlowSteamUpdateRelaunchesWithoutSpendingTheDownloadRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("steamcmd-fixture")
        // Allow a cold worker to launch. Six progress intervals span 1.5 login
        // windows, so the worker can finish only if real log growth extends its deadline.
        let loginWindow: TimeInterval = 4
        let progressInterval = loginWindow / 4
        try """
        #!/bin/sh
        dest="$2"
        logs="$HOME/Library/Application Support/Steam/logs"
        mkdir -p "$logs"
        if [ ! -e "$HOME/updated" ]; then
          for kb in 100 200 300 400 500 600; do
            echo "正在下载更新 (已下载 ${kb}，共 600 KB)..." >> "$logs/bootstrap_log.txt"
            sleep \(progressInterval)
          done
          echo '更新完成，正在启动 Steamcmd...' >> "$logs/bootstrap_log.txt"
          touch "$HOME/updated"
          exit 42
        fi
        echo 'Waiting for user info...OK'
        while read -r cmd app item; do
          [ "$cmd" = quit ] && exit 0
          mkdir -p "$dest/steamapps/workshop/content/$app/$item"
          echo '{}' > "$dest/steamapps/workshop/content/$app/$item/project.json"
          echo "Success. Downloaded item $item to destination (3 bytes)"
        done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = WorkshopDownloader(stagingDirectory: root.appendingPathComponent("cache"), executable: script,
                                        libraryDirectory: library, account: "fixture",
                                        timeouts: .init(login: loginWindow, retryDelay: 0.01))
        defer { client.shutdown() }
        let finished = expectation(description: "Updated worker installs the first request")
        var showedUpdate = false
        var complete = false
        let observation = client.$jobs.sink { jobs in
            guard let job = jobs.first else { return }
            if job.phase == .updatingDownloader { showedUpdate = true }
            if !complete, !WorkshopDownloader.isActive(job.state) {
                complete = true
                XCTAssertEqual(job.state, .done)
                XCTAssertEqual(job.attempt, 1)
                finished.fulfill()
            }
        }
        client.enqueue(id: "1234567890", title: "bootstrap")
        wait(for: [finished], timeout: 6 * loginWindow)
        observation.cancel()
        XCTAssertTrue(showedUpdate)
    }
}
