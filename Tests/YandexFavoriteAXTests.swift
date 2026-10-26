import Foundation

@main
private enum YandexFavoriteAXTests {
    private static var checks = 0
    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard value() else { fatalError(message) }
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
        print("Yandex favorite AX: \(checks) checks passed (whole production parser, no AX calls/player/data)")
    }
}
