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
xcodebuild test-without-building -project Amplayer.xcodeproj -scheme Amplayer -destination "id=$UDID" -derivedDataPath build/sim 2>&1 \
  | grep -E "Test Case .*(passed|failed)|error:|TEST (EXECUTE )?(SUCCEEDED|FAILED)"
status=${PIPESTATUS[0]}
docker rm -f amplayertest-webdav >/dev/null 2>&1
exit $status
