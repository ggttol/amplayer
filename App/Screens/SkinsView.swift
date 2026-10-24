import MP9Kit
import SwiftUI
import UniformTypeIdentifiers

/// 皮肤列表与导入
struct SkinsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    static let skinTypes: [UTType] = [UTType("dev.gaotao.mp9.wsz") ?? .zip, .zip]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(app.skins.entries) { entry in
                        Button {
                            app.skins.select(entry.id)
                        } label: {
                            HStack(spacing: 12) {
                                SkinThumbnail(skin: app.skins.skin(for: entry))
                                VStack(alignment: .leading) {
                                    Text(entry.name).foregroundStyle(.primary)
                                    Text(entry.file == nil ? "内置" : "已导入").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if app.skins.current.id == entry.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                        .swipeActions {
                            if entry.file != nil {
                                Button("删除", role: .destructive) { app.skins.delete(entry) }
                            }
                        }
                    }
                } footer: {
                    Text("支持经典 .wsz 皮肤（Winamp 2.x 格式）。可在 Winamp Skin Museum（skins.webamp.org）下载，然后在“文件”App 里用 MP9 打开，或点右上角导入。皮肤版权归原作者所有。")
                }
            }
            .navigationTitle("皮肤")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("导入", systemImage: "square.and.arrow.down") { importing = true }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.skinTypes, allowsMultipleSelection: true) { result in
                guard case let .success(urls) = result else { return }
                var ok = 0
                for url in urls {
                    if (try? app.skins.importSkin(from: url)) != nil { ok += 1 }
                }
                app.show(ok == urls.count ? "已导入 \(ok) 个皮肤" : "\(urls.count - ok) 个文件不是有效皮肤")
            }
        }
    }
}

/// 主窗口缩略图
struct SkinThumbnail: View {
    let skin: Skin?
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
            } else {
                Color.gray.opacity(0.2)
            }
        }
        .frame(width: 137.5, height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: skin?.id) {
            guard let skin else { return }
            var state = SkinPreview.State()
            state.title = skin.name
            image = SkinPreview.mainWindow(skin, state: state)
        }
    }
}
