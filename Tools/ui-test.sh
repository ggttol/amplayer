#!/bin/bash
# 一键跑界面测试：起 WebDAV 测试服务器、把测试音频放进模拟器里 App 的 Documents、运行 UI 测试。
# 用法：Tools/ui-test.sh [模拟器名，默认 "MP9 iPhone"]
set -uo pipefail
cd "$(dirname "$0")/.."
SIM="${1:-MP9 iPhone}"
M="$HOME/amplayer-testmedia"
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/dockercfg}" PATH="/tmp/dockercfg/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v orb >/dev/null && orb start >/dev/null 2>&1
docker rm -f amplayertest-webdav >/dev/null 2>&1
docker run -d --name amplayertest-webdav -p 18080:8080 -v "$M":/data:ro rclone/rclone serve webdav /data --addr :8080 --user amplayer --pass amplayerpass >/dev/null
UDID=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | grep -oE "[0-9A-F-]{36}")
xcrun simctl boot "$UDID" 2>/dev/null
xcodegen generate >/dev/null
xcodebuild build-for-testing -project Amplayer.xcodeproj -scheme Amplayer -destination "id=$UDID" -derivedDataPath build/sim -quiet 2>&1 | grep -E "error:" && exit 1
xcrun simctl install "$UDID" build/sim/Build/Products/Debug-iphonesimulator/Amplayer.app
DOCS="$(xcrun simctl get_app_container "$UDID" dev.gaotao.amplayer data)/Documents"
mkdir -p "$DOCS" && cp "$M/Album One/"* "$DOCS/"

# 当前 Xcode 跑完测试后解析系统版本号会挂住不退出：看到 All tests 的结果行就结束它
LOG=$(mktemp)
xcodebuild test-without-building -project Amplayer.xcodeproj -scheme Amplayer -destination "id=$UDID" -derivedDataPath build/sim >"$LOG" 2>&1 &
XCB=$!
for _ in $(seq 1 300); do
  kill -0 "$XCB" 2>/dev/null || break
  if grep -qE "^Test Suite 'All tests' (passed|failed)" "$LOG"; then sleep 3; break; fi
  sleep 2
done
kill "$XCB" 2>/dev/null
grep -E "^Test Case .*(passed|failed)|error:" "$LOG" | sort -u
grep -E "^Test Suite 'All tests' (passed|failed)" "$LOG" || echo "测试没有跑完（超时或崩溃），日志：$LOG"
grep -qE "^Test Suite 'All tests' passed" "$LOG"
status=$?
[ $status -eq 0 ] && rm -f "$LOG"
docker rm -f amplayertest-webdav >/dev/null 2>&1
exit $status
