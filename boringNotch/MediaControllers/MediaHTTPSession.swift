import Foundation

/// Authenticated API requests cannot forward credentials to a redirected host or downgrade
/// HTTPS. Download requests carry no Authorization header and remain HTTPS throughout.
enum MediaHTTPSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: MediaHTTPRedirectPolicy(), delegateQueue: nil)
    }()
}

private final class MediaHTTPRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil else {
            completionHandler(nil); return
        }
        if task.originalRequest?.value(forHTTPHeaderField: "Authorization") != nil {
            guard url.host?.lowercased() == task.originalRequest?.url?.host?.lowercased(),
                  url.port == nil || url.port == 443 else { completionHandler(nil); return }
        }
        completionHandler(request)
    }
}
