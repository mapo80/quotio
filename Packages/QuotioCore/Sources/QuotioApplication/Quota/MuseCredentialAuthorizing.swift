import Foundation

/// Asks the system for permission to read the credential the Muse Code CLI owns.
///
/// Meta's CLI writes its credential to the login keychain and does not list Quotio in
/// that item's access control. Locating the item succeeds from Quotio, but decrypting it
/// is refused with `errSecAuthFailed` — measured on macOS 26 — and every reader in this
/// app is deliberately non-interactive, so a background poll can never resolve it.
///
/// An implementation of this port performs the one read that is allowed to show the
/// system keychain prompt. Only a user-initiated action may call it: answering "Always
/// Allow" adds Quotio to the item's access control, after which the ordinary silent
/// reads succeed on their own.
public protocol MuseCredentialAuthorizing: Sendable {
    /// Returns true when Quotio can read the credential, either because it already
    /// could or because the user has just granted access.
    func authorize() async -> Bool
}
