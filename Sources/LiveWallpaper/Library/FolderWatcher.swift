import Foundation

/// 监视一个目录的内容变化(新增/删除子文件夹)。Steam 下完工坊壁纸后会在此目录新增文件夹,
/// 借此自动触发壁纸库重新扫描。基于 DispatchSource 文件描述符监视(轻量、无轮询)。
final class FolderWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let url: URL
    private let onChange: () -> Void
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        stop()
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { Log.write("FolderWatcher: open failed \(url.path)"); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in self?.fire() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        src.resume()
        source = src
        Log.write("FolderWatcher: watching \(url.path)")
    }

    /// 目录事件很频繁(Steam 下载边写边触发),去抖 1.5s 后再回调,避免半成品。
    private func fire() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.write("FolderWatcher: change detected → refresh")
            self?.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
