import Foundation

private final class ArtworkURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var count = 0
    static var stopped = 0
    static var status = 200
    static var mime: String? = "image/png"
    static var delay = 0.1
    private var pending: DispatchWorkItem?
    static func reset(status: Int = 200, mime: String? = "image/png", delay: Double = 0.1) {
        lock.lock(); defer { lock.unlock() }
        count = 0; stopped = 0; self.status = status; self.mime = mime; self.delay = delay
    }
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1
        let status = Self.status, mime = Self.mime, delay = Self.delay
        Self.lock.unlock()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                            headerFields: mime.map { ["Content-Type": $0] })!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("artwork bytes".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        pending = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() {
        pending?.cancel()
        Self.lock.lock(); Self.stopped += 1; Self.lock.unlock()
    }
}
struct ArtworkFailure: Error { let message: String }
@main struct ArtworkTransportTests {
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw ArtworkFailure(message: message) }
    }
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtworkURLProtocol.self]
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = ImageService(session: session)
        let url = URL(string: "https://fixture.invalid/cover")!
        ArtworkURLProtocol.reset()
        async let first = service.fetchImageData(from: url)
        async let second = service.fetchImageData(from: url)
        let values = try await [first, second]
        try expect(values[0] == values[1] && ArtworkURLProtocol.requestCount == 1, "Concurrent artwork consumers did not share one HTTP request")
        for (status, mime) in [(404, "image/png"), (200, "text/html")] {
            ArtworkURLProtocol.reset(status: status, mime: mime)
            do { _ = try await service.fetchImageData(from: url); throw ArtworkFailure(message: "Invalid HTTP response was accepted") }
            catch is URLError { }
        }
        ArtworkURLProtocol.reset(delay: 1)
        let cancelled = Task { try await service.fetchImageData(from: url) }
        while ArtworkURLProtocol.requestCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw ArtworkFailure(message: "Canceled artwork request succeeded") }
        catch is CancellationError { }
        catch let error as URLError { try expect(error.code == .cancelled, "Cancellation became a different transport error") }
        ArtworkURLProtocol.reset()
        do { _ = try await service.fetchImageData(from: URL(string: "file:///tmp/private")!); throw ArtworkFailure(message: "File URL accepted") }
        catch let error as URLError { try expect(error.code == .unsupportedURL, "Wrong unsupported scheme result") }
        try expect(ArtworkURLProtocol.requestCount == 0, "Unsupported URL reached HTTP loader")
        print("Artwork transport: deduplication, HTTP/MIME validation, cancellation and scheme checks passed")
    }
}
