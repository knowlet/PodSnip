import Foundation
import Security

/// Minimal Keychain helper for the BYOK API key (never in UserDefaults).
enum KeychainStore {
    static func save(_ value: String, account: String, service: String = "PodSnip.AI") {
        let data = Data(value.utf8)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String, service: String = "PodSnip.AI") -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String, service: String = "PodSnip.AI") {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

struct AIConfig {
    var baseURL: String   // e.g. https://api.openai.com/v1
    var apiKey: String
    var model: String     // e.g. gpt-4o-mini
    var routeRaw: String  // AIRoute.rawValue

    var route: AIRoute { AIRoute(rawValue: routeRaw) ?? .byok }

    static let defaultsBaseURL = "https://api.openai.com/v1"
    static let defaultsModel = "gpt-4o-mini"

    static func load() -> AIConfig {
        let base = UserDefaults.standard.string(forKey: "ai.baseURL") ?? defaultsBaseURL
        let model = UserDefaults.standard.string(forKey: "ai.model") ?? defaultsModel
        let key = KeychainStore.load(account: "apiKey") ?? ""
        let route = UserDefaults.standard.string(forKey: "ai.route") ?? AIRoute.byok.rawValue
        return AIConfig(baseURL: base, apiKey: key, model: model, routeRaw: route)
    }

    func save() {
        UserDefaults.standard.set(baseURL, forKey: "ai.baseURL")
        UserDefaults.standard.set(model, forKey: "ai.model")
        UserDefaults.standard.set(routeRaw, forKey: "ai.route")
        if apiKey.isEmpty { KeychainStore.delete(account: "apiKey") }
        else { KeychainStore.save(apiKey, account: "apiKey") }
    }

    var isConfigured: Bool { !apiKey.isEmpty && !model.isEmpty && URL(string: baseURL) != nil }
}
