import MP9Kit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mp9.cacheLimit") private var cacheLimit: Int = 2 * 1024 * 1024 * 1024
    @State private var usage: (cache: Int64, offline: Int64) = (0, 0)

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

                Section("支持的格式") {
                    Text("MP3、AAC/M4A、ALAC、FLAC、WAV、AIFF、CAF、Opus（CAF 封装）")
                        .font(.footnote)
                }

                Section("关于") {
                    LabeledContent("版本", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""))")
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
    MP9 使用了以下开源软件：

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

    swift-atomics
    https://github.com/apple/swift-atomics
    Apache License 2.0 — Copyright (c) Apple Inc.

    按照 LGPL 的要求，你可以替换 AMSMB2.framework 为自行编译的版本；MP9 的源码修改与目标文件可应要求提供。

    MP9 与 Winamp、Nullsoft、Llama Group 无关。经典皮肤的版权归各自作者所有。
    """
}
