import Foundation

public struct LyricsLine: Codable, Equatable, Sendable {
    public var time: Double
    public var text: String
    public init(time: Double, text: String) { self.time = time; self.text = text }
}

public struct LyricsDocument: Codable, Equatable, Sendable {
    public var plain: String
    public var synced: [LyricsLine]
    public init(plain: String, synced: [LyricsLine]) { self.plain = plain; self.synced = synced }
    public var isEmpty: Bool {
        plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && synced.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public enum LRCParser {
    /// LRC header offset advances the displayed lyrics by the given milliseconds. The user's
    /// independent UI timing adjustment is applied by the presentation layer afterwards.
    public static func parse(_ source: String) -> [LyricsLine] {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offset = try! NSRegularExpression(pattern: #"(?im)^\s*\[offset:\s*([+-]?\d+)\s*\]"#)
        let nsSource = source as NSString
        let offsetMS = offset.firstMatch(in: source, range: NSRange(location: 0, length: nsSource.length))
            .flatMap { Double(nsSource.substring(with: $0.range(at: 1))) } ?? 0
        var result: [LyricsLine] = []
        for raw in source.components(separatedBy: .newlines) {
            let line = raw as NSString
            let matches = timestamp.matches(in: raw, range: NSRange(location: 0, length: line.length))
            guard let last = matches.last else { continue }
            let text = line.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            // Timestamped empty lines clear the previous lyric during instrumental gaps.
            for match in matches {
                guard let minutes = Double(line.substring(with: match.range(at: 1))),
                      let seconds = Double(line.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                let fractionRange = match.range(at: 3)
                let fraction = fractionRange.location == NSNotFound ? 0 : Double("0." + line.substring(with: fractionRange)) ?? 0
                let time = minutes * 60 + seconds + fraction - offsetMS / 1000
                if time.isFinite { result.append(.init(time: max(0, time), text: text)) }
            }
        }
        return result.enumerated().sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }.map(\.element)
    }
}

public enum MediaText {
    public static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func artistsMatch(_ names: [String], target: String) -> Bool {
        func performers(_ value: String) -> [String] {
            let separated = value.replacingOccurrences(of: #"(?i)\s*(?:[,;&×]|\bfeaturing\b|\bfeat\.?(?=\s|$)|\bft\.?(?=\s|$)|\band\b)\s*"#,
                                                    with: "\n", options: .regularExpression)
            return separated.components(separatedBy: "\n").map(normalized).filter { !$0.isEmpty }
        }
        let names = Set(names.flatMap(performers))
        let targetNames = Set(performers(target))
        return !targetNames.isEmpty && targetNames == names
    }
}

public enum LyricsCacheKey {
    public static func make(source: String, bundle: String?, provider: String, accountFingerprint: String,
                            title: String, artist: String, album: String, duration: Double, nativeID: String? = nil) -> String {
        let seconds = duration.isFinite && duration > 0 ? duration.rounded() : 0
        var values = [source, bundle ?? "", provider, accountFingerprint, title, artist, album, String(seconds)]
        if let nativeID, !nativeID.isEmpty { values.append(nativeID) }
        return values.joined(separator: "\u{1F}").lowercased()
    }
}
