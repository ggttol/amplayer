# Privacy Policy / 隐私政策

[English](#english) · [简体中文](#简体中文)

_Last updated / 最后更新：2026-10-24_

## English

Amplayer is a free, open-source music player. It does not have accounts, analytics, ads or tracking, and the developer does not collect any of your data.

**What stays on your device**
- Your music sources: server addresses and user names are saved on the device, and passwords are saved in the iOS Keychain.
- Your playlists, library, settings, cached songs, lyrics and the playback log are stored on the device only.
- None of this is sent to the developer.

**Network connections Amplayer makes**
- **Your own servers.** Amplayer connects directly to the servers you add: NAS, WebDAV, SMB, Subsonic/Navidrome, Jellyfin/Emby, Synology and DLNA. This is how it browses and plays your music.
- **Synology QuickConnect.** If you enter a QuickConnect ID, Amplayer sends it to Synology's QuickConnect service to look up your NAS address.
- **Online lyrics.** When a song has no synced lyrics on your device or server, Amplayer sends the song's title, artist, album and duration to [LRCLIB](https://lrclib.net), and the title, artist and duration to the public lyrics search of NetEase Cloud Music, QQ Music and Kugou, to look them up. No account or device identifier is sent. You can turn this off in **Settings › Lyrics**.
- **Local network.** Amplayer uses local network discovery (Bonjour and SSDP) to find music servers on your local network.

These requests go straight from your device to the services above. Their own privacy policies apply.

**Contact.** Please open an issue at https://github.com/ggttol/amplayer/issues.

## 简体中文

Amplayer 是一款免费开源的音乐播放器。它没有账号系统，也没有统计、广告或追踪，开发者不收集你的任何数据。

**留在你设备上的数据**
- 你添加的音乐来源：服务器地址和用户名保存在设备上，密码保存在 iOS 钥匙串里。
- 播放列表、曲库、设置、缓存的歌曲、歌词和播放日志也只保存在设备上。
- 这些数据都不会发给开发者。

**Amplayer 会发起的网络连接**
- **你自己的服务器**：Amplayer 直接连接你添加的服务器，包括 NAS、WebDAV、SMB、Subsonic/Navidrome、Jellyfin/Emby、群晖和 DLNA，用来浏览和播放你的音乐。
- **群晖 QuickConnect**：填写 QuickConnect ID 时，Amplayer 会把它发给群晖的 QuickConnect 服务，用来查询你的 NAS 地址。
- **在线歌词**：设备和服务器上都没有带时间轴的歌词时，Amplayer 会把歌名、歌手、专辑和时长发给 [LRCLIB](https://lrclib.net)，把歌名、歌手和时长发给网易云音乐、QQ 音乐、酷狗的公开歌词搜索，用来查找歌词。不发送任何账号或设备标识。可以在“设置 › 歌词”里关闭。
- **局域网**：Amplayer 通过 Bonjour 和 SSDP 发现局域网里的音乐服务器。

这些请求都从你的设备直接发给上面的服务，适用它们各自的隐私政策。

**联系方式**：请在 https://github.com/ggttol/amplayer/issues 提交 Issue。
