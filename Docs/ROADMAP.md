# mp9：支持网盘和网络协议、仿 Winamp 界面的 iOS 音乐播放器

## Context
用户在 Mac 的 `~/code/mp9` 新建了空仓库（`db258ee Initial commit`，只有 README 和 .gitignore）。
目标是做一款 iOS 音乐播放器：
1. 能播放常见网盘和网络协议里的音乐；
2. 界面和功能参考 Winamp 经典版。

本计划先列出调研结论，再给出技术方案和分阶段实施步骤。

**已确认的决策**
- 界面：像素级复刻 Winamp 2.x，**支持加载经典 .wsz 皮肤**，App 自带一套原创默认皮肤。
- 第一版来源：WebDAV（含 Alist/OpenList）、SMB、Subsonic/Navidrome、Jellyfin/Emby、**群晖及其他 NAS**。
- 分发：**上架 App Store**。依赖只用 MIT/BSD/LGPL（LGPL 以动态库方式链接）；网盘只走官方 API；名称和素材中不出现 Winamp 商标。

---

## 一、调研结论

### 1. 同类播放器支持哪些来源（以 App Store 描述为准）
| App | 网络协议 | 网盘 | 媒体服务器 / 其他 |
|---|---|---|---|
| **SenPlayer** | WebDAV、SMB、FTP | 115、阿里云盘、百度网盘 | Emby、Jellyfin、飞牛；IPTV（M3U/M3U8/TXT） |
| **VidHub** | SMB/CIFS、WebDAV | 百度、阿里、115、天翼、移动云盘、Dropbox、Google Drive、OneDrive | Emby、Jellyfin、Plex；Alist 通过 WebDAV 接入 |
| **Infuse** | SMB、NFS、FTP/SFTP/FTPS、WebDAV、UPnP/DLNA | 主流海外网盘 | Plex、Jellyfin、Emby |
| **Listenify**（音乐类） | WebDAV | 阿里云盘 | Navidrome、Subsonic、Emby |
| Amperfy、Substreamer 等 | — | — | Subsonic / OpenSubsonic、Ampache |

**结论**：大家共同支持的是 **SMB + WebDAV + FTP/SFTP**，加上 **Emby/Jellyfin**。国内网盘普遍做的是 **阿里云盘、百度网盘、115**；音乐类还有 **Subsonic/Navidrome**。Alist/OpenList 可以把几十种网盘统一转成 WebDAV，是性价比最高的“间接网盘支持”。

### 2. 国内网盘接入的现实情况
- 阿里云盘、百度网盘、115 都有官方 **OAuth 开放平台**，需要申请 AppKey 并审核，个人开发者能否通过各家不同；115 有传闻称曾暂停 API。夸克没有公开 API。
- 模拟网页或客户端请求（CloudDrive、AList 的部分驱动就是这么做的）不稳定，也有合规风险，不适合上架 App。
- **策略**：第一期用 WebDAV 兼容 Alist/OpenList，覆盖所有网盘；第二期在申请到 Key 后接入阿里云盘和百度网盘的官方 OpenAPI。

### 2.5 NAS 接入
- **群晖**：除了 SMB/WebDAV 通用协议，还有 **Audio Station Web API**：用 `SYNO.API.Auth` 登录，`SYNO.API.Info` 查询接口路径和版本，`SYNO.AudioStation.Song/Album/Artist/Playlist/Cover` 获取曲库，`SYNO.AudioStation.Stream` 取流。可以直接复用 NAS 已扫描好的标签和封面，体验和官方 DS audio 一样。外网访问用 QuickConnect（需要解析 QuickConnect ID 到实际地址，属非公开协议，放到后期）或用户自填 DDNS 地址。官方没有完整的 API 文档，要以 NAS 上 `SYNO.API.Info` 返回的结果为准。
- **其他 NAS**（威联通、飞牛 fnOS、绿联、极空间、TrueNAS、Unraid 等）：没有统一的音乐 API，靠下面几种通用方式覆盖：
  - SMB、WebDAV；
  - **UPnP/DLNA 媒体服务器客户端**（几乎所有 NAS 都自带 DLNA 服务，群晖 Media Server、威联通 DLNA、MiniDLNA 都支持）；
  - NAS 上部署的 Navidrome 或 Jellyfin。
- **局域网自动发现**：用 Bonjour 发现 `_smb._tcp`、`_webdav._tcp`，用 SSDP 发现 DLNA 设备，群晖还可以通过 findhost 方式发现。

### 3. 仿 Winamp 的开源参考
- 目前**没有能加载经典 .wsz 皮肤的 iOS 播放器**。官方 Winamp iOS App 是现代风格，不支持经典皮肤。这一点正好是差异化卖点。
- **Webamp**（captbaritone/webamp，MIT）：用 HTML5 完整复刻 Winamp 2.x，有完整的 .wsz 解析和精灵图坐标表。这是**最重要的参考**，可以移植它的坐标表和解析逻辑。
- **MacWamp**（pzzzy/macwamp，GPL-3.0）：Swift + AppKit + AVFoundation 的 Winamp 复刻，只能参考思路；GPL 会传染，不要拷代码。
- mgreenwood1001/winamp：Swift 实现，含 10 段 EQ、M3U、Milkdrop 可视化，仅限 macOS。
- Audacious、qmmp：桌面端开源播放器，有 Winamp Classic 皮肤模式。
- .wsz 格式：zip 包，里面是 main.bmp、cbuttons.bmp、titlebar.bmp、posbar.bmp、eqmain.bmp、pledit.bmp、numbers.bmp、text.bmp，加上 viscolor.txt、pledit.txt 等；缺少的文件用默认皮肤补齐。
- **版权**：Winamp 默认皮肤和商标属于 Llama Group，不能内置或冠名。App 自带一套原创默认皮肤，用户可自行导入 .wsz。

### 4. 开源 iOS 音乐播放器与组件
- **Amperfy**（BLeeEZ/amperfy，GPL-3.0，Swift 6）：Subsonic/Ampache 客户端，有无缝播放、EQ、ReplayGain、CarPlay、离线。是架构参考，但同样是 GPL。
- **SFBAudioEngine**（sbooth，MIT）：基于 AVAudioEngine，支持 FLAC、Opus、MP3、DSD（DoP/转 PCM）、Monkey's Audio、WavPack 等，**适合做音频内核**。它只接受本地文件 URL，所以网络来源要先下载或缓存。
- **AMSMB2**（amosavian，LGPL-2.1）：SMB2/3 客户端，支持 SPM，用动态库方式链接即可满足 LGPL。
- WebDAV：用 URLSession 自己实现 PROPFIND 和 Range GET 即可（几百行）。FTP/SFTP 可后续用 libssh2 或 Citadel（SwiftNIO SSH）。

---

## 二、技术方案

- **平台**：iOS 17+，Swift 6，**SwiftUI 管页面框架，Winamp 皮肤区用 UIKit/CALayer 精确绘制**（像素级精灵图，整数倍缩放并关闭插值）。
- **工程**：XcodeGen（`project.yml`）生成 Xcode 工程，避免 pbxproj 冲突；模块用本地 Swift Package 拆分：
  - `MP9Core`：数据模型、播放队列、媒体库（SwiftData 或 GRDB）
  - `MP9Audio`：封装 SFBAudioEngine；10 段 EQ 用 AVAudioUnitEQ；频谱用 vDSP FFT 喂给可视化；无缝播放、ReplayGain
  - `MP9Sources`：统一的 `MediaSource` 协议（`list(path)`、`open(item) -> 可 Range 读取的流`、`metadata`）。实现：Local/Files、WebDAV、SMB、Subsonic、Jellyfin/Emby、Synology Audio Station、UPnP/DLNA（自己实现 SSDP + ContentDirectory SOAP Browse，不引入 GPL 库），之后加阿里云盘和百度网盘。凭据存在 Keychain
  - `MP9Cache`：边下边播。用 Range 分块下载到磁盘缓存，凑够头部后交给解码器；配置 LRU 容量
  - `MP9Skin`：解析 .wsz（zip → BMP → CGImage），精灵图坐标表移植自 Webamp；渲染主窗、EQ、播放列表三个窗口
- **Winamp 功能对照**：主窗（时间、滚动标题、kbps/kHz、频谱/示波器、进度、音量、平衡、上一首/播放/暂停/停止/下一首/弹出、随机/循环）、10 段 EQ + 预设、播放列表编辑器（M3U/PLS 导入导出）、皮肤切换。iPhone 上三个窗口竖向堆叠或分页显示，按比例放大到屏宽。
- **iOS 系统集成**：后台播放、锁屏和控制中心（MPNowPlayingInfoCenter、MPRemoteCommandCenter）、AirPlay、CarPlay（后期）。
- **许可证**：全部采用 MIT/LGPL 依赖，App 本身可以闭源上架；GPL 项目只看不抄。

---

## 三、分阶段实施

1. **M0 骨架**：在 `~/code/mp9` 写 XcodeGen 工程和本地 Package，App 能在模拟器启动；配好后台音频 entitlement。
2. **M1 播放内核**：接入 SFBAudioEngine，能播放本地文件（Files 导入）；做队列、锁屏控制、EQ 和 FFT。
3. **M2 Winamp 皮肤**：完成 .wsz 解析和主窗、EQ、播放列表三窗渲染与交互；附带一套原创默认皮肤；支持导入 .wsz。
4. **M3 网络来源**：
   - 先做 WebDAV（含 Alist/OpenList）、SMB，配合边下边播缓存；
   - 再做 Subsonic/Navidrome、Jellyfin/Emby；
   - 然后是群晖 Audio Station 和 UPnP/DLNA；
   - 最后做局域网自动发现。
5. **M4 媒体库**：扫描标签（专辑、艺术家、封面、歌词），支持离线下载和搜索。
6. **M5 扩展**：阿里云盘、百度网盘官方 OpenAPI（需要先申请 Key）、群晖 QuickConnect、FTP/SFTP、CarPlay，之后再考虑上架合规材料（隐私清单 PrivacyInfo.xcprivacy、本地网络权限说明文案）。

> 注：用户导入的 .wsz 由用户自行负责；内置皮肤必须原创。App Store 审核要特别注意本地网络权限（NSLocalNetworkUsageDescription、Bonjour 服务列表）和后台音频声明。

## 验证
- 每个阶段都在 **Mac 上编译**（`xcodebuild -scheme MP9 -destination 'platform=iOS Simulator,name=iPhone 17'`），不在 relay 本机编译；`MP9Skin`、`MP9Sources` 跑单元测试（用 Webamp 自带的 base skin 做皮肤快照对比，WebDAV 用本地 rclone serve webdav 测试）。
- M3 在 Mac 上用 OrbStack 起 Navidrome、Jellyfin、OpenList、MiniDLNA 和 Samba 容器做端到端测试；群晖 Audio Station 需要一台真实 NAS（用户若有，提供测试账号；否则用 Virtual DSM 或抓包样例做 mock）；真机装机按记忆里的方法，在 Mac 桌面会话中用 Xcode 运行。

## 参考来源
- SenPlayer：https://apps.apple.com/cn/app/id6443975850
- VidHub：https://apps.apple.com/cn/app/id1659622164
- Infuse 协议：https://support.firecore.com/hc/articles/215090977
- Navidrome 客户端列表：https://www.navidrome.org/apps/
- Webamp：https://github.com/captbaritone/webamp
- MacWamp：https://github.com/pzzzy/macwamp
- Amperfy：https://github.com/BLeeEZ/amperfy
- SFBAudioEngine：https://github.com/sbooth/SFBAudioEngine
- AMSMB2：https://github.com/amosavian/AMSMB2
- 官方 Winamp iOS 版评测：https://www.ghacks.net/?p=198403
