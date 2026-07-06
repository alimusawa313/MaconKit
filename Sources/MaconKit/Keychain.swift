//
//  Keychain.swift
//  MacON
//
//  Minimal generic-password storage for the Bitbucket API token, so it isn't
//  written to UserDefaults in plaintext.
//

import Foundation
import Security

public enum Keychain {
    private static let service = "com.karar.MacON.bitbucket"

    public static func set(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        if value.isEmpty { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
