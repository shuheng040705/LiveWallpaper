import WebKit

/// Steam 的筛选菜单通过顶层 dialog 承载，菜单位置按网页视口计算。
/// WebKit 中 dialog 默认居中；菜单采用 absolute 布局时会叠加 dialog 的中心偏移，
/// 导致显示与点击坐标不一致。让菜单容器使用同一个视口坐标系，不硬编码按钮位置。
enum WorkshopWebCompatibility {
    static let popupLayoutScript = """
    (() => {
      const host = location.hostname.toLowerCase();
      if (location.protocol !== 'https:' ||
          !(host === 'steamcommunity.com' || host.endsWith('.steamcommunity.com'))) return;
      const install = () => {
        if (document.getElementById('lw-workshop-popup-layout')) return;
        const style = document.createElement('style');
        style.id = 'lw-workshop-popup-layout';
        style.textContent = `
          dialog:has([role="listbox"]), dialog:has([role="menu"]) {
            position: fixed !important;
            inset: 0 !important;
            margin: 0 !important;
            padding: 0 !important;
            border: 0 !important;
            width: 100vw !important;
            height: 100vh !important;
            max-width: none !important;
            max-height: none !important;
            background: transparent !important;
            overflow: visible !important;
          }
        `;
        (document.head || document.documentElement).appendChild(style);
      };
      if (document.documentElement) install();
      else document.addEventListener('DOMContentLoaded', install, {once: true});
    })();
    """

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: popupLayoutScript, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
    }
}
