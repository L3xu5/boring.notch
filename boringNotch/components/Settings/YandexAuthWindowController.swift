import AppKit
import WebKit

final class YandexAuthWindowController: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = YandexAuthWindowController()
    private var window: NSWindow?
    private var pendingState: String?
    private var isShowingError = false

    func present() {
        if let window {
            ApplicationActivationPolicy.present(window)
            return
        }
        let state: String
        do {
            state = try YandexMusicOAuth.makeState()
        } catch {
            showError(YandexMusicOAuthError.stateGeneration.localizedDescription)
            return
        }
        pendingState = state
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent() // fresh session so the user can pick the account
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 460, height: 640), configuration: config)
        webView.navigationDelegate = self
        // Present as a normal browser so Yandex doesn't refuse the embedded web view.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Connect Yandex Music"
        w.minSize = NSSize(width: 420, height: 520)
        w.contentView = webView
        w.center()
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        window = w
        ApplicationActivationPolicy.present(w)
        webView.load(URLRequest(url: YandexMusicOAuth.authorizationURL(state: state)))
    }

    /// Accept only a response to this sign-in session at the client's registered callback.
    @discardableResult
    private func captureToken(from url: URL?) -> Bool {
        guard window != nil, let url,
              YandexMusicOAuth.isCallbackURL(url) || YandexMusicOAuth.hasResponseParameters(url) else {
            return false
        }
        do {
            guard let pendingState else { throw YandexMusicOAuthError.invalidCallback }
            let token = try YandexMusicOAuth.token(from: url, expectedState: pendingState)
            try YandexMusicTokenStore.shared.save(token: token)
            self.pendingState = nil
            window?.close()
        } catch let error as YandexMusicOAuthError {
            showError(error.localizedDescription)
        } catch {
            showError(YandexMusicTokenError.secureStorage.localizedDescription)
        }
        return true
    }

    private func showError(_ message: String) {
        guard !isShowingError else { return }
        let alert = NSAlert()
        alert.messageText = "Could not connect Yandex Music"
        alert.informativeText = message
        if let window {
            isShowingError = true
            alert.beginSheetModal(for: window) { [weak self] _ in self?.isShowingError = false }
        } else {
            alert.runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        let closingWindow = window
        let webView = window?.contentView as? WKWebView
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        pendingState = nil
        window = nil
        isShowingError = false
        ApplicationActivationPolicy.restore(excluding: closingWindow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if captureToken(from: navigationAction.request.url) {
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        captureToken(from: webView.url)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureToken(from: webView.url)
    }
}
