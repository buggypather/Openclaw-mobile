import Foundation
import CryptoKit
import Security

struct DeviceIdentity {
    let id: String
    let publicKey: String
    let privateKey: Curve25519.Signing.PrivateKey
}

struct DeviceToken: Codable {
    let token: String
    let role: String
    let scopes: Set<String>
}

final class DeviceIdentityStore {
    private let service = "ai.openclaw.mobile.device"
    private let privateAccount = "ed25519-private"
    private let tokenAccount = "device-token"

    func identity() throws -> DeviceIdentity {
        let key: Curve25519.Signing.PrivateKey
        if let stored = read(account: privateAccount) {
            key = try Curve25519.Signing.PrivateKey(rawRepresentation: stored)
        } else {
            key = Curve25519.Signing.PrivateKey()
            try write(key.rawRepresentation, account: privateAccount)
        }
        let pub = key.publicKey.rawRepresentation
        let digest = SHA256.hash(data: pub)
        let id = digest.map { String(format: "%02x", $0) }.joined()
        return DeviceIdentity(id: id, publicKey: pub.base64URLEncodedString(), privateKey: key)
    }

    func token() -> DeviceToken? {
        guard let data = read(account: tokenAccount) else { return nil }
        return try? JSONDecoder().decode(DeviceToken.self, from: data)
    }

    func saveToken(_ token: DeviceToken) throws {
        try write(JSONEncoder().encode(token), account: tokenAccount)
    }

    func clearToken() {
        SecItemDelete(query(account: tokenAccount) as CFDictionary)
    }

    func sign(_ identity: DeviceIdentity, payload: String) throws -> String {
        let signature = try identity.privateKey.signature(for: Data(payload.utf8))
        return signature.base64URLEncodedString()
    }

    private func query(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func read(account: String) -> Data? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func write(_ data: Data, account: String) throws {
        let q = query(account: account)
        let attrs = [kSecValueData as String: data]
        let status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    enum KeychainError: Error { case status(OSStatus) }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
