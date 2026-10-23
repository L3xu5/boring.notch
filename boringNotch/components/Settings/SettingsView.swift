import BoringCore
import Defaults
import Sparkle
import SwiftUI

struct SettingsView: View {
    @AppStorage("settings.destination") private var savedDestination = SettingsDestination.general.rawValue
    @Default(.useCustomAccentColor) private var useCustomAccentColor
    @Default(.customAccentColorData) private var customAccentColorData
    @State private var selectedDestination: SettingsDestination?
    @State private var search = ""

    private let updaterController: SPUStandardUpdaterController

    init(updaterController: SPUStandardUpdaterController? = nil) {
        _selectedDestination = State(initialValue: SettingsDestination(
            rawValue: UserDefaults.standard.string(forKey: "settings.destination") ?? SettingsDestination.general.rawValue
        ) ?? .general)
        self.updaterController = updaterController ?? SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
    }

    private var matches: [SettingsDestination] {
        SettingsDestination.allCases.filter { destination in
            let localized = [destination.title, destination.summary, destination.group.rawValue]
                .map { NSLocalizedString($0, comment: "Settings navigation") }.joined(separator: " ")
            return destination.matches(search, localizedText: localized)
        }
    }

    private var accent: Color {
        // Observe the stored accent directly: updating a color must not recreate
        // the navigation tree, dismiss sheets, or discard account-entry drafts.
        _ = useCustomAccentColor
        _ = customAccentColorData
        return .effectiveAccent
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedDestination) {
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    let destinations = matches.filter { $0.group == group }
                    if !destinations.isEmpty {
                        Section(LocalizedStringKey(group.rawValue)) {
                            ForEach(destinations) { destination in
                                Label(LocalizedStringKey(destination.title), systemImage: destination.icon)
                                    .tag(destination)
                                    .help(Text(LocalizedStringKey(destination.summary)))
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 260)
        } detail: {
            if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResults
            } else {
                let destination = selectedDestination ?? .general
                VStack(alignment: .leading, spacing: 0) {
                    SettingsPageHeader(destination: destination)
                    Divider()
                    page(destination)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .navigationTitle(LocalizedStringKey(destination.title))
            }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, prompt: "Find a setting")
        .formStyle(.grouped)
        .tint(accent)
        .frame(minWidth: 680, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: selectedDestination) { _, destination in
            if let destination { savedDestination = destination.rawValue }
        }
    }

    private var searchResults: some View {
        Group {
            if matches.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    Section("Matching settings") {
                        ForEach(matches) { destination in
                            Button {
                                selectedDestination = destination
                                search = ""
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: destination.icon)
                                        .font(.title3)
                                        .foregroundStyle(.tint)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(LocalizedStringKey(destination.title)).font(.headline)
                                        Text(LocalizedStringKey(destination.summary))
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .navigationTitle("Search Settings")
        .toolbar {
            Button("Clear Search", systemImage: "xmark.circle") { search = "" }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func page(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .general: GeneralSettings()
        case .appearance: Appearance()
        case .media: Media()
        case .calendar: CalendarSettings()
        case .hud: HUD()
        case .battery: Charge()
        case .shelf: Shelf()
        case .shortcuts: Shortcuts()
        case .advanced: Advanced()
        case .about: About(updaterController: updaterController)
        }
    }
}

private struct SettingsPageHeader: View {
    let destination: SettingsDestination

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: destination.icon)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(Color.effectiveAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(destination.title))
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(LocalizedStringKey(destination.summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}
