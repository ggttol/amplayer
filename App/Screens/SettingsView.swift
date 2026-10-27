import AmplayerKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("amplayer.cacheLimit") private var cacheLimit: Int = 2 * 1024 * 1024 * 1024
    @State private var usage: (cache: Int64, offline: Int64) = (0, 0)
    /// 和 PlayerController.onlineLyricsEnabled 是同一个键
    @AppStorage("amplayer.onlineLyrics") private var onlineLyrics = true
    @AppStorage("amplayer.simplifyLyrics") private var simplifyLyrics = true
    @AppStorage("amplayer.lyricsOnNowPlaying") private var lyricsOnNowPlaying = true

    private let limits: [(String, Int)] = [
        ("500 MB", 500 * 1024 * 1024), ("1 GB", 1 << 30), ("2 GB", 2 << 30), ("5 GB", 5 << 30), ("10 GB", 10 << 30), ("20 GB", 20 << 30),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("缓存上限", selection: $cacheLimit) {
                        ForEach(limits, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    LabeledContent("播放缓存", value: ByteCountFormatter.string(fromByteCount: usage.cache, countStyle: .file))
                    LabeledContent("离线下载", value: ByteCountFormatter.string(fromByteCount: usage.offline, countStyle: .file))
                    Button("清除播放缓存", role: .destructive) {
                        Task {
                            await app.player.cache.clearCache()
                            usage = await app.player.cache.usage()
                        }
                    }
                } header: {
                    Text("存储")
                } footer: {
                    Text("网络上的曲目会先完整缓存再播放，并预先缓存下一首。超过上限时自动删除最久未播放的缓存；离线下载的曲目不会被删除。")
                }

                Section("播放") {
                    @Bindable var app = app
                    Toggle("显示剩余时间", isOn: $app.showRemainingTime)
                    Picker("可视化", selection: $app.visualizerMode) {
                        Text("频谱").tag(AppModel.VisualizerMode.spectrum)
                        Text("示波器").tag(AppModel.VisualizerMode.oscilloscope)
                        Text("关闭").tag(AppModel.VisualizerMode.off)
                    }
                }

                Section {
                    Toggle("在线查找歌词", isOn: $onlineLyrics)
                    Toggle("繁体歌词显示为简体", isOn: $simplifyLyrics)
                        .onChange(of: simplifyLyrics) { _, _ in app.player.refreshLyricsDisplay() }
                    Toggle("锁屏和车机显示歌词", isOn: $lyricsOnNowPlaying)
                        .onChange(of: lyricsOnNowPlaying) { _, _ in app.player.refreshNowPlaying() }
                } header: {
                    Text("歌词")
                } footer: {
                    Text("本地没有带时间轴的歌词时，把歌名、歌手和时长发给 LRCLIB、网易云音乐、QQ 音乐和酷狗查找。找到的歌词保存在本机。“锁屏和车机显示歌词”打开时，锁屏、控制中心和 CarPlay 里歌手一行会换成当前这句。")
                }

                Section("支持的格式") {
                    Text("MP3、AAC/M4A、ALAC、FLAC、APE（Monkey's Audio）、WAV、AIFF、CAF、Opus（CAF 封装）")
                        .font(.footnote)
                }

                Section("关于") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
                    Link(destination: AppLinks.repository) {
                        LabeledContent("开源项目", value: "github.com/ggttol/amplayer")
                    }
                    Link("反馈问题 / 提建议", destination: AppLinks.issues)
                    NavigationLink("播放日志") { PlaybackLogView() }
                    NavigationLink("开源许可") { LicensesView() }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { usage = await app.player.cache.usage() }
            .onChange(of: cacheLimit) { _, new in
                Task {
                    await app.player.cache.setLimit(Int64(new))
                    usage = await app.player.cache.usage()
                }
            }
        }
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.footnote.monospaced())
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("开源许可")
    }

    static let text = """
    Amplayer 使用了以下开源软件：

    Webamp（皮肤精灵图坐标与字体映射）
    https://github.com/captbaritone/webamp
    MIT License — Copyright (c) 2015 Jordan Eldredge

    Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

    AMSMB2（SMB 客户端，以动态库形式链接）
    https://github.com/amosavian/AMSMB2
    GNU Lesser General Public License v2.1 — Copyright (c) Amir Abbas Mousavian

    libsmb2
    https://github.com/sahlberg/libsmb2
    GNU Lesser General Public License v2.1 — Copyright (c) Ronnie Sahlberg

    Monkey's Audio SDK 13.43（APE 解码）
    https://monkeysaudio.com
    3-Clause BSD License — Copyright 2000-2026 Matthew T. Ashland. All rights reserved.
    Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met: (1) Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer. (2) Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution. (3) Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.

    swift-atomics
    https://github.com/apple/swift-atomics
    Apache License 2.0 — Copyright (c) Apple Inc.

    按照 LGPL 的要求，你可以替换 AMSMB2.framework 为自行编译的版本；Amplayer 的源码修改与目标文件可应要求提供。

    Amplayer 与 Winamp、Nullsoft、Llama Group 无关。经典皮肤的版权归各自作者所有。
    """
}

/// 播放日志：遇到“不自动下一首”之类的问题时复制给开发者
struct PlaybackLogView: View {
    @State private var text = PlaybackLog.text
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "还没有记录" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("播放日志")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("复制", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = text
                    app.show("已复制播放日志")
                }
                Button("清空", systemImage: "trash") {
                    PlaybackLog.clear()
                    text = ""
                }
            }
        }
    }
}

enum AppLinks {
    static let repository = URL(string: "https://github.com/ggttol/amplayer")!
    static let issues = URL(string: "https://github.com/ggttol/amplayer/issues")!
}
