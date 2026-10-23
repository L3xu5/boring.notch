import Combine
import BoringCore
import Foundation
import Security

enum MediaExecutionMode {
    static var isIsolatedPreview: Bool {
        #if DEBUG
        return MediaStartupPolicy.isIsolatedPreview(debugBuild: true, bundleIdentifier: Bundle.main.bundleIdentifier,
                                                   arguments: CommandLine.arguments)
        #else
        return false
        #endif
    }
}

protocol YandexMusicTokenStorage {
    func read() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

protocol YandexMusicLegacyTokenStorage {
    func read() -> String?
    func delete()
}

private struct YandexMusicKeychainStorage: YandexMusicTokenStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "theboringteam.boringnotch.yandex-music",
         kSecAttrAccount as String: "oauth-token"]
    }

    func read() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw YandexMusicTokenError.secureStorage
        }
        return token
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
                throw YandexMusicTokenError.secureStorage
            }
        } else if status != errSecSuccess {
            throw YandexMusicTokenError.secureStorage
        }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw YandexMusicTokenError.secureStorage
        }
    }
}

private struct YandexMusicLegacyDefaults: YandexMusicLegacyTokenStorage {
    private let key = "yandexMusicToken"
    func read() -> String? { UserDefaults.standard.string(forKey: key) }
    func delete() { UserDefaults.standard.removeObject(forKey: key) }
}

enum YandexMusicTokenError: LocalizedError {
    case invalidToken
    case secureStorage

    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Enter a valid Yandex Music OAuth token."
        case .secureStorage: return "Unable to access the Yandex Music token in Keychain. Please try again."
        }
    }
}

/// The legacy preference is removed only after a token is confirmed in secure storage.
/// Injected storage keeps migration and failure handling testable without using a real Keychain.
@MainActor
final class YandexMusicTokenStore: ObservableObject {
    static let shared: YandexMusicTokenStore = {
        if MediaExecutionMode.isIsolatedPreview {
            return YandexMusicTokenStore(storage: PreviewTokenStorage(), legacyStorage: PreviewLegacyStorage())
        }
        return YandexMusicTokenStore(storage: YandexMusicKeychainStorage(), legacyStorage: YandexMusicLegacyDefaults())
    }()

    @Published private(set) var token = ""
    @Published private(set) var errorMessage: String?
    var isConnected: Bool { !token.isEmpty }

    private let storage: any YandexMusicTokenStorage
    private let legacyStorage: any YandexMusicLegacyTokenStorage

    init(storage: any YandexMusicTokenStorage, legacyStorage: any YandexMusicLegacyTokenStorage) {
        self.storage = storage
        self.legacyStorage = legacyStorage
        reload()
    }

    func reload() {
        do {
            if let saved = try storage.read(), Self.isValidToken(saved) {
                token = saved
                legacyStorage.delete()
            } else if let legacy = legacyStorage.read(), !legacy.isEmpty {
                try save(token: legacy)
            } else {
                token = ""
            }
            errorMessage = nil
        } catch {
            // Preserve the old preference when Keychain is unavailable; a later retry can migrate it.
            errorMessage = YandexMusicTokenError.secureStorage.localizedDescription
        }
    }

    func save(token value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidToken(value) else {
            errorMessage = YandexMusicTokenError.invalidToken.localizedDescription
            throw YandexMusicTokenError.invalidToken
        }
        do {
            try storage.save(value)
            legacyStorage.delete()
            token = value
            errorMessage = nil
        } catch {
            errorMessage = YandexMusicTokenError.secureStorage.localizedDescription
            throw YandexMusicTokenError.secureStorage
        }
    }

    func disconnect() throws {
        do {
            try storage.delete()
            legacyStorage.delete()
            token = ""
            errorMessage = nil
        } catch {
            errorMessage = YandexMusicTokenError.secureStorage.localizedDescription
            throw YandexMusicTokenError.secureStorage
        }
    }

    nonisolated static func isValidToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 8192
            && value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
    }
}

private final class PreviewTokenStorage: YandexMusicTokenStorage {
    private var token: String?
    func read() -> String? { token }
    func save(_ token: String) { self.token = token }
    func delete() { token = nil }
}
private struct PreviewLegacyStorage: YandexMusicLegacyTokenStorage {
    func read() -> String? { nil }
    func delete() {}
}

enum YandexMusicOAuthError: LocalizedError {
    case invalidCallback
    case authorizationDenied
    case stateGeneration

    var errorDescription: String? {
        switch self {
        case .invalidCallback: return "The Yandex Music sign-in response could not be verified. Close this window and connect again."
        case .authorizationDenied: return "Yandex Music sign-in was not completed. Close this window and connect again."
        case .stateGeneration: return "Unable to start secure Yandex Music sign-in. Please try again."
        }
    }
}

enum YandexMusicOAuth {
    // This client belongs to Yandex. Keep its existing registered default redirect URI.
    static func authorizationURL(state: String) -> URL {
        var url = URLComponents(string: "https://oauth.yandex.ru/authorize")!
        url.queryItems = [URLQueryItem(name: "response_type", value: "token"),
                          URLQueryItem(name: "client_id", value: "23cabbbdc6cd418abb4b39c32c41195d"),
                          URLQueryItem(name: "force_confirm", value: "yes"),
                          URLQueryItem(name: "state", value: state)]
        return url.url!
    }

    static func makeState() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw YandexMusicOAuthError.stateGeneration
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isCallbackURL(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && parts.host?.lowercased() == "music.yandex.ru"
            && (parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/")
            && parts.user == nil && parts.password == nil && (parts.port == nil || parts.port == 443)
            && parts.query == nil
    }

    /// Also intercept OAuth-looking responses on an unexpected URL so its token cannot be accepted
    /// or sent on to a page in the embedded browser.
    static func hasResponseParameters(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        let names = Set((parts.queryItems ?? []).map(\.name) + fragmentItems(parts).map(\.name))
        return !names.isDisjoint(with: ["access_token", "error"])
    }

    static func token(from url: URL, expectedState: String) throws -> String {
        guard isCallbackURL(url), !expectedState.isEmpty,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw YandexMusicOAuthError.invalidCallback
        }
        let items = fragmentItems(parts)
        var values: [String: String] = [:]
        for item in items {
            guard !item.name.isEmpty, let value = item.value, values[item.name] == nil else {
                throw YandexMusicOAuthError.invalidCallback
            }
            values[item.name] = value
        }
        guard values["state"] == expectedState else { throw YandexMusicOAuthError.invalidCallback }
        if values["error"] != nil { throw YandexMusicOAuthError.authorizationDenied }
        guard let token = values["access_token"], YandexMusicTokenStore.isValidToken(token),
              values["token_type"].map({ $0.caseInsensitiveCompare("bearer") == .orderedSame }) ?? true else {
            throw YandexMusicOAuthError.invalidCallback
        }
        return token
    }

    private static func fragmentItems(_ parts: URLComponents) -> [URLQueryItem] {
        guard let fragment = parts.percentEncodedFragment else { return [] }
        // Decode once, after splitting parameters; an encoded '&' belongs to a value.
        return URLComponents(string: "https://callback.invalid/?" + fragment)?.queryItems ?? []
    }
}
