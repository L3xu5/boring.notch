import AppKit
import AVFoundation
import BoringCore
import Defaults
import SwiftUI

struct Appearance: View {
    @ObservedObject private var coordinator = BoringViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.mirrorShape) private var mirrorShape
    @Default(.sliderColor) private var sliderColor
    @Default(.useMusicVisualizer) private var useMusicVisualizer
    @Default(.customVisualizers) private var customVisualizers
    @Default(.selectedVisualizer) private var selectedVisualizer
    @State private var addingVisualizer = false
    @State private var name = ""
    @State private var url = ""
    @State private var speed = 1.0

    var body: some View {
        Form {
            Section("Navigation") {
                Toggle("Always show tabs", isOn: $coordinator.alwaysShowTabs)
                Defaults.Toggle("Show settings button in notch", key: .settingsIconInNotch)
            }
            Section("Player") {
                Defaults.Toggle("Tint text with album artwork", key: .playerColorTinting)
                Defaults.Toggle("Glow behind artwork", key: .lightingEffect)
                Defaults.Toggle("Color the visualizer", key: .coloredSpectrogram)
                Picker("Progress color", selection: $sliderColor) {
                    ForEach(SliderColorEnum.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            }
            Section {
                Picker("Music activity", selection: $useMusicVisualizer) {
                    Text("Animated bars").tag(true)
                    Text("Lottie animation").tag(false)
                }
                if !useMusicVisualizer {
                    Picker("Animation", selection: $selectedVisualizer) {
                        Text("Built-in animation").tag(Optional<CustomVisualizer>.none)
                        ForEach(customVisualizers, id: \.UUID) { visualizer in
                            Text(visualizer.name).tag(Optional(visualizer))
                        }
                    }
                }
                if reduceMotion {
                    Label("Reduce Motion is enabled in macOS. Visualizers use a still frame.", systemImage: "accessibility")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Closed music activity") }
            Section {
                if customVisualizers.isEmpty {
                    Text("Add a Lottie JSON animation to use it beside the notch.")
                        .foregroundStyle(.secondary)
                }
                ForEach(customVisualizers, id: \.UUID) { visualizer in
                    HStack(spacing: 12) {
                        LottieView(url: visualizer.url, speed: visualizer.speed, loopMode: .loop)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(visualizer.name)
                            Text(visualizer.url.host ?? visualizer.url.lastPathComponent)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if selectedVisualizer?.UUID == visualizer.UUID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint).accessibilityLabel("Selected animation")
                        }
                        Button("Remove", systemImage: "trash", role: .destructive) { remove(visualizer) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Remove \(visualizer.name)")
                            .accessibilityLabel("Remove \(visualizer.name)")
                    }
                    .padding(.vertical, 3)
                }
                Button("Add Animation…", systemImage: "plus") {
                    name = ""; url = ""; speed = 1
                    addingVisualizer = true
                }
            } header: { Text("Custom animations") }
            Section("Extras") {
                Defaults.Toggle("Enable camera mirror", key: .showMirror)
                    .disabled(AVCaptureDevice.default(for: .video) == nil)
                Picker("Mirror shape", selection: $mirrorShape) {
                    Text("Circular").tag(MirrorShapeEnum.circle)
                    Text("Rectangular").tag(MirrorShapeEnum.rectangle)
                }
                Defaults.Toggle("Show face while idle", key: .showNotHumanFace)
            }
        }
        .formStyle(.grouped)
        .onAppear { validateSelection() }
        .onChange(of: customVisualizers) { _, values in
            validateSelection()
        }
        .sheet(isPresented: $addingVisualizer) { addVisualizerSheet }
    }

    private var addVisualizerSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Animation").font(.title2.bold())
            Text("Use a public HTTP or HTTPS link to a Lottie JSON file.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name", text: $name)
            TextField("Animation URL", text: $url)
            if !url.isEmpty && SettingsInputValidation.visualizerURL(url) == nil {
                Label("Enter a complete web URL, such as https://example.com/music.json.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }
            LabeledContent("Playback speed") {
                Slider(value: $speed, in: 0...2, step: 0.1)
                    .accessibilityLabel("Playback speed")
                Text("\(speed, specifier: "%.1f")×").monospacedDigit().frame(width: 40)
            }
            HStack {
                Spacer()
                Button("Cancel") { addingVisualizer = false }.keyboardShortcut(.cancelAction)
                Button("Add") { addVisualizer() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || SettingsInputValidation.visualizerURL(url) == nil)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 440)
    }

    private func addVisualizer() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let validatedURL = SettingsInputValidation.visualizerURL(url) else { return }
        customVisualizers.append(CustomVisualizer(UUID: UUID(), name: title, url: validatedURL, speed: CGFloat(speed)))
        addingVisualizer = false
    }

    private func remove(_ visualizer: CustomVisualizer) {
        customVisualizers.removeAll { $0.UUID == visualizer.UUID }
        if selectedVisualizer?.UUID == visualizer.UUID { selectedVisualizer = nil }
    }

    private func validateSelection() {
        if let selected = selectedVisualizer, !customVisualizers.contains(where: { $0.UUID == selected.UUID }) {
            selectedVisualizer = nil
        }
    }
}
