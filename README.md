# MP9

iOS 音乐播放器，界面像素级复刻经典 Winamp 2.x，可加载 `.wsz` 皮肤。可以播放本机、NAS、媒体服务器和网盘里的音乐。

调研结论与路线图见 [Docs/ROADMAP.md](Docs/ROADMAP.md)。

## 功能

- **经典三窗口**：主窗口、10 段均衡器、播放列表，按屏幕宽度等比放大，最近邻插值保证像素清晰
  - 主窗口：时间（点按切换剩余时间，暂停时闪烁）、滚动标题（中文自动改用系统字体）、kbps/kHz/声道、频谱与示波器（viscolor.txt 配色）、进度、音量、平衡、随机/循环（关→全部→单曲）
  - 均衡器：10 段 + 前级放大、开关、19 个预设、曲线图；双击滑块归零
  - 播放列表：ADD / REM / SEL / MISC / LIST 菜单，排序、反转、打乱、去重、裁剪，保存与打开 M3U/PLS，长按曲目查看信息或离线下载
- **皮肤**：内置原创 “MP9 Graphite”；支持导入任意 Winamp 2.x `.wsz` 皮肤，缺少的位图用内置皮肤补齐。可在“文件”App 中直接用 MP9 打开 `.wsz`
- **来源**
  | 类型 | 说明 |
  |---|---|
  | 本机文件 | “文件”App › MP9，或从“文件”导入 |
  | WebDAV | 含 Alist / OpenList（可把各种网盘转成 WebDAV）、群晖 WebDAV Server、Nextcloud |
  | SMB 2/3 | Windows 共享、各类 NAS |
  | Subsonic / OpenSubsonic | Navidrome、Airsonic、Gonic、Ampache |
  | Jellyfin / Emby | 媒体库、专辑、艺术家、文件夹浏览 |
  | 群晖 Audio Station | 文件夹、专辑、播放列表，直接使用 NAS 的标签和封面 |
  | UPnP / DLNA | 几乎所有 NAS 自带的媒体服务器 |
  | 阿里云盘 / 百度网盘 | 走官方开放平台 OAuth，需要先配置 AppKey（见下） |
- **局域网发现**：Bonjour（SMB、WebDAV）+ SSDP（DLNA）
- **缓存**：网络曲目完整缓存后播放，并预缓存下一首；LRU 上限可调；支持离线下载
- **曲库**：扫描来源进曲库，按歌曲、艺术家、专辑浏览和搜索
- **系统集成**：后台播放、锁屏与控制中心、耳机线控、来电打断后恢复、AirPlay

支持的格式：MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF、CAF、Opus（CAF 封装），也就是 Core Audio 原生能解码的格式。

## 工程结构

```
App/                     SwiftUI 界面
  Skin/                  经典三窗口（精灵图渲染、滑块、可视化）
  Screens/               来源、浏览、曲库、皮肤、设置
Packages/MP9Kit/
  MP9Core                曲目、播放队列、M3U/PLS、均衡器
  MP9Audio               AVAudioEngine 播放器、10 段 EQ、vDSP 频谱、标签读取
  MP9Sources             各协议来源、Keychain、局域网发现
  MP9Cache               下载缓存、LRU、离线
  MP9Skin                .wsz 解析（自带 ZIP 读取器）、精灵图表、默认皮肤绘制
  MP9Kit                 播放总控、曲库、来源与皮肤管理
UITests/                 XCUITest 端到端测试
Tools/                   测试服务器脚本、图标生成
```

## 构建（在 Mac 上）

```sh
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig   # 填入 Team ID
xcodegen generate
xcodebuild -project MP9.xcodeproj -scheme MP9 -destination "platform=iOS Simulator,name=MP9 iPhone" build
```

网盘直连需要开放平台的应用凭据：复制 `Config/Secrets.xcconfig.example` 为 `Config/Secrets.local.xcconfig` 并填写。不配置时，界面会提示改用 Alist/OpenList 的 WebDAV。

## 测试

```sh
# 单元测试（macOS 上运行 Swift 包测试）
(cd Packages/MP9Kit && swift test)

# 用真实皮肤验证解析：指向 Webamp 仓库里的 base-2.91.wsz（不入库）
(cd Packages/MP9Kit && MP9_TEST_WSZ=/path/to/base-2.91.wsz swift test)

# 端到端：启动 WebDAV、DLNA、SMB、Navidrome、Jellyfin 容器，再跑在线测试
Tools/test-servers.sh
(cd Packages/MP9Kit && MP9_LIVE=1 swift test)

# 界面测试（需要上面的 WebDAV 容器，模拟器 Documents 里放几首测试音频）
xcodebuild test -project MP9.xcodeproj -scheme MP9 -destination "platform=iOS Simulator,name=MP9 iPhone"
```

调试版支持用启动参数驱动界面，见 `App/DebugHooks.swift`。

## 许可

依赖只使用 MIT / Apache / LGPL（AMSMB2 以动态库链接）。详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。MP9 与 Winamp / Nullsoft / Llama Group 无关。
