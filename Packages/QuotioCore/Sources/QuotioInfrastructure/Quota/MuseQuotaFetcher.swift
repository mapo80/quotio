import Foundation
import QuotioApplication
import QuotioDomain

/// Muse Code (Meta) subscription quota.
///
/// The Muse Code CLI keeps a pointer at `~/.config/muse/auth.json` that carries no
/// secret, and stores the credential itself in the login keychain under service
/// `ai.meta.dev.credentials`, account `meta`. That payload holds two values: the Model
/// API key the CLI sends to `api.meta.ai/v1`, and the Meta account access token minted
/// by the device grant. Only the account token reads subscription usage, so the Model
/// API key is never read, returned, or logged here.
///
/// Meta publishes no quota endpoint. The one machine-readable snapshot is the
/// `subs_usage` object in the response of the subscription-key endpoint, which makes a
/// refresh an auth-plane POST rather than a metered inference call. That endpoint is
/// rate limited and hands back the same key every time, so successful reads are spaced
/// and failures back off. Both bounds hold for a forced refresh too — a refresh may skip
/// a display cache, but it may not spend another key request — and the previous snapshot
/// is served while a bound holds.
///
/// The keychain read is non-interactive, like every other external credential Quotio
/// reads. An item whose access control does not admit Quotio simply reads as absent.
public actor MuseQuotaFetcher: QuotaFetching {
  public struct Pointer: Sendable, Equatable {
    public let accountKey: String
    public let displayName: String?

    public init(accountKey: String, displayName: String?) {
      self.accountKey = accountKey
      self.displayName = displayName
    }
  }

  /// The last read and the earliest time the endpoint may be asked again. `quota` is
  /// nil while a backoff is running with nothing to serve yet.
  private struct CachedQuota {
    let quota: ProviderQuota?
    let readyAt: Date
  }

  public static let pointerPath = "~/.config/muse/auth.json"
  public static let keychainService = "ai.meta.dev.credentials"
  public static let keychainAccount = "meta"
  /// Used when the pointer names no account. Meta issues one credential per machine.
  public static let localAccountKey = "Muse Code"
  /// Meta rejects the subscription-key endpoint without it.
  public static let apiVersion = "1.0.0"
  /// Matches the spacing the vendor's own client keeps on this endpoint.
  public static let refreshInterval: TimeInterval = 300
  public static let failureBackoff: TimeInterval = 300
  /// Meta's rolling window, identified by its declared duration rather than assumed.
  public static let fiveHourWindowMinutes: Double = 300

  public nonisolated let provider = QuotaProvider.muse
  private let files: any QuotaCredentialFileReading
  private let credentials: any ExternalCredentialReading
  private let session: any QuotaHTTPSession
  private let pointerPath: String
  private let keyURL: URL
  private let now: @Sendable () -> Date
  private var cache: [String: CachedQuota] = [:]

  public init(
    files: any QuotaCredentialFileReading = LocalQuotaCredentialFileReader(),
    credentials: any ExternalCredentialReading = ExternalKeychainCredentialReader(),
    session: any QuotaHTTPSession = URLSession(
      configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 15)),
    pointerPath: String = MuseQuotaFetcher.pointerPath,
    keyURL: URL = URL(string: "https://api.meta.ai/muse-code/key")!,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.files = files
    self.credentials = credentials
    self.session = session
    self.pointerPath = pointerPath
    self.keyURL = keyURL
    self.now = now
  }

  public func fetch(_ request: QuotaFetchRequest) async throws -> QuotaProviderOutput {
    guard let data = await files.read(path: pointerPath),
      let pointer = Self.loadPointer(data: data)
    else {
      return .init(quotas: [:], credentialAvailability: .missing, credentialAccountKeys: [])
    }
    let keys: Set<String> = [pointer.accountKey]
    guard Self.includes(pointer.accountKey, in: request.scope) else {
      return .init(quotas: [:], credentialAvailability: .present, credentialAccountKeys: keys)
    }
    guard let quota = await quota(for: pointer) else {
      return .init(quotas: [:], credentialAvailability: .present, credentialAccountKeys: keys)
    }
    return .init(
      quotas: [pointer.accountKey: quota],
      credentialAvailability: .present,
      credentialAccountKeys: keys
    )
  }

  /// Reads the pointer the Muse Code CLI writes. It holds no secret by design.
  public nonisolated static func loadPointer(data: Data) -> Pointer? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let providers = root["providers"] as? [String: Any],
      let meta = providers["meta"] as? [String: Any]
    else { return nil }
    let email = trimmed(meta["user_email"] as? String)?.lowercased()
    return Pointer(accountKey: email ?? localAccountKey, displayName: email)
  }

  /// Turns Meta's `subs_usage` object into the rolling and weekly windows Quotio renders.
  ///
  /// A window whose declared duration is not the five-hour one is carried under its own
  /// name rather than filed as the session window: reporting a longer window as the
  /// five-hour one would understate usage by the ratio between them, and would do it
  /// with full confidence.
  public nonisolated static func mapUsage(
    _ usage: [String: Any],
    plan: String?,
    displayName: String?,
    now: Date
  ) -> ProviderQuota? {
    var metrics: [QuotaMetric] = []
    if let window = usage["window"] as? [String: Any],
      let remaining = remainingPercentage(window["used_percent"])
    {
      let minutes = number(window["window_duration_mins"])
      let name =
        minutes == fiveHourWindowMinutes || minutes == nil
        ? "muse-session" : "muse-window-\(Int(minutes ?? 0))"
      metrics.append(
        .init(
          name: name, percentage: remaining, resetTime: resetTime(window["resets_at"])))
    }
    if let weekly = usage["weekly"] as? [String: Any],
      let remaining = remainingPercentage(weekly["used_percent"])
    {
      metrics.append(
        .init(
          name: "muse-weekly", percentage: remaining, resetTime: resetTime(weekly["resets_at"])))
    }
    guard !metrics.isEmpty else { return nil }
    return ProviderQuota(
      models: metrics, lastUpdated: now, planType: plan, accountDisplayName: displayName)
  }

  private func quota(for pointer: Pointer) async -> ProviderQuota? {
    let at = now()
    if let cached = cache[pointer.accountKey], at < cached.readyAt { return cached.quota }
    guard
      let record = await credentials.read(
        service: Self.keychainService, account: Self.keychainAccount),
      let token = Self.accountAccessToken(record.data)
    else {
      // A keychain the process may not read is not a rate-limited endpoint: nothing to
      // back off from, and the next poll may well succeed after the user grants access.
      return nil
    }
    do {
      let quota = try await read(token: token, pointer: pointer)
      cache[pointer.accountKey] = CachedQuota(
        quota: quota, readyAt: at.addingTimeInterval(Self.refreshInterval))
      return quota
    } catch {
      // Every failure backs off, expired credentials included: the account token cannot
      // be refreshed, so retrying it on the next poll only spends rate limit. The last
      // good reading keeps being served while the backoff runs.
      let previous = cache[pointer.accountKey]?.quota
      cache[pointer.accountKey] = CachedQuota(
        quota: previous, readyAt: at.addingTimeInterval(Self.failureBackoff))
      return previous
    }
  }

  private func read(token: String, pointer: Pointer) async throws -> ProviderQuota {
    var request = URLRequest(url: keyURL)
    request.httpMethod = "POST"
    // No `onboard`: this is a read. Onboarding on a poll would change the user's account.
    request.httpBody = Data("{}".utf8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(Self.apiVersion, forHTTPHeaderField: "x-api-version")
    request.setValue("Quotio", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    if http.statusCode == 401 || http.statusCode == 403 {
      return ProviderQuota(
        lastUpdated: now(), isForbidden: true, accountDisplayName: pointer.displayName)
    }
    guard 200...299 ~= http.statusCode else {
      throw InfrastructureQuotaFetchError.httpError(http.statusCode)
    }
    // The body of this endpoint carries the Model API key. Only these fields are read.
    guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    let plan = Self.trimmed(body["subs_tier_name"] as? String)
    let display = Self.trimmed((body["user_email"] as? String)?.lowercased())
      ?? pointer.displayName
    if body["is_subs_active"] as? Bool == false {
      return ProviderQuota(
        models: [
          .init(
            name: "muse-subscription", percentage: -1, resetTime: "",
            presentation: .status(text: "muse-inactive"))
        ],
        lastUpdated: now(),
        planType: plan,
        accountDisplayName: display
      )
    }
    guard let usage = body["subs_usage"] as? [String: Any],
      let quota = Self.mapUsage(usage, plan: plan, displayName: display, now: now())
    else {
      throw InfrastructureQuotaFetchError.invalidResponse
    }
    return quota
  }

  /// The keychain payload also holds the Model API key; it is deliberately not read.
  private nonisolated static func accountAccessToken(_ data: Data) -> String? {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    return trimmed(json["access_token"] as? String)
  }

  private nonisolated static func remainingPercentage(_ value: Any?) -> Double? {
    guard let used = number(value) else { return nil }
    return max(0, min(100, 100 - used))
  }

  private nonisolated static func resetTime(_ value: Any?) -> String {
    guard let seconds = number(value), seconds > 0 else { return "" }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
  }

  private nonisolated static func number(_ value: Any?) -> Double? {
    value is NSNumber ? (value as? NSNumber)?.doubleValue : (value as? String).flatMap(Double.init)
  }

  private nonisolated static func trimmed(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }

  private nonisolated static func includes(_ key: String, in scope: QuotaFetchScope) -> Bool {
    switch scope {
    case .provider: true
    case .account(let value): value == key
    case .importedAccounts(let values): values.contains(key)
    }
  }
}
