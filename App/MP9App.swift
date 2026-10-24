import MP9Kit
import SwiftUI

@main
struct MP9App: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PlayerScreen()
                .environment(model)
                #if DEBUG
                .task { DebugHooks.run(model) }
                #endif
        }
    }
}
