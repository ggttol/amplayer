#!/bin/bash
# 在本机 Docker（Mac 上用 OrbStack）里启动集成测试用的服务器：
#   WebDAV  http://127.0.0.1:18080  amplayer / amplayerpass   (rclone)
#   DLNA    http://127.0.0.1:17879/rootDesc.xml     (rclone)
#   SMB     smb://127.0.0.1/Music   amplayer / amplayerpass   (Samba)
#   Subsonic http://127.0.0.1:14533 amplayer / amplayerpass   (Navidrome)
#   Jellyfin http://127.0.0.1:18096 amplayer / amplayerpass
# 用法：Tools/test-servers.sh [音乐目录]   之后运行：(cd Packages/AmplayerKit && AMP_LIVE=1 swift test)
# 停止：Tools/test-servers.sh --down
set -euo pipefail
NAMES="amplayertest-webdav amplayertest-dlna amplayertest-samba amplayertest-navidrome amplayertest-jellyfin"
if [ "${1:-}" = "--down" ]; then docker rm -f $NAMES >/dev/null 2>&1 || true; echo "已停止"; exit 0; fi
M="${1:-$HOME/amplayer-testmedia}"
if [ ! -d "$M" ]; then
  echo "生成测试音频到 $M"
  mkdir -p "$M/Album One"
  for i in 1 2 3; do
    say -o "/tmp/amplayer-say-$i.aiff" "Amplayer test track $i" 2>/dev/null || true
    [ -f "/tmp/amplayer-say-$i.aiff" ] && afconvert -f flac -d flac "/tmp/amplayer-say-$i.aiff" "$M/Album One/0$i - Test Track $i.flac"
  done
fi
docker rm -f $NAMES >/dev/null 2>&1 || true
docker run -d --name amplayertest-webdav -p 18080:8080 -v "$M":/data:ro rclone/rclone serve webdav /data --addr :8080 --user amplayer --pass amplayerpass >/dev/null
docker run -d --name amplayertest-dlna -p 17879:7879 -v "$M":/data:ro rclone/rclone serve dlna /data --addr :7879 --name AmplayerTestDLNA >/dev/null
docker run -d --name amplayertest-samba -p 445:445 -v "$M":/mount dperson/samba -u "amplayer;amplayerpass" -s "Music;/mount;yes;no;no;amplayer" >/dev/null
docker run -d --name amplayertest-navidrome -p 14533:4533 -v "$M":/music:ro -e ND_SCANSCHEDULE=1m deluan/navidrome:latest >/dev/null
docker run -d --name amplayertest-jellyfin -p 18096:8096 -v "$M":/media/music:ro jellyfin/jellyfin:latest >/dev/null

echo "初始化 Navidrome…"
until curl -sf http://127.0.0.1:14533/ping >/dev/null 2>&1 || curl -sf http://127.0.0.1:14533/app/ >/dev/null 2>&1; do sleep 2; done
curl -s -X POST http://127.0.0.1:14533/auth/createAdmin -H "Content-Type: application/json" -d '{"username":"amplayer","password":"amplayerpass"}' >/dev/null

echo "初始化 Jellyfin…"
J=http://127.0.0.1:18096
until curl -sf $J/System/Info/Public >/dev/null; do sleep 2; done
# 刚启动时 Jellyfin 会重置连接几次：等它稳定下来再做初始化
until curl -sf $J/Startup/Configuration >/dev/null 2>&1 || curl -sf $J/System/Info/Public | grep -q "\"StartupWizardCompleted\":true"; do sleep 2; done
sleep 3
curl -s -X POST $J/Startup/Configuration -H "Content-Type: application/json" -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null
curl -s $J/Startup/User >/dev/null
curl -s -X POST $J/Startup/User -H "Content-Type: application/json" -d '{"Name":"amplayer","Password":"amplayerpass"}' >/dev/null
curl -s -X POST $J/Startup/Complete >/dev/null
A='MediaBrowser Client="setup", Device="script", DeviceId="amplayer-setup", Version="1"'
TOKEN=$(curl -s --retry 5 --retry-all-errors -X POST $J/Users/AuthenticateByName -H "Content-Type: application/json" -H "Authorization: $A" -d '{"Username":"amplayer","Pw":"amplayerpass"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["AccessToken"])')
curl -s -X POST "$J/Library/VirtualFolders?name=Music&collectionType=music&paths=%2Fmedia%2Fmusic&refreshLibrary=true" \
  -H "Authorization: $A, Token=\"$TOKEN\"" -H "Content-Type: application/json" -d '{"LibraryOptions":{}}' >/dev/null
echo "等待媒体库扫描…"; sleep 20
docker ps --format '{{.Names}}  {{.Status}}' | grep amplayertest
