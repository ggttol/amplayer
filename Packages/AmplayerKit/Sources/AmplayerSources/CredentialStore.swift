import Foundation
import Security

/// 来源密码与令牌存放在 Keychain（仅本机、解锁后可读）
public enum CredentialStore {
    private static let service = "dev.gaotao.amplayer.sources"

    public static func password(for sourceID: String) -> String? { get(sourceID + ".password") }
    public static func setPassword(_ value: String?, for sourceID: String) { set(value, account: sourceID + ".password") }

    /// OAuth 等令牌（JSON）
    public static func token(for sourceID: String) -> Data? { getData(sourceID + ".token") }
    public static func setToken(_ value: Data?, for sourceID: String) { setData(value, account: sourceID + ".token") }

    public static func removeAll(for sourceID: String) {
        set(nil, account: sourceID + ".password")
        setData(nil, account: sourceID + ".token")
    }

    private static func get(_ account: String) -> String? {
        getData(account).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func set(_ value: String?, account: String) {
        setData(value.map { Data($0.utf8) }, account: account)
    }

    private static func getData(_ account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func setData(_ value: Data?, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value else { return }
        var add = base
        add[kSecValueData as String] = value
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
