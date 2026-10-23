import Foundation

public enum SettingsGroup: String, CaseIterable, Hashable, Sendable {
    case experience = "Experience"
    case features = "Features"
    case application = "Application"
}

/// Stable navigation identifiers are independent of display labels and stored preferences.
public enum SettingsDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, appearance, media, calendar, hud, battery, shelf, shortcuts, advanced, about

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .media: "Media"
        case .calendar: "Calendar"
        case .hud: "System HUD"
        case .battery: "Battery"
        case .shelf: "Shelf"
        case .shortcuts: "Shortcuts"
        case .advanced: "Advanced"
        case .about: "About & Updates"
        }
    }

    public var icon: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .media: "music.note"
        case .calendar: "calendar"
        case .hud: "dial.medium"
        case .battery: "battery.100.bolt"
        case .shelf: "tray"
        case .shortcuts: "keyboard"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    public var group: SettingsGroup {
        switch self {
        case .general, .appearance, .media: .experience
        case .calendar, .hud, .battery, .shelf: .features
        case .shortcuts, .advanced, .about: .application
        }
    }

    public var summary: String {
        switch self {
        case .general: "Startup, displays, and how the notch opens."
        case .appearance: "Player styling, animations, and the mirror."
        case .media: "Choose a player, arrange controls, and connect lyrics."
        case .calendar: "Events, reminders, and the calendars you share with the notch."
        case .hud: "Volume and brightness controls with permission status."
        case .battery: "Power notifications and battery information."
        case .shelf: "Drag, store, and share files."
        case .shortcuts: "Keyboard commands for the notch and your selected player."
        case .advanced: "Accent colors, privacy, and window behavior."
        case .about: "Version information, automatic updates, and project links."
        }
    }

    private var keywords: String {
        switch self {
        case .general: "system features launch startup login menu bar icon hover open close delay gestures sensitivity screen display monitor preferred automatic automatically switch all notch height size custom real match menubar haptic feedback remember last tab"
        case .appearance: "navigation tabs settings icon music player text color colour artwork glow visualizer spectrum animated bars lottie animation JSON URL name speed blur mirror camera shape circular rectangular face idle slider progress tint labels reduce motion accessibility"
        case .media: "Yandex Spotify Apple Music YouTube Now Playing source account OAuth token accessibility permission lyrics karaoke offset delay timing sync synchronized favorite dislike shuffle repeat volume controls slots visible layout reset inactivity timeout live activity sneak peek full screen fullscreen hide seek skip backward forward position"
        case .calendar: "events reminders permission access calendars all day completed titles auto scroll"
        case .hud: "replace system HUD accessibility permission access volume brightness keyboard light backlight option key behavior progress glow shadow accent tint open closed default inline percentage gradient"
        case .battery: "power charge charging percentage indicator notification"
        case .shelf: "file drag drop copy remove quick share AirDrop provider"
        case .shortcuts: "keyboard hotkey play pause next previous like dislike toggle"
        case .advanced: "accent color custom system preset blue purple pink red orange yellow green graphite theme window shadow corner radius scaling lock screen recording privacy extend hover area title bar"
        case .about: "version build release name automatic automatically check update download GitHub fork original project credits license"
        }
    }

    public func matches(_ query: String, localizedText: String = "") -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        let haystack = "\(title) \(summary) \(keywords) \(localizedText) show hide enable disable use settings"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return terms.allSatisfy { term in
            haystack.contains(String(term).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }
}

public enum SettingsInputValidation {
    public static func visualizerURL(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else { return nil }
        return url
    }
}
