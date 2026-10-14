import Foundation
import Security

/// The device's token, kept in the Keychain (never in UserDefaults or files).
nonisolated enum KeychainToken {
    private static let service = "Cookbook.api-token"
    private static let account = "default"

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        delete()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            // Readable after the first unlock, so background refreshes work; never synced.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// A pairing code from `python -m app.tokens create`: "cookbook-pair:" + base64url JSON
/// {"server": ..., "token": ...}.
nonisolated struct PairingCode: Equatable {
    let server: URL
    let token: String

    static let prefix = "cookbook-pair:"

    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(Self.prefix) else { return nil }
        var payload = String(trimmed.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        struct Body: Decodable { let server: String; let token: String }
        guard let data = Data(base64Encoded: payload),
              let body = try? JSONDecoder().decode(Body.self, from: data),
              let url = URL(string: body.server), let scheme = url.scheme, ["http", "https"].contains(scheme),
              url.host() != nil, body.token.hasPrefix("ckb_") else { return nil }
        server = url
        self.token = body.token
    }
}
