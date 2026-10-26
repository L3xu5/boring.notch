import Foundation
import ApplicationServices

protocol YandexAccessibilityProviding: Sendable {
    func read(processIdentifier: pid_t) async -> YandexAccessibilityMetadata?
    func perform(_ action: YandexPlayerAction, processIdentifier: pid_t,
                 isCurrent: @escaping @Sendable () -> Bool) async -> Bool
    func favoriteState(processIdentifier: pid_t) async -> Bool?
}

/// The AX worker checks the same ticket immediately before its native side effect. MainActor
/// can invalidate it while a blocking AX lookup is in progress, without an actor round-trip.
final class YandexCommandLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    func ticket() -> UUID { lock.withLock { generation } }
    func invalidate() { lock.withLock { generation = UUID() } }
    func isCurrent(_ ticket: UUID) -> Bool { lock.withLock { generation == ticket } }
}

struct YandexAccessibilityNode: Decodable, Sendable {
    let role: String
    let labels: [String]
    let value: String?
    let url: URL?
    let children: [YandexAccessibilityNode]
}

/// A toggle's label describes the action in both states. Only its explicit AX value
/// confirms a like; Chromium exposes mixed/indeterminate as 2, not as true.
enum YandexLikeState {
    static func isLikeControl(role: String, labels: [String]) -> Bool {
        guard ["AXButton", "AXCheckBox"].contains(role) else { return false }
        let names: Set<String> = ["like", "нравится", "мне нравится", "ұнайды", "yoqadi"]
        return labels.contains { names.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    static func decode(_ value: String?) -> Bool? {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true": return true
        case "0", "false": return false
        default: return nil
        }
    }

    static func decodeAXValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            switch number.doubleValue {
            case 0: return false
            case 1: return true
            default: return nil
            }
        }
        return decode(value as? String)
    }
}

struct YandexAccessibilityMetadata: Sendable {
    let title: String
    let artist: String
    let album: String
    let trackID: String?
    let artworkURL: URL?
    let isPlaying: Bool?
    let isFavorite: Bool?

    init?(root: YandexAccessibilityNode) {
        var nodes: [YandexAccessibilityNode] = []
        func visit(_ node: YandexAccessibilityNode) { nodes.append(node); node.children.forEach(visit) }
        visit(root)
        func text(_ node: YandexAccessibilityNode, prefixes: [String]) -> String {
            for label in node.labels {
                for prefix in prefixes where label.lowercased().hasPrefix(prefix) {
                    return String(label.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            if let value = node.value, !value.isEmpty { return value }
            return node.children.compactMap { $0.value }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        let tracks = nodes.filter { node in
            node.role == "AXLink" && ((node.url.map(Self.isEntityURL) == true && node.url?.path.contains("/track/") == true)
                || node.labels.contains { $0.lowercased().hasPrefix("track ") || $0.lowercased().hasPrefix("трек ") })
        }
        let titles = tracks.map { text($0, prefixes: ["track ", "трек "]) }.filter { !$0.isEmpty }
        // A whole library/list is not the persistent player bar. Never borrow a random row's title.
        let trackPaths = Set(tracks.compactMap { $0.url }.filter(Self.isEntityURL).map(\.path))
        guard let title = titles.first, Set(titles).count == 1, trackPaths.count <= 1 else { return nil }
        let track = tracks.first { $0.url.map(Self.isEntityURL) == true && $0.url?.path.contains("/track/") == true }
        let components = track?.url?.pathComponents ?? []
        let id = components.firstIndex(of: "track").flatMap { $0 + 1 < components.count ? components[$0 + 1] : nil }
        self.trackID = id.flatMap { !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) ? $0 : nil }
        self.title = title
        var artists: [String] = []
        for node in nodes where node.role == "AXLink" && node.url.map(Self.isEntityURL) == true && node.url?.path.contains("/artist/") == true {
            let name = text(node, prefixes: ["artist ", "артист ", "исполнитель "])
            if !name.isEmpty && !artists.contains(name) { artists.append(name) }
        }
        artist = artists.joined(separator: ", ")
        album = nodes.first { $0.role == "AXLink" && $0.url.map(Self.isEntityURL) == true && $0.url?.path.contains("/album/") == true
            && $0.url?.path.contains("/track/") != true }
            .map { text($0, prefixes: ["album ", "альбом "]) } ?? ""
        artworkURL = nodes.lazy.filter { $0.role == "AXImage" }.compactMap(\.url)
            .first(where: Self.isTrustedArtworkURL)
        let controls = nodes.filter { ["AXButton", "AXCheckBox"].contains($0.role) }
            .flatMap(\.labels).map { $0.lowercased() }
        if controls.contains(where: { $0 == "pause" || $0.contains("пауза") || $0.contains("приостанов") }) { isPlaying = true }
        else if controls.contains(where: { $0 == "play" || $0 == "playback" || $0.contains("воспроизвед") || $0 == "продолжить" }) { isPlaying = false }
        else { isPlaying = nil }
        let likes = nodes.filter { YandexLikeState.isLikeControl(role: $0.role, labels: $0.labels) }
        let values = likes.compactMap { YandexLikeState.decode($0.value) }
        // Multiple rendered controls must agree, and an unknown value cannot establish true.
        isFavorite = !likes.isEmpty && values.count == likes.count && Set(values).count == 1 ? values.first : nil
    }

    static func isEntityURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        if url.scheme?.lowercased() == "music-application", url.host?.lowercased() == "desktop" { return true }
        return url.scheme?.lowercased() == "https"
            && ["music.yandex.ru", "music.yandex.com", "music.yandex.by", "music.yandex.kz", "music.yandex.uz"].contains(url.host?.lowercased() ?? "")
    }

    static func isTrustedArtworkURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && ["avatars.yandex.net", "avatars.mds.yandex.net"].contains(url.host?.lowercased() ?? "")
    }
}

/// All AX IPC and tree walking stays on this actor's executor, away from hover/UI updates.
actor YandexAccessibilityClient: YandexAccessibilityProviding {
    private var cachedTransportCluster: AXUIElement?
    private var controlDeadline = Date.distantFuture
    private var actionIsCurrent: @Sendable () -> Bool = { true }
    private var cachedBar: AXUIElement?
    private var cachedPID: pid_t?
    private var nextSearch = Date.distantPast

    private func attributes(_ element: AXUIElement) -> (node: YandexAccessibilityNode, children: [AXUIElement])? {
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXURLAttribute, kAXChildrenAttribute, kAXEnabledAttribute]
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &raw) == .success,
              let values = raw as? [Any], values.count == names.count, let role = values[0] as? String else { return nil }
        let url = (values[4] as? URL) ?? (values[4] as? String).flatMap(URL.init(string:))
        let labels = [values[1] as? String, values[2] as? String].compactMap { $0 }.filter { !$0.isEmpty }
        var value = values[3] as? String
        if ["AXButton", "AXCheckBox"].contains(role) {
            value = (values[6] as? NSNumber)?.boolValue == false ? nil
                : YandexLikeState.decodeAXValue(values[3]).map { $0 ? "1" : "0" }
        }
        return (.init(role: role, labels: labels, value: value, url: url, children: []), values[5] as? [AXUIElement] ?? [])
    }

    private func tree(_ element: AXUIElement, remaining: inout Int, deadline: Date, depth: Int = 0) -> YandexAccessibilityNode? {
        guard !Task.isCancelled, remaining > 0, depth < 18, Date() < deadline,
              let (node, children) = attributes(element) else { return nil }
        remaining -= 1
        var descendants: [YandexAccessibilityNode] = []
        for child in children {
            guard let snapshot = tree(child, remaining: &remaining, deadline: deadline, depth: depth + 1) else { return nil }
            descendants.append(snapshot)
        }
        return .init(role: node.role, labels: node.labels, value: node.value, url: node.url, children: descendants)
    }

    private func nextButton(_ element: AXUIElement, remaining: inout Int, deadline: Date, depth: Int = 0) -> AXUIElement? {
        guard !Task.isCancelled, remaining > 0, depth < 60, Date() < deadline,
              let (node, children) = attributes(element) else { return nil }
        remaining -= 1
        if node.role == "AXButton", node.labels.contains(where: { label in
            let label = label.lowercased()
            return ["next", "next song", "next track"].contains(label) || label.contains("следующ")
        }) { return element }
        for child in children {
            if let found = nextButton(child, remaining: &remaining, deadline: deadline, depth: depth + 1) { return found }
        }
        return nil
    }

    func read(processIdentifier: pid_t) -> YandexAccessibilityMetadata? {
        guard AXIsProcessTrusted(), !Task.isCancelled else { return nil }
        prepare(processIdentifier)
        if let cachedBar {
            var budget = 500
            if let node = tree(cachedBar, remaining: &budget, deadline: Date().addingTimeInterval(0.25)),
               let metadata = YandexAccessibilityMetadata(root: node) { return metadata }
            self.cachedBar = nil
            nextSearch = .distantPast
        }
        guard Date() >= nextSearch else { return nil }
        nextSearch = Date().addingTimeInterval(5)
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var budget = 6000
        guard let next = nextButton(application, remaining: &budget, deadline: Date().addingTimeInterval(1)) else { return nil }
        var candidate = next
        var best: (AXUIElement, YandexAccessibilityMetadata)?
        for _ in 0..<7 {
            var parent: CFTypeRef?
            guard !Task.isCancelled, AXUIElementCopyAttributeValue(candidate, kAXParentAttribute as CFString, &parent) == .success,
                  let parent else { break }
            candidate = parent as! AXUIElement
            guard let (node, _) = attributes(candidate), !["AXWebArea", "AXWindow", "AXApplication"].contains(node.role) else { break }
            var budget = 500
            if let snapshot = tree(candidate, remaining: &budget, deadline: Date().addingTimeInterval(0.25)),
               let metadata = YandexAccessibilityMetadata(root: snapshot) {
                best = (candidate, metadata)
                if metadata.isFavorite != nil {
                    cachedBar = candidate
                    return metadata
                }
            }
        }
        if let (element, metadata) = best { cachedBar = element; return metadata }
        return nil
    }
}

extension YandexAccessibilityClient {
    // Label matchers. Exact labels are compared whole (lowercased); "contains" fragments are
    // substring-matched. The play/pause matcher deliberately avoids a bare "play" fragment so
    // it never hits a "Play queue"-style control that also contains the word.
    fileprivate static let playPauseExact = ["playback", "play", "pause"]
    fileprivate static let playPauseContains = ["воспроизвед", "пауза", "приостанов", "играть", "продолж"]
    fileprivate static let nextExact = ["next", "next song", "next track"]
    fileprivate static let nextContains = ["следующ", "вперёд", "вперед"]
    fileprivate static let previousExact = ["previous", "previous song", "previous track"]
    fileprivate static let previousContains = ["предыдущ", "назад"]

    // Dislike is a different action from the explicitly matched Like toggle.
    private static let dislikeLabelHints = ["don't like", "dont like", "dislike", "не нравится"]

    // MARK: Transport

    /// Presses a transport control inside Yandex's bottom now-playing bar. Returns true on a
    /// successful press; false if Accessibility is unavailable or the control wasn't found.
    func pressTransport(exact: [String], contains: [String]) -> Bool {
        // Anchor on the now-playing bar so we never match the many track-row "Playback"/"Like"
        // controls that live elsewhere in the list.
        guard AXIsProcessTrusted(), let cluster = transportCluster() else { return false }

        var visited = 0
        guard let button = firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.matchesControl($0, exact: exact, contains: contains) }
        ) else { return false }

        guard !Task.isCancelled, Date() < controlDeadline, actionIsCurrent() else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    // MARK: Like

    @discardableResult
    func pressLikeButton() -> Bool {
        guard AXIsProcessTrusted() else {
            NSLog("[YandexMusic] Accessibility permission not granted; cannot toggle like.")
            return false
        }
        guard let button = findLikeButton() else {
            NSLog("[YandexMusic] Like button not found in accessibility tree.")
            return false
        }
        guard !Task.isCancelled, Date() < controlDeadline, actionIsCurrent() else { return false }
        let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
        if result != .success {
            NSLog("[YandexMusic] Failed to press like button (AX error \(result.rawValue)).")
        }
        return result == .success
    }

    /// Returns the current like state if it can be determined, otherwise nil.
    func readLikeState() -> Bool? {
        guard AXIsProcessTrusted(), let button = findLikeButton() else { return nil }

        // The like toggle exposes its pressed state via kAXValueAttribute (1 = liked, 0 = not).
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(button, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return YandexLikeState.decodeAXValue(value)
    }

    private func findLikeButton() -> AXUIElement? {
        // The now-playing like control lives inside the bottom bar; anchoring there (as the
        // transport code does) excludes the per-row like buttons in the track list.
        guard let cluster = transportCluster() else { return nil }
        var visited = 0
        return firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.isLikeButton($0) }
        )
    }

    func pressDislikeButton() {
        guard AXIsProcessTrusted() else {
            NSLog("[YandexMusic] Accessibility permission not granted; cannot dislike.")
            return
        }
        guard let cluster = transportCluster() else { return }
        var visited = 0
        guard let button = firstDescendant(
            in: cluster, depth: 0, visited: &visited, maxDepth: 25, maxVisited: 2000,
            where: { self.isDislikeButton($0) }
        ) else {
            NSLog("[YandexMusic] Dislike button not found in accessibility tree.")
            return
        }
        guard !Task.isCancelled, Date() < controlDeadline, actionIsCurrent() else { return }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func isDislikeButton(_ element: AXUIElement) -> Bool {
        guard isPressableControl(element) else { return false }
        let labels = axLabels(element)
        guard !labels.isEmpty else { return false }
        return labels.contains { label in Self.dislikeLabelHints.contains(where: label.contains) }
    }

    // MARK: Element access & search

    /// Returns the application AX element for Yandex Music with Chromium's web-content
    /// accessibility tree enabled, or nil when the app isn't running.
    private func yandexAppElement() -> AXUIElement? {
        guard let cachedPID else { return nil }
        let app = AXUIElementCreateApplication(cachedPID)
        AXUIElementSetMessagingTimeout(app, 0.1)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return app
    }

    /// The persistent bottom now-playing bar's control container, reused from the cache when it
    /// is still valid, otherwise re-located.
    ///
    /// It is found by locating a "Next song" button — which exists only in the now-playing bar,
    /// never in the track rows — and walking up to the nearest ancestor that also contains a
    /// "Previous song" button. That ancestor is the transport cluster; it holds exactly one each
    /// of play/pause, prev, next and like, so subsequent searches are unambiguous. (The main
    /// page's central player has these too; either container works, since we only ever press.)
    private func transportCluster() -> AXUIElement? {
        if let bar = cachedBar, isTransportCluster(bar) { return bar }
        if let cached = cachedTransportCluster, isTransportCluster(cached) {
            return cached
        }
        cachedTransportCluster = nil

        guard let appElement = yandexAppElement() else { return nil }
        var visited = 0
        guard let next = firstDescendant(
            in: appElement, depth: 0, visited: &visited, maxDepth: 60, maxVisited: 8000,
            where: { self.matchesControl($0, exact: Self.nextExact, contains: Self.nextContains) }
        ) else { return nil }

        var node: AXUIElement? = axParent(next)
        var hops = 0
        while let candidate = node, hops < 8 {
            if isTransportCluster(candidate) {
                cachedTransportCluster = candidate
                return candidate
            }
            node = axParent(candidate)
            hops += 1
        }
        return nil
    }

    /// True when `element`'s subtree contains both a "Next song" and a "Previous song" control —
    /// the signature of the now-playing bar's transport cluster.
    private func isTransportCluster(_ element: AXUIElement) -> Bool {
        var v1 = 0
        let hasNext = firstDescendant(
            in: element, depth: 0, visited: &v1, maxDepth: 12, maxVisited: 400,
            where: { self.matchesControl($0, exact: Self.nextExact, contains: Self.nextContains) }
        ) != nil
        guard hasNext else { return false }
        var v2 = 0
        return firstDescendant(
            in: element, depth: 0, visited: &v2, maxDepth: 12, maxVisited: 400,
            where: { self.matchesControl($0, exact: Self.previousExact, contains: Self.previousContains) }
        ) != nil
    }

    /// Bounded depth-first search returning the first descendant (or `element` itself) that
    /// satisfies `predicate`.
    private func firstDescendant(
        in element: AXUIElement,
        depth: Int,
        visited: inout Int,
        maxDepth: Int,
        maxVisited: Int,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if Task.isCancelled || Date() >= controlDeadline || depth > maxDepth || visited > maxVisited { return nil }
        visited += 1

        if predicate(element) { return element }

        guard let children: [AXUIElement] = axAttribute(element, kAXChildrenAttribute) else { return nil }
        for child in children {
            if let found = firstDescendant(
                in: child, depth: depth + 1, visited: &visited,
                maxDepth: maxDepth, maxVisited: maxVisited, where: predicate) {
                return found
            }
        }
        return nil
    }

    // MARK: Predicates

    private func axParent(_ element: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &raw) == .success,
              let value = raw else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func matchesControl(_ element: AXUIElement, exact: [String], contains: [String]) -> Bool {
        guard isPressableControl(element) else { return false }
        let labels = axLabels(element)
        guard !labels.isEmpty else { return false }
        // Match per-attribute: an exact token must equal one whole attribute (e.g. AXDescription
        // "playback"), a contains token need only be a substring of some attribute. Matching the
        // concatenation would break as soon as a node also exposes an empty/secondary attribute.
        if labels.contains(where: exact.contains) { return true }
        return labels.contains { label in contains.contains(where: label.contains) }
    }

    private func isLikeButton(_ element: AXUIElement) -> Bool {
        guard let role: String = axAttribute(element, kAXRoleAttribute) else { return false }
        return YandexLikeState.isLikeControl(role: role, labels: axLabels(element))
    }

    private func isPressableControl(_ element: AXUIElement) -> Bool {
        let role: String? = axAttribute(element, kAXRoleAttribute)
        return role == (kAXButtonRole as String)
            || role == "AXCheckBox"
            || role == (kAXRadioButtonRole as String)
            || role == (kAXMenuButtonRole as String)
    }

    /// The element's individual, non-empty, lowercased text labels
    /// (description/title/identifier/help). Kept as separate entries — not concatenated — so
    /// exact matching isn't defeated by empty or secondary attributes.
    private func axLabels(_ element: AXUIElement) -> [String] {
        [
            axAttribute(element, kAXDescriptionAttribute) as String?,
            axAttribute(element, kAXTitleAttribute) as String?,
            axAttribute(element, kAXIdentifierAttribute) as String?,
            axAttribute(element, kAXHelpAttribute) as String?,
        ]
        .compactMap { $0 }
        .map { $0.lowercased() }
        .filter { !$0.isEmpty }
    }

    // Generic AX attribute reader for String, Int and [AXUIElement].
    private func axAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success,
              let value = raw else {
            return nil
        }
        if let typed = value as? T { return typed }
        // aria-pressed / toggle state comes back as a CFNumber; bridge to Int when requested.
        if T.self == Int.self, let number = value as? NSNumber { return number.intValue as? T }
        return nil
    }
}

enum YandexPlayerAction: Sendable { case playPause, next, previous, like, dislike }

extension YandexAccessibilityClient {
    private func prepare(_ processIdentifier: pid_t) {
        if cachedPID != processIdentifier {
            cachedBar = nil; cachedTransportCluster = nil; nextSearch = .distantPast; cachedPID = processIdentifier
        }
    }
    func perform(_ action: YandexPlayerAction, processIdentifier: pid_t,
                 isCurrent: @escaping @Sendable () -> Bool) -> Bool {
        prepare(processIdentifier)
        actionIsCurrent = isCurrent
        controlDeadline = Date().addingTimeInterval(1)
        guard AXIsProcessTrusted(), !Task.isCancelled, isCurrent() else { return false }
        switch action {
        case .playPause: return pressTransport(exact: Self.playPauseExact, contains: Self.playPauseContains)
        case .next: return pressTransport(exact: Self.nextExact, contains: Self.nextContains)
        case .previous: return pressTransport(exact: Self.previousExact, contains: Self.previousContains)
        case .like: return pressLikeButton()
        case .dislike: pressDislikeButton(); return true
        }
    }
    func favoriteState(processIdentifier: pid_t) -> Bool? {
        prepare(processIdentifier)
        controlDeadline = Date().addingTimeInterval(1)
        return readLikeState()
    }
}
