import SwiftUI
import TelegramLink
import VoiceLoop

/// Placeholder root view for the M0 skeleton. Replaced by the login and chat screens.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Winston")
                .font(.largeTitle)
            Text(AppSecrets.load() == nil ? "Telegram API credentials missing" : "Ready")
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
