import LooperCore
import SwiftUI

/// Placeholder window until the milestone 2 UI lands.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "repeat")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Looper")
                .font(.title)
            Text("Engine \(LooperCore.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 320)
    }
}

#Preview {
    ContentView()
}
