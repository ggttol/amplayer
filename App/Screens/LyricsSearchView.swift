import AmplayerKit
import SwiftUI

/// 在线搜索歌词（LRCLIB），自动匹配不对时手动挑一条
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
                Text("歌词来自 LRCLIB（lrclib.net）社区")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
            }
            .sheet(item: $preview) { r in
                LyricsPreview(result: r) {
                    if let text = r.text, app.player.setLyrics(text) {
                        app.show("已使用这份歌词")
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
                Text(r.synced != nil ? "同步" : (r.isInstrumental ? "纯音乐" : "纯文本"))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background((r.synced != nil ? Color.orange : Color.gray).opacity(0.2), in: Capsule())
            }
            let detail = [r.artist, r.album, r.duration.map(TimeFormat.clock)].compactMap { $0 }.filter { !$0.isEmpty }
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
            // 当前曲目时长附近的、带时间轴的排前面
            let duration = app.player.current?.duration
            results = found.filter { $0.text != nil || $0.isInstrumental }.sorted { a, b in
                if (a.synced != nil) != (b.synced != nil) { return a.synced != nil }
                guard let d = duration else { return false }
                return abs((a.duration ?? 1e9) - d) < abs((b.duration ?? 1e9) - d)
            }
            error = nil
        } catch {
            self.error = "搜索失败：\(error.localizedDescription)"
        }
    }
}

private struct LyricsPreview: View {
    let result: OnlineLyrics.Result
    let onUse: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                let lines = Lyrics.parse(result.text ?? "")?.lines.map(\.text) ?? []
                Text(lines.isEmpty ? "（没有歌词内容）" : lines.joined(separator: "\n"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("使用") { onUse() }.disabled(result.text == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
