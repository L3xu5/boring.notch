import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private func expectFailure(_ operation: () throws -> Void) throws {
    do {
        try operation()
    } catch is TestFailure {
        throw TestFailure(description: "Unexpected test failure")
    } catch {
        return
    }
    throw TestFailure(description: "Expected operation to fail")
}

private final class Events {
    var values: [String] = []
}

private enum StorageFailure: Error { case unavailable }

private final class FakeTokenStorage: YandexMusicTokenStorage {
    var token: String?
    var failRead = false
    var failSave = false
    var failDelete = false
    let events: Events

    init(token: String? = nil, events: Events = Events()) {
        self.token = token
        self.events = events
    }

    func read() throws -> String? {
        events.values.append("read")
        if failRead { throw StorageFailure.unavailable }
        return token
    }

    func save(_ token: String) throws {
        events.values.append("save")
        if failSave { throw StorageFailure.unavailable }
        self.token = token
    }

    func delete() throws {
        events.values.append("delete")
        if failDelete { throw StorageFailure.unavailable }
        token = nil
    }
}

private final class FakeLegacyStorage: YandexMusicLegacyTokenStorage {
    var token: String?
    let events: Events

    init(token: String? = nil, events: Events = Events()) {
        self.token = token
        self.events = events
    }

    func read() -> String? { token }
    func delete() {
        events.values.append("legacy.delete")
        token = nil
    }
}

@main
@MainActor
private struct YandexMusicAuthTests {
    static func main() throws {
        var passed = 0
        func test(_ name: String, _ operation: () throws -> Void) throws {
            do {
                try operation()
                passed += 1
                print("PASS \(name)")
            } catch {
                throw TestFailure(description: "\(name): \(error)")
            }
        }

        try test("authorization request keeps registered default and is not a callback") {
            let url = YandexMusicOAuth.authorizationURL(state: "nonce")
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value ?? "") })
            try expect(query["state"] == "nonce", "Missing OAuth state")
            try expect(query["response_type"] == "token", "Changed OAuth flow")
            try expect(query["client_id"] == "23cabbbdc6cd418abb4b39c32c41195d", "Changed registered client")
            try expect(query["redirect_uri"] == nil, "Overrode Yandex's registered redirect")
            try expect(!YandexMusicOAuth.hasResponseParameters(url), "Initial authorization was treated as a response")
            try expect(!YandexMusicOAuth.isCallbackURL(url), "Authorization endpoint was treated as the callback")
            let login = URL(string: "https://passport.yandex.ru/auth?retpath=https%3A%2F%2Foauth.yandex.ru%2Fauthorize%3Fstate%3Dnonce")!
            try expect(!YandexMusicOAuth.hasResponseParameters(login), "Login navigation was treated as a response")
        }

        try test("state uses fresh cryptographic random bytes") {
            let states = try (0..<128).map { _ in try YandexMusicOAuth.makeState() }
            try expect(Set(states).count == states.count, "State was reused")
            try expect(states.allSatisfy { $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }, "Wrong state format")
        }

        try test("valid callback decodes exactly once and accepts bearer case variants") {
            let url = URL(string: "https://music.yandex.ru/#access_token=opaque%3Dvalue%2Bpart%26tail&state=nonce&token_type=BeArEr")!
            let token = try YandexMusicOAuth.token(from: url, expectedState: "nonce")
            try expect(token == "opaque=value+part&tail", "Token was split or decoded incorrectly")
            let encoded = URL(string: "https://music.yandex.ru/#access_token=opaque%2526value&state=nonce")!
            let encodedToken = try YandexMusicOAuth.token(from: encoded, expectedState: "nonce")
            try expect(encodedToken == "opaque%26value", "Token was decoded twice")
        }

        let invalidCallbacks = [
            "http://music.yandex.ru/#access_token=value&state=nonce",
            "https://evil.example/#access_token=value&state=nonce",
            "https://music.yandex.ru.evil.example/#access_token=value&state=nonce",
            "https://evil.music.yandex.ru/#access_token=value&state=nonce",
            "https://user@music.yandex.ru/#access_token=value&state=nonce",
            "https://music.yandex.ru:444/#access_token=value&state=nonce",
            "https://music.yandex.ru/other#access_token=value&state=nonce",
            "https://music.yandex.ru/%2F#access_token=value&state=nonce",
            "https://music.yandex.ru/?access_token=value&state=nonce",
            "https://music.yandex.ru/?state=nonce#access_token=value&state=nonce",
            "https://music.yandex.ru/#access_token=value",
            "https://music.yandex.ru/#access_token=value&state=wrong",
            "https://music.yandex.ru/#access_token=value&state=nonce&state=nonce",
            "https://music.yandex.ru/#access_token=value&state=nonce&%73tate=nonce",
            "https://music.yandex.ru/#access_token=one&access_token=two&state=nonce",
            "https://music.yandex.ru/#access_token=value&state=nonce&token_type=bearer&token_type=bearer",
            "https://music.yandex.ru/#access_token=value&state=nonce&expires_in=1&expires_in=2",
            "https://music.yandex.ru/#state=nonce",
            "https://music.yandex.ru/#access_token=&state=nonce",
            "https://music.yandex.ru/#access_token=value%0Aheader&state=nonce",
            "https://music.yandex.ru/#access_token=value&state=nonce&token_type=basic",
            "https://music.yandex.ru/#access_token=value&state=nonce&error=access_denied",
            "https://music.yandex.ru/#error=access_denied&state=nonce",
            "https://music.yandex.ru/",
        ]
        for (index, value) in invalidCallbacks.enumerated() {
            try test("reject invalid callback \(index + 1)") {
                try expectFailure { _ = try YandexMusicOAuth.token(from: URL(string: value)!, expectedState: "nonce") }
            }
        }

        try test("reject absent session and intercept unexpected token destinations") {
            let url = URL(string: "https://music.yandex.ru/#access_token=value&state=nonce")!
            try expectFailure { _ = try YandexMusicOAuth.token(from: url, expectedState: "") }
            let unexpected = URL(string: "https://evil.example/#access_token=value&state=nonce")!
            try expect(YandexMusicOAuth.hasResponseParameters(unexpected), "Unexpected token response was not intercepted")
        }

        try test("migration writes secure storage before deleting legacy preference") {
            let events = Events()
            let storage = FakeTokenStorage(events: events)
            let legacy = FakeLegacyStorage(token: "legacy-value", events: events)
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            try expect(events.values == ["read", "save", "legacy.delete"], "Unsafe migration order")
            try expect(store.token == "legacy-value" && storage.token == "legacy-value" && legacy.token == nil, "Migration lost credentials")
        }

        try test("failed migration preserves legacy and retries successfully") {
            let storage = FakeTokenStorage()
            storage.failSave = true
            let legacy = FakeLegacyStorage(token: "legacy-value")
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            try expect(legacy.token == "legacy-value" && storage.token == nil && !store.isConnected, "Failed migration lost credentials")
            try expect(store.errorMessage != nil && !store.errorMessage!.contains("legacy-value"), "Missing safe storage error")
            storage.failSave = false
            store.reload()
            try expect(store.token == "legacy-value" && legacy.token == nil && store.errorMessage == nil, "Migration retry failed")
        }

        try test("unavailable secure storage does not delete legacy or attempt overwrite") {
            let storage = FakeTokenStorage()
            storage.failRead = true
            let legacy = FakeLegacyStorage(token: "legacy-value")
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            try expect(legacy.token == "legacy-value" && storage.events.values == ["read"], "Unreadable secure storage was overwritten")
            try expect(!store.isConnected && store.errorMessage != nil, "Storage error was hidden")
        }

        try test("confirmed secure token takes precedence and removes stale plaintext") {
            let storage = FakeTokenStorage(token: "secure-value")
            let legacy = FakeLegacyStorage(token: "legacy-value")
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            try expect(store.token == "secure-value" && legacy.token == nil, "Stale plaintext replaced secure credential")
        }

        try test("manual save validates token and preserves connection on write failure") {
            let storage = FakeTokenStorage(token: "old-value")
            let legacy = FakeLegacyStorage()
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            storage.failSave = true
            try expectFailure { try store.save(token: "new-value") }
            try expect(store.token == "old-value" && storage.token == "old-value", "Failed save replaced current credential")
            storage.failSave = false
            try expectFailure { try store.save(token: "bad\nvalue") }
            try store.save(token: "  manual-value\n")
            try expect(store.token == "manual-value" && storage.token == "manual-value", "Manual token was not saved")
        }

        try test("disconnect clears both stores only after successful secure deletion") {
            let events = Events()
            let storage = FakeTokenStorage(token: "secure-value", events: events)
            let legacy = FakeLegacyStorage(events: events)
            let store = YandexMusicTokenStore(storage: storage, legacyStorage: legacy)
            legacy.token = "legacy-value"
            storage.failDelete = true
            events.values = []
            try expectFailure { try store.disconnect() }
            try expect(store.isConnected && legacy.token == "legacy-value" && events.values == ["delete"], "Failed delete lost credentials")
            storage.failDelete = false
            events.values = []
            try store.disconnect()
            try expect(!store.isConnected && storage.token == nil && legacy.token == nil, "Disconnect left credentials behind")
            try expect(events.values == ["delete", "legacy.delete"], "Unsafe deletion order")
        }

        print("\(passed) Yandex Music authentication checks passed; real Keychain and preferences were not accessed.")
    }
}
