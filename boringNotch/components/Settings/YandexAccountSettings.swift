import AppKit
import Defaults
import SwiftUI
import ApplicationServices

struct YandexTokenSettingsView: View {
    @ObservedObject private var tokenStore = YandexMusicTokenStore.shared
    @State private var draft = ""
    @State private var showManual = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: tokenStore.isConnected ? "checkmark.seal.fill" : "quote.bubble")
                    .foregroundStyle(tokenStore.isConnected ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Yandex Music account")
                    Text(!tokenStore.isConnected
                         ? "Connect your account to display Yandex lyrics for the current recording."
                         : "Connected. Yandex lyrics are used when available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !tokenStore.isConnected {
                    Button("Connect…") { YandexAuthWindowController.shared.present() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Disconnect") {
                        do {
                            try tokenStore.disconnect()
                            draft = ""
                        } catch {
                            // The store publishes a safe, actionable error and preserves the token.
                        }
                    }
                }
            }

            if let error = tokenStore.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("Retry") { tokenStore.reload() }
                }
            }

            if !tokenStore.isConnected {
                Button(showManual ? "Hide manual entry" : "Enter a token manually instead") {
                    withAnimation { showManual.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)

                if showManual {
                    HStack {
                        SecureField("Paste OAuth token", text: $draft)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Yandex OAuth token")
                            .onSubmit { saveDraft() }
                        Button("Save") {
                            saveDraft()
                        }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }
    private func saveDraft() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try tokenStore.save(token: draft)
            draft = ""
        } catch {
            // The store publishes a safe error; keep the draft for retry.
        }
    }

}

struct YandexAccessibilityStatusView: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(trusted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Yandex Music control")
                Text(trusted
                     ? "Accessibility granted. Open Yandex Music to use playback controls."
                     : "Grant Accessibility so the notch can control Yandex Music directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !trusted {
                Button("Grant…") {
                    _ = AXIsProcessTrustedWithOptions(
                        [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .task {
            do {
                while !Task.isCancelled {
                    trusted = AXIsProcessTrusted()
                    try await Task.sleep(for: .seconds(2))
                }
            } catch { return }
        }
    }
}
