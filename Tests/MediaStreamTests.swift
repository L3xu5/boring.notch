import Foundation

// The runner inserts the production actor verbatim. These tests use real Pipes: no mocked
// framing, decoder or stream reader. Buffered-byte observation makes UTF-8 splits deterministic.
// PRODUCTION_PIPE_HANDLER

extension JSONLinesPipeHandler {
    func bufferedByteCount() -> Int { buffer.count }
}
struct MediaEvent: Codable, Equatable {
    let title: String
    var artworkData: String? = nil
}
actor EventCollector {
    var events: [MediaEvent] = []
    func append(_ event: MediaEvent) { events.append(event) }
    func snapshot() -> [MediaEvent] { events }
}
struct TestFailure: Error, CustomStringConvertible { let description: String }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}
func eventually(_ message: String, _ condition: () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw TestFailure(description: "Timed out: " + message)
}

@main struct MediaStreamTests {
    static func start() async -> (JSONLinesPipeHandler, FileHandle, EventCollector, Task<Void, Never>) {
        let handler = JSONLinesPipeHandler()
        let pipe = await handler.getPipe()
        let collector = EventCollector()
        let reader = Task {
            await handler.readJSONLines(as: MediaEvent.self) { event in
                await collector.append(event)
            }
        }
        return (handler, pipe.fileHandleForWriting, collector, reader)
    }
    static func main() async throws {
        try await splitEveryUTF8Byte()
        try await largeArtworkWithSplitTitle()
        try await fragmentedNewlinesAndMultipleLines()
        try await finalLineAtEOF()
        try await malformedLineRecovery()
        print("5 media stream regression scenarios passed")
    }
    static func splitEveryUTF8Byte() async throws {
        let (handler, writer, collector, reader) = await start()
        let event = MediaEvent(title: "Привет, мир 🎵🧑‍🎤 日本語 café")
        let bytes = try JSONEncoder().encode(event)
        for (index, byte) in bytes.enumerated() {
            try writer.write(contentsOf: Data([byte]))
            // Wait for this exact fragment to be buffered before sending the next byte. This
            // forces readData to return invalid partial UTF-8 sequences that the old code lost.
            try await eventually("UTF-8 byte fragment \(index)") {
                await handler.bufferedByteCount() == index + 1
            }
        }
        try writer.write(contentsOf: Data([0x0A]))
        try writer.close()
        await reader.value
        let events = await collector.snapshot()
        try expect(events == [event], "Splitting a Cyrillic/emoji character dropped its JSON update")
    }
    static func largeArtworkWithSplitTitle() async throws {
        let (handler, writer, collector, reader) = await start()
        let artwork = Data(repeating: 0x7B, count: 750_000).base64EncodedString()
        let prefix = Data(("{\"artworkData\":\"" + artwork + "\",\"title\":\"").utf8)
        let title = "Обложка 🎶"
        for offset in stride(from: 0, to: prefix.count, by: 4093) {
            try writer.write(contentsOf: prefix[offset..<min(offset + 4093, prefix.count)])
        }
        try await eventually("large artwork buffer") { await handler.bufferedByteCount() == prefix.count }
        // The title follows a megabyte of artwork. Split every byte to ensure neither the
        // prefix nor the final multibyte metadata is discarded after a fragmented read.
        let titleBytes = Data(title.utf8)
        for (index, byte) in titleBytes.enumerated() {
            try writer.write(contentsOf: Data([byte]))
            try await eventually("large artwork title fragment") {
                await handler.bufferedByteCount() == prefix.count + index + 1
            }
        }
        try writer.write(contentsOf: Data("\"}\n".utf8))
        try writer.close()
        await reader.value
        let events = await collector.snapshot()
        try expect(events == [MediaEvent(title: title, artworkData: artwork)], "Large artwork corrupted the adjacent UTF-8 metadata")
    }
    static func fragmentedNewlinesAndMultipleLines() async throws {
        let (handler, writer, collector, reader) = await start()
        try writer.write(contentsOf: Data("{\"title\":\"First\"}\r".utf8))
        try await eventually("line awaiting LF") { await handler.bufferedByteCount() > 0 }
        let beforeNewline = await collector.snapshot()
        try expect(beforeNewline.isEmpty, "A line was decoded before its LF arrived")
        try writer.write(contentsOf: Data("\n\n{\"title\":\"Second\"}\n{\"title\":\"Third\"}\n".utf8))
        try writer.close()
        await reader.value
        let events = await collector.snapshot()
        try expect(events.map(\.title) == ["First", "Second", "Third"], "CRLF, blank lines or several lines in one read changed order")
    }
    static func finalLineAtEOF() async throws {
        let (_, writer, collector, reader) = await start()
        try writer.write(contentsOf: Data("{\"title\":\"Без завершающего LF 🎵\"}".utf8))
        try writer.close()
        await reader.value
        let events = await collector.snapshot()
        try expect(events.map(\.title) == ["Без завершающего LF 🎵"], "EOF discarded a complete JSON object without trailing LF")
    }
    static func malformedLineRecovery() async throws {
        let (_, writer, collector, reader) = await start()
        try writer.write(contentsOf: Data([0xFF, 0x0A]))
        try writer.write(contentsOf: Data("not json\n{\"title\":\"Still healthy 🎵\"}\n{\"title\":".utf8))
        try writer.close()
        await reader.value
        let events = await collector.snapshot()
        try expect(events.map(\.title) == ["Still healthy 🎵"], "Malformed input prevented the next valid line or incomplete EOF was emitted")
    }
}
