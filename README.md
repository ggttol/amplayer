# mp9

iOS 音乐播放器：支持 WebDAV（含 Alist/OpenList）、SMB、Subsonic/Navidrome、Jellyfin/Emby、群晖及其他 NAS，界面复刻 Winamp 2.x 并可加载经典 .wsz 皮肤。

调研结论与分阶段计划见 [Docs/ROADMAP.md](Docs/ROADMAP.md)。

## 构建（在 Mac 上）

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig  # 填入 Team ID
xcodegen generate
xcodebuild -project MP9.xcodeproj -scheme MP9 -destination "platform=iOS Simulator,name=MP9 iPhone" build
(cd Packages/MP9Kit && swift test)
```
