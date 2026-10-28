import Foundation

@main
private enum YandexFavoriteAXTests {
    private static var checks = 0
    private static var failures: [String] = []
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    private static func node(_ role: String, _ labels: [String] = [], value: String? = nil,
                             url: String? = nil, children: [YandexAccessibilityNode] = []) -> YandexAccessibilityNode {
        .init(role: role, labels: labels, value: value, url: url.flatMap(URL.init(string:)), children: children)
    }
    private static func metadata(_ controls: [YandexAccessibilityNode]) -> YandexAccessibilityMetadata? {
        .init(root: node("AXGroup", children: [
            node("AXLink", ["Track Fixture"], url: "https://music.yandex.ru/album/1/track/2"),
            node("AXLink", ["Artist Fixture artist"], url: "https://music.yandex.ru/artist/3"),
        ] + controls))
    }

    private static func routeMetadata(_ track: String, favorite: String? = "0") -> YandexAccessibilityMetadata? {
        .init(root: node("AXGroup", children: [
            // These are the actual renderer's unprefixed labels and query-based entity routes.
            node("AXLink", ["Native title"], url: track),
            node("AXLink", ["Native artist"], url: "music-application://desktop/artist?artistId=3"),
            node("AXLink", ["Native album"], url: "music-application://desktop/album?albumId=1"),
            node("AXCheckBox", ["Like"], value: favorite),
            node("AXButton", ["Pause"]),
        ]))
    }

    private static func entityRoutes() {
        let valid: [(String, String, String)] = [
            ("music-application://desktop/track?trackId=2", "track", "2"),
            ("music-application://desktop/album/track?albumId=1&trackId=2", "track", "2"),
            ("music-application://desktop/artist?artistId=3", "artist", "3"),
            ("music-application://desktop/album?albumId=1", "album", "1"),
            ("music-application://desktop/album/track?trackId=2&albumId=1", "track", "2"),
            ("music-application://desktop/track?trackId=%32&from=player", "track", "2"),
            ("MUSIC-APPLICATION://DESKTOP/track?TRACKID=2", "track", "2"),
            ("music-application://desktop/album/1/track/2", "track", "2"),
            ("music-application://desktop/artist/3", "artist", "3"),
            ("music-application://desktop/album/1", "album", "1"),
            ("https://music.yandex.ru/album/1/track/2", "track", "2"),
            ("https://music.yandex.com/track/2", "track", "2"),
            ("https://music.yandex.kz/artist/3", "artist", "3"),
            ("https://music.yandex.by/album/1", "album", "1"),
        ]
        for (address, kind, expected) in valid {
            expect(YandexAccessibilityMetadata.entityID(in: URL(string: address)!, kind: kind) == expected,
                   "Valid \(kind) route lost its ID: \(address)")
        }
        for address in [
            "music-application://desktop/track?trackId=2",
            "music-application://desktop/album/track?albumId=1&trackId=2",
        ] {
            let parsed = routeMetadata(address)
            expect(parsed?.trackID == "2" && parsed?.title == "Native title", "Native track query URL did not identify the player: \(address)")
            expect(parsed?.artist == "Native artist" && parsed?.album == "Native album", "Native artist/album query labels were omitted")
            expect(parsed?.isFavorite == false && parsed?.isPlaying == true, "Query route metadata lost its explicit control states")
        }
        let invalid = [
            "music-application://desktop/track?trackId",
            "music-application://desktop/track?trackId=",
            "music-application://desktop/track?trackId=-2",
            "music-application://desktop/track?trackId=2.5",
            "music-application://desktop/track?trackId=2x",
            "music-application://desktop/track?trackId=1e3",
            "music-application://desktop/track?trackId=%EF%BC%92",
            "music-application://desktop/track?trackId=2%2F3",
            "music-application://desktop/track?artistId=2",
            "music-application://desktop/artist?trackId=2",
            "music-application://desktop/track/-2",
            "music-application://desktop/track/2x",
            "music-application://desktop/track?trackId=2&trackId=3",
            "music-application://desktop/track?trackId=2&trackId=2",
            "music-application://desktop/track?trackId&trackId=2",
            "music-application://desktop/track?trackId=2&trackId",
            "music-application://desktop/track?TRACKID=2&trackId",
            "music-application://desktop/track/2?trackId=3",
            "music-application://desktop/album/1/track/2?trackId=3",
            "music-application://desktop/track/2/track/3",
            "https://music.yandex.ru/track/2?trackId=3",
            "https://evil.example/track/2",
            "https://music.yandex.ru.evil.example/track/2",
            "http://music.yandex.ru/track/2",
            "https://user:password@music.yandex.ru/track/2",
            "https://music.yandex.ru:444/track/2",
            "music-application://evil.example/track?trackId=2",
            "music-application://desktop:80/track?trackId=2",
            "file:///track/2",
        ]
        for address in invalid {
            expect(YandexAccessibilityMetadata.entityID(in: URL(string: address)!, kind: "track") == nil,
                   "Invalid/ambiguous/external track route supplied an ID: \(address)")
        }
        for kind in ["artist", "album"] {
            let key = kind + "Id"
            for query in ["\(key)=2&\(key)=3", "\(key)&\(key)=2", "\(key)=", "\(key)=-2"] {
                let address = "music-application://desktop/\(kind)?\(query)"
                expect(YandexAccessibilityMetadata.entityID(in: URL(string: address)!, kind: kind) == nil,
                       "Invalid/ambiguous \(kind) query supplied an ID: \(address)")
            }
        }
        for address in ["music-application://evil.example/track?trackId=2", "https://evil.example/track/2"] {
            expect(routeMetadata(address) == nil, "An external link with an unprefixed title was accepted as player metadata")
        }
        let ambiguous = node("AXGroup", children: [
            node("AXLink", ["Native title"], url: "music-application://desktop/track?trackId=2"),
            node("AXLink", ["Native title"], url: "music-application://desktop/album/track?albumId=1&trackId=3"),
            node("AXCheckBox", ["Like"], value: "1"),
        ])
        expect(YandexAccessibilityMetadata(root: ambiguous) == nil, "Different native query IDs with the same title established a favorite")
        let equivalent = node("AXGroup", children: [
            node("AXLink", ["Native title"], url: "music-application://desktop/track?trackId=2"),
            node("AXLink", ["Native title"], url: "https://music.yandex.ru/album/1/track/2"),
            node("AXCheckBox", ["Like"], value: "1"),
        ])
        expect(YandexAccessibilityMetadata(root: equivalent)?.trackID == "2", "Two representations of one recording were mistaken for ambiguous tracks")
    }

    private static func targetMatching() {
        guard let parsed = routeMetadata("music-application://desktop/track?trackId=2", favorite: nil) else {
            expect(false, "Native query fixture could not establish target identity")
            return
        }
        expect(YandexFavoriteTarget(trackID: "2", title: "Different localized title", artist: "").matches(parsed),
               "An exact trusted recording ID was defeated by partial or localized metadata")
        expect(!YandexFavoriteTarget(trackID: "3", title: parsed.title, artist: parsed.artist).matches(parsed),
               "Different recording IDs matched through equal title/artist")
        expect(YandexFavoriteTarget(trackID: nil, title: "NÁTIVE TITLE!", artist: "native artist").matches(parsed),
               "Title/artist fallback lost its normalization")
        expect(!YandexFavoriteTarget(trackID: nil, title: "Other title", artist: parsed.artist).matches(parsed),
               "An unrelated title passed fallback target matching")
        expect(!YandexFavoriteTarget(trackID: nil, title: parsed.title, artist: "Other artist").matches(parsed),
               "An unrelated artist passed fallback target matching")
        expect(!YandexFavoriteTarget(trackID: nil, title: "", artist: parsed.artist).matches(parsed),
               "An empty displayed title authorized a favorite press")
        expect(parsed.isFavorite == nil && YandexFavoriteTarget(trackID: "2", title: "", artist: "").matches(parsed),
               "Unknown pressed state disabled an otherwise exact target match")
        let observedWithID = metadata([node("AXCheckBox", ["Like"])])!
        expect(YandexFavoriteTarget(trackID: nil, title: "fixture", artist: "fixture artist").matches(observedWithID),
               "Matching title/artist target was rejected")
        let labelOnly = YandexAccessibilityMetadata(root: node("AXGroup", children: [
            node("AXLink", ["Track Fixture"]),
            node("AXLink", ["Artist Fixture artist"], url: "music-application://desktop/artist?artistId=3"),
        ]))!
        expect(labelOnly.trackID == nil && YandexFavoriteTarget(trackID: "2", title: "Fixture", artist: "Fixture artist").matches(labelOnly),
               "Missing observed ID prevented a strict title/artist fallback")
        expect(!YandexFavoriteTarget(trackID: nil, title: "Fixture", artist: "").matches(labelOnly),
               "Missing artist evidence matched a nonempty observed artist")
    }
    private static func nativePlayerIdentity() {
        // MediaSession publishes the base title and artists joined with ", ". The
        // installed player renders the version in its ARIA label and a separate
        // span; each artist can be a link or a separate plain-text span.
        let target = YandexFavoriteTarget(trackID: nil, title: "Fixture song", artist: "Artist A, Artist B")
        func bar(artists: [YandexAccessibilityNode], visibleTitle: String = "Fixture song",
                 titleLabel: String = "Track Fixture song (Live)") -> YandexAccessibilityNode {
            node("AXGroup", children: [
                node("AXGroup", children: [
                    node("AXLink", [titleLabel], url: "music-application://desktop/track?trackId=42", children: [
                        node("AXStaticText", value: visibleTitle),
                    ]),
                    node("AXStaticText", value: " (Live)"),
                ]),
                node("AXGroup", children: artists),
                node("AXButton", ["Previous song"]), node("AXButton", ["Next song"]),
                node("AXCheckBox", ["Like"], value: "1"),
            ])
        }
        let linkedArtists = [
            node("AXLink", ["Artist Artist A"], url: "music-application://desktop/artist?artistId=1", children: [
                node("AXStaticText", value: "Artist A"),
            ]),
            node("AXStaticText", value: ", "),
            node("AXLink", ["Artist Artist B"], url: "music-application://desktop/artist?artistId=2", children: [
                node("AXStaticText", value: "Artist B"),
            ]),
        ]
        let staticArtists = [
            node("AXStaticText", value: "Artist A"), node("AXStaticText", value: ", "),
            node("AXStaticText", value: "Artist B"),
        ]
        let linked = bar(artists: linkedArtists)
        let parsed = YandexAccessibilityMetadata(root: linked)
        expect(parsed?.title == target.title, "The ARIA version replaced MediaSession's visible base title")
        expect(parsed?.artist == target.artist, "Separate artist links did not retain the complete ordered artist list")
        expect(parsed?.isFavorite == true, "Versioned multiartist metadata lost its explicit favorite value")
        expect(target.matches(root: linked), "A versioned title and separate artist links rejected the actual current track")
        let plain = bar(artists: staticArtists)
        expect(YandexAccessibilityMetadata(root: plain)?.title == target.title,
               "A plain artist group prevented reading the visible base title")
        expect(target.matches(root: plain), "A complete plain artist group was mistaken for a missing single-string artist")
        let mixed = bar(artists: [linkedArtists[0], node("AXStaticText", value: ", "), node("AXStaticText", value: "Artist B")])
        expect(target.matches(root: mixed), "A complete artist list split between a link and plain text was rejected")
        expect(!YandexFavoriteTarget(trackID: nil, title: target.title, artist: "Artist A").matches(root: mixed),
               "Partial linked metadata overrode a complete mixed artist list")
        expect(!YandexFavoriteTarget(trackID: nil, title: target.title, artist: "Artist A").matches(root: linked),
               "The first artist of a linked list authorized the whole multiartist recording")
        expect(!target.matches(root: bar(artists: [linkedArtists[0], node("AXStaticText", value: ", "),
                                                  node("AXStaticText", value: "Other artist")])),
               "Partial linked metadata hid a conflicting plain-text collaborator")
        expect(target.matches(root: bar(artists: staticArtists, titleLabel: "Трек Fixture song (Live)")),
               "A localized versioned ARIA label replaced the visible base title")
        expect(!target.matches(root: bar(artists: [])), "Missing artist evidence authorized a favorite action")
        expect(!target.matches(root: bar(artists: [node("AXStaticText", value: "Artist A")])),
               "A partial artist list authorized a multiartist favorite action")
        expect(!target.matches(root: bar(artists: [
            node("AXStaticText", value: "Artist A"), node("AXStaticText", value: ", "),
            node("AXStaticText", value: "Artist…"),
        ])), "A truncated artist list authorized a favorite action")
        expect(!target.matches(root: bar(artists: [node("AXStaticText", value: "Other artist")])),
               "The same title from another artist authorized a favorite action")
        let conflictingTitle = bar(artists: linkedArtists, visibleTitle: "Another song")
        expect(YandexAccessibilityMetadata(root: conflictingTitle)?.title == "Another song",
               "A stale versioned ARIA label overrode the current visible base title")
        expect(!target.matches(root: conflictingTitle), "A previous versioned ARIA title authorized a different visible track")
        expect(!YandexFavoriteTarget(trackID: nil, title: "Fixture", artist: target.artist).matches(root: plain),
               "A title substring authorized a favorite action")
        expect(!YandexFavoriteTarget(trackID: nil, title: target.title, artist: "Artist A").matches(root: plain),
               "A subset of the complete visible artist group authorized a favorite action")
        let labelOnly = node("AXGroup", children: [
            node("AXLink", ["Track Fixture song"], url: "music-application://desktop/track?trackId=42"),
            node("AXLink", ["Artist Artist A"], url: "music-application://desktop/artist?artistId=1"),
            node("AXLink", ["Artist Artist B"], url: "music-application://desktop/artist?artistId=2"),
        ])
        expect(YandexAccessibilityMetadata(root: labelOnly)?.title == target.title,
               "A label-only track without child text lost its existing fallback")
        expect(target.matches(root: labelOnly), "Label-only title/artist fallback no longer matches the current track")
    }

    static func main() {
        for role in ["AXButton", "AXCheckBox"] {
            for label in ["Like", "Нравится", "Мне нравится", "Ұнайды", "Yoqadi"] {
                expect(metadata([node(role, [label], value: "1")])?.isFavorite == true, "Pressed toggle lost its state")
                expect(metadata([node(role, [label], value: "0")])?.isFavorite == false, "Unpressed toggle was reported as liked")
                expect(metadata([node(role, [label])])?.isFavorite == nil, "The action label was mistaken for selected state")
            }
        }
        for value in ["2", "-1", "1.5", "mixed", "unknown", "Like", "", "NaN"] {
            expect(metadata([node("AXCheckBox", ["Like"], value: value)])?.isFavorite == nil,
                   "Indeterminate/nonboolean value was guessed")
        }
        for label in ["I don't like it", "Не нравится", "Ұнамайды", "Yoqmaydi", "Liked tracks", "Playback", "Next song"] {
            expect(metadata([node("AXCheckBox", [label], value: "1")])?.isFavorite == nil,
                   "An unrelated/dislike control was mistaken for the Like toggle")
        }
        expect(metadata([node("AXMenuItem", ["Like"], value: "1")])?.isFavorite == nil, "A contextual menu replaced the player toggle")
        expect(metadata([])?.isFavorite == nil, "Missing toggle was guessed")
        expect(metadata([node("AXButton", ["Like"], value: "true")])?.isFavorite == true, "Explicit true was lost")
        expect(metadata([node("AXButton", ["Like"], value: "false")])?.isFavorite == false, "Explicit false was lost")
        expect(metadata([node("AXButton", ["Like"], value: "1"), node("AXCheckBox", ["Like"], value: "0")])?.isFavorite == nil,
               "Conflicting rendered toggles were guessed")
        expect(metadata([node("AXButton", ["Like"], value: "1"), node("AXCheckBox", ["Like"], value: "1")])?.isFavorite == true,
               "Matching rendered toggles were rejected")
        expect(metadata([node("AXButton", ["Like"], value: "1"), node("AXCheckBox", ["Like"])])?.isFavorite == nil,
               "An unknown duplicate control established a confirmed like")
        let invalid = node("AXGroup", children: [
            node("AXLink", ["Track Other"], url: "https://music.yandex.ru/track/5"),
            node("AXLink", ["Track Fixture"], url: "https://music.yandex.ru/track/2"),
            node("AXCheckBox", ["Like"], value: "1"),
        ])
        expect(YandexAccessibilityMetadata(root: invalid) == nil, "Library items established a player favorite")
        for value in [NSNumber(value: true), NSNumber(value: 1), NSNumber(value: 1.0)] {
            expect(YandexLikeState.decodeAXValue(value) == true, "Explicit numeric/boolean one was lost")
        }
        for value in [NSNumber(value: false), NSNumber(value: 0), NSNumber(value: 0.0)] {
            expect(YandexLikeState.decodeAXValue(value) == false, "Explicit numeric/boolean zero was lost")
        }
        for value in [NSNumber(value: 2), NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: Double.nan), NSNumber(value: Double.infinity)] {
            expect(YandexLikeState.decodeAXValue(value) == nil, "Invalid number was truncated to a boolean")
        }
        expect(YandexLikeState.decodeAXValue(nil) == nil, "Absent AX value was guessed")
        entityRoutes()
        targetMatching()
        nativePlayerIdentity()
        // The native player can expose only an album link and plain title/artist text.
        // This exact shape was read from the live bottom transport bar, without account mutation.
        let plainTarget = YandexFavoriteTarget(trackID: "42", title: "Fixture song", artist: "Fixture artist")
        func plainBar(title: String = "Fixture song", artist: String = "Fixture artist") -> YandexAccessibilityNode {
            node("AXGroup", children: [
                node("AXLink", ["Fixture song"], url: "music-application://desktop/album?albumId=999"),
                node("AXStaticText", value: title), node("AXStaticText", value: artist),
                node("AXButton", ["Previous song"]), node("AXButton", ["Next song"]),
                node("AXCheckBox", ["Like"], value: "1"),
            ])
        }
        expect(YandexAccessibilityMetadata(root: plainBar()) == nil, "Album-only links must not invent full track metadata")
        expect(plainTarget.matches(root: plainBar()), "A plain current-player title/artist must establish a toggle target")
        expect(plainTarget.matches(root: plainBar(title: "Fixture—Song", artist: "FIXTURE ARTIST")), "Plain text normalization changed")
        expect(!plainTarget.matches(root: plainBar(title: "Other song")), "The album link title must not replace a conflicting visible title")
        expect(!plainTarget.matches(root: plainBar(artist: "Other artist")), "A different current artist matched")
        expect(!plainTarget.matches(root: plainBar(artist: "")), "Missing artist established a target")
        for target in [
            YandexFavoriteTarget(trackID: nil, title: "", artist: "Fixture artist"),
            YandexFavoriteTarget(trackID: nil, title: "Fixture song", artist: ""),
            YandexFavoriteTarget(trackID: nil, title: "Fixture", artist: "Fixture artist"),
        ] {
            expect(!target.matches(root: plainBar()), "Empty/partial identity established a current track")
        }
        let wrongTrack = node("AXGroup", children: plainBar().children + [node("AXLink", ["Fixture song"], url: "music-application://desktop/track?trackId=43")])
        expect(!plainTarget.matches(root: wrongTrack), "A mismatched trusted track ID was replaced by matching text")
        let exactTrack = node("AXGroup", children: [node("AXLink", ["Unrelated localized title"], url: "music-application://desktop/track?trackId=42")])
        expect(plainTarget.matches(root: exactTrack), "An exact track ID required optional localized text")
        let ambiguous = node("AXGroup", children: exactTrack.children + wrongTrack.children)
        expect(!plainTarget.matches(root: ambiguous), "Conflicting track IDs established one target")
        if !failures.isEmpty {
            fputs("Yandex favorite AX: \(failures.count) failures in \(checks) checks\n", stderr)
            fputs(failures.joined(separator: "\n") + "\n", stderr)
            exit(1)
        }
        print("Yandex favorite AX: \(checks) checks passed (whole production parser, no AX calls/player/data)")
    }
}
