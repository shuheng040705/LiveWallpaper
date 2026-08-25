#!/bin/bash
# 用 SwiftPM 构建,再打包成可运行的 .app(带 Info.plist → 菜单栏代理、固定 bundle id)。
set -e
cd "$(dirname "$0")"

CONFIG="${1:-release}"   # ./build.sh debug 出调试版
APP="LiveWallpaper.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/LiveWallpaper"

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LiveWallpaper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# app 图标(若已生成)
[ -f build_icon/AppIcon.icns ] && cp build_icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 打包 WE 内置资源(粒子贴图 materials/ + 着色器 shaders/ + particles/ + effects/)进 bundle。
# 这样场景渲染读 app 包内文件,运行时不访问 ~/Documents,彻底消除「文稿」权限弹窗。
# ⚠ effects/ 必须打包:内置特效自带的相位/法线/流向贴图(如 waterflow 的 effects/waterflowphase、
#   waterripple 法线图)埋在 effects/<fx>/materials/effects/ 下,缺它则 g_Texture 辅助槽退白 →
#   屋檐水流不流、涟漪/晃动等位移类特效在打包版里全失效(headless 跑 ~/Documents/assets 看不出)。
# ⚠ assets 是渲染必需品:缺失时以前是「静默跳过」→ 打包出残废 app(位移类特效全失效),
#   headless 测试还看不出来。改为大声报错退出,拷贝失败也不再吞(cp 失败=残包,必须止步)。
ASSETS_SRC="${WE_ASSETS:-$HOME/Documents/assets}"
if [ ! -d "$ASSETS_SRC" ]; then
  echo "❌ 内置资源目录不存在: $ASSETS_SRC(可用 WE_ASSETS 环境变量指定)。assets 是渲染必需,拒绝打包残废 app。" >&2
  exit 1
fi
mkdir -p "$APP/Contents/Resources/assets"
for sub in materials shaders particles effects; do
  if [ ! -d "$ASSETS_SRC/$sub" ]; then
    echo "❌ 缺内置资源子目录: $ASSETS_SRC/$sub(effects/ 缺失=水流/涟漪等位移特效全失效,见上方注释)。" >&2
    exit 1
  fi
  cp -R "$ASSETS_SRC/$sub" "$APP/Contents/Resources/assets/" || { echo "❌ 拷贝 $sub 失败" >&2; exit 1; }
done
echo "==> 已打包内置资源: $(du -sh "$APP/Contents/Resources/assets" 2>/dev/null | awk '{print $1}')"

# 打包转译出的 WE 特效(manifest + MSL)进 bundle,供 WEEffectChain 加载真 WE 着色器。
# ⚠ 路径必须小写 tools/(实际目录名):曾写成大写 Tools/,在大小写不敏感卷上碰巧能跑,
#   换 case-sensitive 卷/CI 会静默漏打包 manifest → 全库特效失效泛白。
# ⚠ manifest 是渲染必需品:缺失/拷贝失败一律报错退出,不再静默跳过。
if [ ! -f tools/generated/WEEffects.json ]; then
  echo "❌ 缺 manifest: tools/generated/WEEffects.json(渲染必需)。请先跑 tools/we_add_effects.py 增量构建(勿全量 regen,见 manifest-regen-hazard)。" >&2
  exit 1
fi
cp tools/generated/WEEffects.json "$APP/Contents/Resources/WEEffects.json" || { echo "❌ 拷贝 WEEffects.json 失败" >&2; exit 1; }
cp -R tools/generated/we_effects "$APP/Contents/Resources/we_effects" || { echo "❌ 拷贝 we_effects/ MSL 失败" >&2; exit 1; }
echo "==> 已打包 WE 转译特效: $(ls tools/generated/we_effects/*.metal 2>/dev/null | wc -l | tr -d ' ') 个着色器"

# 代码签名:优先用固定的自签名证书「LiveWallpaper Self-Signed」(签名身份稳定,
# 屏幕录制等 TCC 权限授权一次后永久记住,不会每次 build 都重新申请)。
# 没有该证书时回退 adhoc(每次 build 身份变,权限会重新询问)。
# 注:用不带 -v 的列表(证书是自签名「未受信任」,但签名不需要信任,只验证才需要)。
SIGN_HASH=$(security find-identity -p codesigning 2>/dev/null | grep "LiveWallpaper Self-Signed" | head -1 | awk '{print $2}')
if [ -n "$SIGN_HASH" ]; then
  codesign --force --deep --sign "$SIGN_HASH" "$APP" 2>/dev/null && echo "==> 已用固定证书签名(权限持久)" || codesign --force --sign - "$APP" 2>/dev/null || true
else
  codesign --force --sign - "$APP" 2>/dev/null || true
  echo "==> adhoc 签名(无固定证书;权限可能每次重问)"
fi

# 部署到 /Applications/(用户实际运行的位置)。重要:bundle id 相同时 `open` 会被 LaunchServices
# 重定向到已注册的 /Applications/ 副本,所以只构建到开发目录会让用户一直跑旧版。除非 NO_DEPLOY=1。
if [ "${NO_DEPLOY:-0}" != "1" ]; then
  echo "==> 部署到 /Applications/"
  # 先让旧版正常退出，使 applicationWillTerminate 有机会关闭常驻 SteamCMD。
  # 过去直接 killall 会把 App 杀掉、却把下载子进程留成 PPID=1 的孤儿；连续部署后多个
  # SteamCMD 会争同一份 config/content_log，重新制造“点击后卡很久才下载”。
  if pgrep -f "/Applications/LiveWallpaper.app/Contents/MacOS/LiveWallpaper" >/dev/null 2>&1; then
    osascript -e 'tell application "LiveWallpaper" to quit' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pgrep -f "/Applications/LiveWallpaper.app/Contents/MacOS/LiveWallpaper" >/dev/null 2>&1 || break
      sleep 0.3
    done
  fi
  # 正常退出失败才强制结束 App。
  killall LiveWallpaper 2>/dev/null || true
  sleep 1
  # 只清理由本应用专属 staging 参数标识出的遗留 worker，不碰用户其它 SteamCMD。
  orphan_workers=$(ps -axo pid=,ppid=,command= | awk '
    $2 == 1 &&
    index($0, "com.a55555.livewallpaper/SteamWorkshop") &&
    index($0, "/MacOS/steamcmd") { print $1 }
  ')
  for worker_pid in $orphan_workers; do
    kill -TERM "$worker_pid" 2>/dev/null || true
  done
  [ -z "$orphan_workers" ] || sleep 1
  rm -rf /Applications/LiveWallpaper.app
  cp -R "$APP" /Applications/LiveWallpaper.app
  # ⭐防护:把当前 manifest+metal 强制再刷一遍进 /Applications(防止陈旧 manifest 残留 → 特效失效
  #   → 美术层退纯色填充 = 整屏泛白糊,见 texture-override-custom-fx-framework)。曾踩坑:/Applications 残留
  #   114-key 旧 manifest 而仓库是 130 → 白影 texture_override 全失效泛白。
  # ⚠ 顺序关键:刷新必须在下面 codesign **之前**——签名后再改 bundle 内容会破坏签名 seal,
  #   而本项目靠固定自签证书维持屏幕录制等 TCC 权限(见上方签名注释),签名破损=权限身份漂移。
  #   manifest 在上面已验证存在,这里拷贝失败直接报错(渲染必需,不吞)。
  cp tools/generated/WEEffects.json /Applications/LiveWallpaper.app/Contents/Resources/WEEffects.json \
    || { echo "❌ 刷新部署版 WEEffects.json 失败" >&2; exit 1; }
  rsync -a tools/generated/we_effects/ /Applications/LiveWallpaper.app/Contents/Resources/we_effects/ \
    || { echo "❌ 刷新部署版 we_effects/ 失败" >&2; exit 1; }
  echo "==> 已校验刷新部署版 manifest: $(python3 -c "import json;print(len(json.load(open('/Applications/LiveWallpaper.app/Contents/Resources/WEEffects.json'))))" 2>/dev/null) keys"
  # 所有对 bundle 内容的写入已完成,现在才签名(保证 seal 覆盖最终内容)。
  if [ -n "$SIGN_HASH" ]; then
    codesign --force --deep --sign "$SIGN_HASH" /Applications/LiveWallpaper.app 2>/dev/null || true
  fi
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/LiveWallpaper.app 2>/dev/null || true
  # ⭐sanity check:部署完的 .app 必须带齐渲染必需品(防上游哪步悄悄漏了还宣告部署成功)。
  if [ ! -d /Applications/LiveWallpaper.app/Contents/Resources/assets/effects ]; then
    echo "❌ 部署版缺 Resources/assets/effects/(位移类特效会全失效),部署无效!" >&2
    exit 1
  fi
  if [ ! -f /Applications/LiveWallpaper.app/Contents/Resources/WEEffects.json ]; then
    echo "❌ 部署版缺 Resources/WEEffects.json(特效 manifest),部署无效!" >&2
    exit 1
  fi
  echo "==> 已部署: /Applications/LiveWallpaper.app"
  # ⭐自动重启正在跑的壁纸进程,让新版立即生效(否则桌面继续跑旧进程=「改动不生效」,见 deploy-target-applications)。
  # NO_RELAUNCH=1 跳过(纯部署不重启)。
  if [ "${NO_RELAUNCH:-0}" != "1" ]; then
    sleep 1
    # ⭐open 后**验证进程真起来**:踩坑——killall 后 open 偶尔被 LaunchServices 忽略(旧实例退出竞态)→
    #   壁纸没重启、用户一直看旧画面=「改动不生效」(连续 3 版眼睛修复全因此没在桌面生效)。重试+存活校验+失败报警。
    started=0
    for try in 1 2 3; do
      open -a /Applications/LiveWallpaper.app 2>/dev/null || open /Applications/LiveWallpaper.app 2>/dev/null || true
      sleep 2
      if pgrep -f "LiveWallpaper.app/Contents/MacOS" >/dev/null 2>&1; then
        echo "==> 已重启壁纸(新版生效,PID $(pgrep -f 'LiveWallpaper.app/Contents/MacOS' | head -1))"
        started=1; break
      fi
      echo "==> 壁纸未起来,重试 $try/3..."
    done
    [ "$started" = "1" ] || echo "⚠️ 壁纸启动失败,请手动: open -a /Applications/LiveWallpaper.app"
  fi
fi

echo "==> 完成: $(pwd)/$APP"
echo "运行:  open '/Applications/LiveWallpaper.app'"
echo "在 Xcode 里开发:  open '$(pwd)/Package.swift'"
