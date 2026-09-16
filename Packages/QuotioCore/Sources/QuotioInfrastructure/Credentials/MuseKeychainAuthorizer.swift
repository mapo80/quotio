import Foundation
import LocalAuthentication
import QuotioApplication
import Security

/// Grants Quotio access to the Muse Code credential through the system keychain prompt.
///
/// Two reads, in order. The first carries an `LAContext` with `interactionNotAllowed`,
/// exactly like every other credential Quotio reads, so an account that already works
/// costs the user nothing. Only when that is refused does the second read run without
/// the flag, which is what lets macOS show "Quotio wants to use your confidential
/// information stored in ai.meta.dev.credentials". Answering "Always Allow" adds this
/// build of Quotio to the item's access control, and the silent read succeeds from then
/// on, including from background polls.
///
/// The secret is never returned, logged, or kept: only whether it could be read.
public actor MuseKeychainAuthorizer: MuseCredentialAuthorizing {
    private let service: String
    private let account: String

    public init(
        service: String = MuseQuotaFetcher.keychainService,
        account: String = MuseQuotaFetcher.keychainAccount
    ) {
        self.service = service
        self.account = account
    }

    public func authorize() async -> Bool {
        if canRead(allowingPrompt: false) { return true }
        return canRead(allowingPrompt: true)
    }

    private func canRead(allowingPrompt: Bool) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowingPrompt {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // The value is deliberately dropped: this port answers a yes/no question.
        result = nil
        return status == errSecSuccess
    }
}
