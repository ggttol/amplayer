# Amplayer

[English](README.md) · **简体中文**

<img src="App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="112" align="right" alt="Amplayer 图标">

**一款致敬 Winamp 2.x 的怀旧开源 iOS 音乐播放器。**

像素级还原经典三窗口（主窗口、10 段均衡器、播放列表），能加载原汁原味的 `.wsz` 皮肤，频谱照样跳动。音乐可以直接从 NAS、媒体服务器和局域网共享里播放。献给所有还记得把皮肤拖到那个小窗口上的人。

欢迎大家试用，有问题或想法请提 Issue，也欢迎 PR！

<p>
  <img src="Docs/screenshots/main.png" width="200" alt="主窗口、均衡器和播放列表">
  <img src="Docs/screenshots/lyrics.png" width="200" alt="辉光皮肤下的同步歌词">
  <img src="Docs/screenshots/ivory.png" width="200" alt="象牙皮肤">
  <img src="Docs/screenshots/skins.png" width="200" alt="内置皮肤">
</p>

## 功能

**经典三窗口**
- 主窗口：数码管时间（点一下切换剩余时间）、滚动标题、kbps/kHz、频谱和示波器、进度、音量、平衡、随机和循环（单曲循环时按钮上显示小“1”）。
- 均衡器：10 段加前级放大，19 个预设，带曲线图。
- 播放列表：ADD / REM / SEL / MISC / LIST 菜单，可以排序、反转、打乱、去重，导入导出 M3U / PLS。点歌名直接播放；长按可以多选、看曲目信息、离线下载。
- 标题栏：左上角按钮打开侧边总控菜单，`_` 切换迷你模式，`□` 换下一套皮肤。

**皮肤**
- 能加载任意 Winamp 2.x 经典 `.wsz` 皮肤，皮肤里缺的图用内置皮肤补齐。
- 内置 6 套原创皮肤，全部用代码绘制：Graphite、Nixie 辉光、Deep Ocean 深海、Sakura 樱、Synthwave 霓虹、Ivory 象牙。
- 皮肤页有 [Winamp Skin Museum](https://skins.webamp.org) 的入口，收录了七万多款皮肤。下载的 `.wsz` 在“文件”App 里点开就能导入。

**音乐来源**

| 来源 | 说明 |
|---|---|
| 本机文件 | “文件”App › Amplayer，或从“文件”导入 |
| WebDAV | 包括 Alist / OpenList（能把大部分网盘转成 WebDAV）、群晖 WebDAV Server、Nextcloud |
| SMB 2/3 | Windows 共享和各类 NAS |
| Subsonic / OpenSubsonic | Navidrome、Airsonic、Gonic、Ampache |
| Jellyfin / Emby | 媒体库、专辑、艺术家、文件夹 |
| 群晖 DSM | 可填 IP、域名或 **QuickConnect ID**；File Station 能浏览所有共享文件夹，不需要建索引；Audio Station 另外提供专辑和播放列表 |
| UPnP / DLNA | 几乎所有 NAS 都自带的媒体服务器 |

局域网里的 SMB、WebDAV、DLNA 服务会通过 Bonjour 和 SSDP 自动发现。

**播放**
- 支持 MP3、AAC/M4A、ALAC、FLAC、**APE**（内置 Monkey's Audio 解码器）、WAV、AIFF、CAF、Opus（CAF 封装）。
- 下一首已经缓存、并且格式相同时，切歌无缝衔接。
- 网络曲目先缓存再播放，下载时显示进度，并会提前缓存下一首；也可以离线下载。
- 支持后台播放、锁屏和控制中心、耳机线控、AirPlay，被来电打断后自动恢复。

**歌词**
- 点播放列表的标题栏，在列表和同步歌词之间切换。当前句高亮并自动滚动，点某一句就跳到那里。
- 歌词来源依次是：歌曲旁边的同名 `.lrc`（UTF-8 和 GBK 都行）、群晖和 Navidrome 的歌词接口、文件内嵌歌词，都没有时在线查 [LRCLIB](https://lrclib.net)。也可以手动搜索，自己挑一条。
- 繁体歌词可以显示成简体。

**曲库**
- 把来源扫描进曲库，按歌曲、艺术家、专辑浏览和搜索。

## 试用

**TestFlight 公开测试**：https://testflight.apple.com/join/tkH6ZD3E 。在 iPhone 上装好 TestFlight，打开链接就能安装。App Store 正式版正在审核中。

也可以自己编译安装：

1. 需要一台 Mac，装好 **Xcode 16 或更高版本**（在 Xcode 27 上测试过）和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。App 支持 iOS 17 及以上。
2. 克隆仓库，配置签名团队：
   ```sh
   git clone https://github.com/ggttol/amplayer.git && cd amplayer
   cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # 填入 DEVELOPMENT_TEAM
   xcodegen generate
   open Amplayer.xcodeproj
   ```
3. 选你的 iPhone 或模拟器，点运行。用免费 Apple ID 也可以，但每 7 天要重新安装一次。

想播网盘里的歌（阿里云盘、百度网盘、115、夸克等）：装一个 [Alist / OpenList](https://github.com/OpenListTeam/OpenList)，再在 Amplayer 里把它添加为 WebDAV 来源。

## 工程结构

```
App/                      SwiftUI 界面
  Skin/                   经典三窗口：精灵图渲染、滑块、可视化、歌词面板
  Screens/                来源、浏览、曲库、皮肤、设置、侧边菜单
Packages/AmplayerKit/
  AmplayerCore            曲目、播放队列、M3U/PLS、均衡器、LRC 解析
  AmplayerAudio           AVAudioEngine 播放器、10 段 EQ、vDSP 频谱、标签读取、APE 流式解码、无缝衔接
  MonkeysAudio            Monkey's Audio SDK（C++）和一层 C 接口
  AmplayerSources         各协议来源、Keychain、局域网发现、在线歌词
  AmplayerCache           下载缓存、LRU、离线文件、下载进度
  AmplayerSkin            .wsz 解析（自带 ZIP 读取器）、精灵图坐标表、内置皮肤
  AmplayerKit             播放总控、曲库、来源和皮肤管理
UITests/                  XCUITest 端到端测试
Tools/                    测试服务器、界面测试脚本、图标生成
```

## 测试

```sh
(cd Packages/AmplayerKit && swift test)    # 在 macOS 上跑单元测试
Tools/ui-test.sh                           # 在模拟器里跑界面测试（会用 Docker 起一个 WebDAV 测试服务器）
Tools/test-servers.sh && (cd Packages/AmplayerKit && AMP_LIVE=1 swift test)   # 在 Docker 里起 WebDAV、DLNA、SMB、Navidrome、Jellyfin
```

有些测试会连真实服务，凭据通过环境变量传入：
- **真实群晖**：`AMP_SYNO_URL`、`AMP_SYNO_USER`、`AMP_SYNO_PASS`、`AMP_SYNO_QC`。
- **LRCLIB**：`AMP_LIVE_LYRICS=1`。
- **真实 `.wsz` 皮肤**：`AMP_TEST_WSZ`。

调试版可以用启动参数驱动界面，见 `App/DebugHooks.swift`。App 里的 **设置 › 播放日志** 会记录切歌、出错和音频打断，反馈问题时附上它会很有帮助。

## 许可

代码以 [MIT 许可证](LICENSE) 开源。第三方组件沿用各自的许可：Monkey's Audio SDK 是 BSD；AMSMB2 / libsmb2 是 LGPL，以动态库方式链接。详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。

Amplayer 是爱好者的致敬作品，与 Winamp、Nullsoft、Llama Group 没有任何关系。内置皮肤和图标都是原创；导入的 `.wsz` 皮肤版权归原作者所有。
