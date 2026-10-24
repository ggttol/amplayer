import SwiftUI
import MP9Kit

struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("MP9")
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
            Text("v\(MP9Kit.version)")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    RootView()
}
