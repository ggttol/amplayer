import AmplayerKit
import SwiftUI

@main
struct AmplayerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PlayerScreen()
                .environment(model)
                .tint(.orange)
                #if DEBUG
                .task { DebugHooks.run(model) }
                #endif
        }
    }
}
