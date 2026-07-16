//
//  ClickyProxyAuthorization.swift
//  leanring-buddy
//
//  Reads the per-install Worker credential from the macOS Keychain.
//

import Foundation
import Security

struct ClickyProxyAuthorizationError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum ClickyProxyAuthorization {
    static let keychainAccountName = "clicky-worker-access"

    static var keychainServiceName: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? "com.yourcompany.leanring-buddy"
        return "\(bundleIdentifier).proxy-access-token"
    }

    static var isConfigured: Bool {
        (try? accessToken()) != nil
    }

    static func authorize(_ request: inout URLRequest) throws {
        request.setValue(
            "Bearer \(try accessToken())",
            forHTTPHeaderField: "Authorization"
        )
    }

    private static func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainServiceName,
            kSecAttrAccount as String: keychainAccountName,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]

        var keychainItem: CFTypeRef?
        let keychainStatus = SecItemCopyMatching(
            query as CFDictionary,
            &keychainItem
        )
        guard keychainStatus == errSecSuccess,
              let tokenData = keychainItem as? Data,
              let token = String(data: tokenData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.count >= 32 else {
            throw ClickyProxyAuthorizationError(
                message: "Clicky's Worker access token is missing from the macOS Keychain."
            )
        }
        return token
    }
}
