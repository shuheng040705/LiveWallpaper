import WebKit

/// LiveWallpaper 内的网页只需要播放媒体，不需要采集摄像头、麦克风或屏幕。
/// WKUIDelegate 的权限拒绝是最终防线；此脚本在页面脚本执行前移除采集入口，避免第三方页面
/// 反复发起请求，或在 WebKit 权限回调前短暂唤醒系统采集服务。
enum WebMediaCapturePolicy {
    static let denialScriptSource = #"""
    (function () {
      'use strict';
      var makeError = function () {
        try { return new DOMException('Media capture is disabled by LiveWallpaper', 'NotAllowedError'); }
        catch (_) { var e = new Error('Media capture is disabled by LiveWallpaper'); e.name = 'NotAllowedError'; return e; }
      };
      var rejected = function () { return Promise.reject(makeError()); };
      var blockPromiseAPI = function (target, name) {
        if (!target) return;
        try {
          Object.defineProperty(target, name, {
            value: rejected, writable: false, enumerable: false, configurable: false
          });
        } catch (_) {
          try { target[name] = rejected; } catch (_) {}
        }
      };

      var mediaDevices = null;
      try { mediaDevices = navigator.mediaDevices; } catch (_) {}
      blockPromiseAPI(mediaDevices, 'getUserMedia');
      blockPromiseAPI(mediaDevices, 'getDisplayMedia');

      var legacyDenied = function (_constraints, _success, failure) {
        var error = makeError();
        if (typeof failure === 'function') {
          Promise.resolve().then(function () { failure(error); });
        }
      };
      ['getUserMedia', 'webkitGetUserMedia', 'mozGetUserMedia'].forEach(function (name) {
        try {
          Object.defineProperty(navigator, name, {
            value: legacyDenied, writable: false, enumerable: false, configurable: false
          });
        } catch (_) {
          try { navigator[name] = legacyDenied; } catch (_) {}
        }
      });
    })();
    """#

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: denialScriptSource,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
    }
}
