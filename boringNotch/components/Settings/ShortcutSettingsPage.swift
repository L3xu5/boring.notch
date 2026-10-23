import AppKit
import Defaults
import SwiftUI
import KeyboardShortcuts

struct Shortcuts: View {
    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Toggle Sneak Peek:", name: .toggleSneakPeek)
            } header: {
                Text("Media")
            } footer: {
                Text(
                    "Sneak Peek shows the media title and artist under the notch for a few seconds."
                )
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
            Section {
                KeyboardShortcuts.Recorder("Toggle Notch Open:", name: .toggleNotchOpen)
            }
            Section {
                KeyboardShortcuts.Recorder("Play / Pause:", name: .mediaPlayPause)
                KeyboardShortcuts.Recorder("Next track:", name: .mediaNextTrack)
                KeyboardShortcuts.Recorder("Previous track:", name: .mediaPreviousTrack)
                KeyboardShortcuts.Recorder("Like:", name: .mediaLike)
                KeyboardShortcuts.Recorder("Dislike:", name: .mediaDislike)
            } header: {
                Text("Media control")
            } footer: {
                Text("These shortcuts control your selected music source directly. Your keyboard's physical media keys continue to use macOS media handling.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .accentColor(.effectiveAccent)
    }
}
