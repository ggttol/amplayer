import AmplayerKit
import SwiftUI

/// 在线搜索歌词（LRCLIB、网易云音乐、QQ 音乐、酷狗），自动匹配不对时手动挑一条
struct LyricsSearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [OnlineLyrics.Result] = []
    @State private var searching = false
    @State private var error: String?
    @State private var preview: OnlineLyrics.Result?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                ForEach(results) { r in
                    Button { preview = r } label: { row(r) }
                        .foregroundStyle(.primary)
                }
            }
            .overlay {
                if searching {
                    ProgressView()
                } else if results.isEmpty && error == nil && !query.isEmpty {
                    ContentUnavailableView("没有结果", systemImage: "quote.bubble", description: Text("换个关键词试试，比如只写歌名"))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "歌名 歌手")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle("在线搜索歌词")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
            .safeAreaInset(edge: .bottom) {
                Text("歌词来自 LRCLIB、网易云音乐、QQ 音乐、酷狗")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .sheet(item: $preview) { r in
                LyricsPreview(result: r) { text in
                    if app.player.setLyrics(text) {
                        app.show(String(localized: "已使用这份歌词"))
                        app.showLyrics = true
                        app.showPlaylist = true
                    }
                    preview = nil
                    dismiss()
                }
            }
            .task {
                guard query.isEmpty, let track = app.player.current else { return }
                query = [track.artist, track.title].compactMap { $0 }.joined(separator: " ")
                await search()
            }
        }
    }

    private func row(_ r: OnlineLyrics.Result) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(r.title).lineLimit(1)
                Spacer()
                if r.isLoaded {
                    Text(r.synced != nil ? "同步" : (r.isInstrumental ? "纯音乐" : "纯文本"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((r.synced != nil ? Color.orange : Color.gray).opacity(0.2), in: Capsule())
                }
            }
            let detail = [r.provider.name, r.artist, r.album, r.duration.map(TimeFormat.clock)].compactMap { $0 }.filter { !$0.isEmpty }
            Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            let found = try await OnlineLyrics.shared.search(query: q)
            // 和当前曲目时长差不多（3 秒内）的排前面，其余保持各家交错的顺序
            let duration = app.player.current?.duration
            func near(_ r: OnlineLyrics.Result) -> Bool {
                guard let duration, let d = r.duration else { return false }
                return abs(d - duration) <= 3
            }
            results = found.filter { !$0.isLoaded || $0.text != nil || $0.isInstrumental }
                .enumerated().sorted { a, b in near(a.element) != near(b.element) ? near(a.element) : a.offset < b.offset }
                .map(\.element)
            error = nil
        } catch {
            self.error = String(localized: "搜索失败：\(error.localizedDescription)")
        }
    }
}

private struct LyricsPreview: View {
    let result: OnlineLyrics.Result
    let onUse: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: OnlineLyrics.Result?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if let loaded {
                    let lines = Lyrics.parse(loaded.text ?? "")?.lines.map(\.text) ?? []
                    Text(lines.isEmpty ? (loaded.isInstrumental ? String(localized: "（纯音乐）") : String(localized: "（没有歌词内容）")) : lines.joined(separator: "\n"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else if failed {
                    Text("歌词下载失败，返回换一条试试").foregroundStyle(.secondary).padding()
                } else {
                    ProgressView().padding(.top, 40)
                }
            }
            .task {
                do { loaded = try await OnlineLyrics.shared.load(result) } catch { failed = true }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { if let text = loaded?.text { onUse(text) } }.disabled(loaded?.text == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
