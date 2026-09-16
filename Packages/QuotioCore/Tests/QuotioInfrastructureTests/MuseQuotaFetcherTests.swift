import Foundation
import QuotioApplication
import QuotioDomain
import XCTest

@testable import QuotioInfrastructure

final class MuseQuotaFetcherTests: XCTestCase {
  private static let pointer = """
    {"schema_version":2,"providers":{"meta":{"mechanism":"oauth","storage":"keychain",
    "api_base_url":"https://api.meta.ai/v1","user_email":"Developer@Example.test"}}}
    """
  /// Shaped like the subscription-key response, including the field this fetcher must
  /// never read back out.
  private static let keyResponse = """
    {"api_key":"LLM|1234567890|key-material","is_subs_active":true,
    "subs_tier_name":"Muse Code Pro","user_email":"developer@example.test",
    "user_id":"1234567890","subs_usage":{"tier":"1234567890",
    "window":{"used_percent":12,"resets_at":1788431188,"window_duration_mins":300},
    "weekly":{"used_percent":40,"resets_at":1788739200}}}
    """
  private static let keychain = """
    {"api_key":"LLM|1234567890|key-material","access_token":"meta-account-token"}
    """

  func testPointerNamesTheAccountByEmailAndFallsBackWhenItIsAbsent() {
    let named = MuseQuotaFetcher.loadPointer(data: Data(Self.pointer.utf8))
    XCTAssertEqual(named?.accountKey, "developer@example.test")
    XCTAssertEqual(named?.displayName, "developer@example.test")

    let anonymous = MuseQuotaFetcher.loadPointer(
      data: Data(#"{"providers":{"meta":{"storage":"keychain"}}}"#.utf8))
    XCTAssertEqual(anonymous?.accountKey, MuseQuotaFetcher.localAccountKey)
    XCTAssertNil(anonymous?.displayName)

    XCTAssertNil(MuseQuotaFetcher.loadPointer(data: Data(#"{"providers":{}}"#.utf8)))
    XCTAssertNil(MuseQuotaFetcher.loadPointer(data: Data("not json".utf8)))
  }

  func testSendsTheAccountTokenAndReportsBothWindowsAsRemainingPercentages() async throws {
    let session = MuseSession { request in
      XCTAssertEqual(request.url?.absoluteString, "https://api.meta.ai/muse-code/key")
      XCTAssertEqual(request.httpMethod, "POST")
      // The account token reads usage; the Model API key in the keychain must not be
      // sent here, and `onboard` would change the account on a poll.
      XCTAssertEqual(
        request.value(forHTTPHeaderField: "Authorization"), "Bearer meta-account-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-version"), "1.0.0")
      XCTAssertEqual(request.httpBody, Data("{}".utf8))
      return (Self.keyResponse, 200)
    }
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: session, now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .present)
    XCTAssertEqual(output.credentialAccountKeys, ["developer@example.test"])
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])
    XCTAssertEqual(quota.planType, "Muse Code Pro")
    XCTAssertEqual(quota.accountDisplayName, "developer@example.test")
    let session5h = try XCTUnwrap(quota.models.first { $0.name == "muse-session" })
    XCTAssertEqual(session5h.percentage, 88)
    XCTAssertEqual(session5h.usedPercentage, 12)
    XCTAssertEqual(
      ISO8601DateFormatter().date(from: session5h.resetTime),
      Date(timeIntervalSince1970: 1_788_431_188))
    let weekly = try XCTUnwrap(quota.models.first { $0.name == "muse-weekly" })
    XCTAssertEqual(weekly.percentage, 60)
    XCTAssertEqual(
      ISO8601DateFormatter().date(from: weekly.resetTime),
      Date(timeIntervalSince1970: 1_788_739_200))
  }

  func testNeverCarriesTheModelAPIKeyOutOfTheResponse() async throws {
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in (Self.keyResponse, 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    let rendered =
      [quota.planType, quota.accountDisplayName].compactMap { $0 }
      + quota.models.flatMap { [$0.name, $0.resetTime, $0.tooltip ?? ""] }
    for value in rendered {
      XCTAssertFalse(value.contains("LLM|"), "leaked the Model API key in \(value)")
      XCTAssertFalse(value.contains("key-material"), "leaked the Model API key in \(value)")
    }
  }

  func testCarriesAWindowOfAnotherDurationUnderItsOwnNameInsteadOfTheSessionSlot() {
    let usage: [String: Any] = [
      "window": ["used_percent": 25, "resets_at": 1_788_431_188, "window_duration_mins": 600]
    ]
    let quota = MuseQuotaFetcher.mapUsage(
      usage, plan: nil, displayName: nil, now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(quota.models.map(\.name), ["muse-window-600", "muse-weekly"])
    XCTAssertEqual(quota.models.first?.percentage, 75)
  }

  func testAWindowWithNoDeclaredDurationStaysTheSessionWindow() {
    let quota = MuseQuotaFetcher.mapUsage(
      ["window": ["used_percent": 0]], plan: nil, displayName: nil,
      now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(quota.models.map(\.name), ["muse-session", "muse-weekly"])
    XCTAssertEqual(quota.models.first?.resetTime, "")
  }

  /// A window whose only readable field is its reset time still reports Unknown, not a
  /// fetch failure: `percentage < 0` is this app's existing "unknown" sentinel, rendered
  /// as unavailable by the presentation layer.
  func testAWindowWithNoReadablePercentageIsUnknownRatherThanOmitted() {
    let quota = MuseQuotaFetcher.mapUsage(
      ["window": ["resets_at": 1_788_431_188]], plan: "Muse Code Pro", displayName: nil,
      now: Date(timeIntervalSince1970: 1_788_000_000))

    XCTAssertEqual(quota.models.map(\.name), ["muse-session", "muse-weekly"])
    XCTAssertEqual(quota.models[0].percentage, -1)
    XCTAssertEqual(quota.planType, "Muse Code Pro")
  }

  /// Reproduces the real response of an active "Muse Code High Usage" subscription,
  /// measured live 2026-09-16: `is_subs_active: true` with no `subs_usage` object at
  /// all. Meta appears to only attach it around a mint, not on every read. The account
  /// and plan were read correctly and must not be reported as a fetch failure.
  func testAnActiveSubscriptionWithNoSubsUsageReportsUnknownWindowsNotAFailure() async throws {
    let body = """
      {"api_key":"LLM|1234567890|key-material","is_subs_active":true,
      "subs_tier_name":"Muse Code High Usage","user_email":"user@example.test"}
      """
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in (body, 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    XCTAssertEqual(quota.planType, "Muse Code High Usage")
    XCTAssertEqual(quota.models.map(\.name), ["muse-session", "muse-weekly"])
    XCTAssertTrue(quota.models.allSatisfy { $0.percentage < 0 })
  }

  func testInactiveSubscriptionReportsAStatusInsteadOfInventedWindows() async throws {
    let body = """
      {"api_key":"LLM|1234567890|key-material","is_subs_active":false,
      "subs_tier_name":"Muse Code Free"}
      """
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in (body, 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let quota = try XCTUnwrap(output.quotas["developer@example.test"])

    XCTAssertEqual(quota.planType, "Muse Code Free")
    XCTAssertEqual(quota.models.map(\.presentation), [.status(text: "muse-inactive")])
  }

  func testRejectedCredentialMarksTheAccountForbiddenRatherThanEmpty() async throws {
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in (#"{"error":"invalid_api_key"}"#, 401) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.quotas["developer@example.test"]?.isForbidden, true)
  }

  func testMissingPointerReportsTheCredentialAsMissing() async throws {
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(nil), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in XCTFail("no request without a pointer"); return ("", 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .missing)
    XCTAssertEqual(output.credentialAccountKeys, [])
  }

  func testAnUnreadableKeychainLeavesTheAccountVisibleWithoutQuota() async throws {
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(nil),
      session: MuseSession { _ in XCTFail("no request without a token"); return ("", 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .present)
    XCTAssertEqual(output.credentialAccountKeys, ["developer@example.test"])
    XCTAssertTrue(output.quotas.isEmpty)
  }

  func testAnotherAccountInScopeIsNotFetched() async throws {
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: MuseSession { _ in XCTFail("out of scope"); return ("", 200) },
      now: { Date(timeIntervalSince1970: 1_788_000_000) })

    let output = try await fetcher.fetch(
      .init(provider: .muse, scope: .account("someone-else@example.test"), mode: .monitor))

    XCTAssertEqual(output.credentialAvailability, .present)
    XCTAssertTrue(output.quotas.isEmpty)
  }

  func testAForcedRefreshInsideTheWindowServesTheLastReadWithoutSpendingAKeyRequest()
    async throws
  {
    let clock = MuseClock(Date(timeIntervalSince1970: 1_788_000_000))
    let session = MuseSession { _ in (Self.keyResponse, 200) }
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: session, now: { clock.date })

    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    clock.advance(MuseQuotaFetcher.refreshInterval - 1)
    let cached = try await fetcher.fetch(.init(provider: .muse, mode: .monitor, force: true))
    let requests1 = await session.count()
    XCTAssertEqual(requests1, 1)
    XCTAssertNotNil(cached.quotas["developer@example.test"])

    clock.advance(2)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let requests2 = await session.count()
    XCTAssertEqual(requests2, 2)
  }

  func testAFailureBacksOffAndKeepsServingTheLastGoodReading() async throws {
    let clock = MuseClock(Date(timeIntervalSince1970: 1_788_000_000))
    let session = MuseSession { _ in (Self.keyResponse, 200) }
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: session, now: { clock.date })

    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    clock.advance(MuseQuotaFetcher.refreshInterval)
    await session.fail(true)
    let backedOff = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let afterFailure = await session.count()
    XCTAssertEqual(afterFailure, 2)
    XCTAssertNotNil(backedOff.quotas["developer@example.test"])

    clock.advance(MuseQuotaFetcher.failureBackoff - 1)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor, force: true))
    let stillTwo = await session.count()
    XCTAssertEqual(stillTwo, 2, "a forced refresh must not spend a key request")

    clock.advance(2)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    let requests3 = await session.count()
    XCTAssertEqual(requests3, 3)
  }

  func testABackoffWithNothingCachedYetLeavesTheAccountWithoutQuota() async throws {
    let clock = MuseClock(Date(timeIntervalSince1970: 1_788_000_000))
    let session = MuseSession { _ in ("", 429) }
    let fetcher = MuseQuotaFetcher(
      files: MuseFileReader(Self.pointer), credentials: MuseCredentials(Self.keychain),
      session: session, now: { clock.date })

    let first = try await fetcher.fetch(.init(provider: .muse, mode: .monitor))
    XCTAssertTrue(first.quotas.isEmpty)
    XCTAssertEqual(first.credentialAvailability, .present)

    clock.advance(MuseQuotaFetcher.failureBackoff - 1)
    _ = try await fetcher.fetch(.init(provider: .muse, mode: .monitor, force: true))
    let requests1 = await session.count()
    XCTAssertEqual(requests1, 1)
  }
}

private struct MuseFileReader: QuotaCredentialFileReading {
  let payload: String?
  init(_ payload: String?) { self.payload = payload }
  func read(path: String) async -> Data? { payload.map { Data($0.utf8) } }
}

private actor MuseCredentials: ExternalCredentialReading {
  private let payload: String?
  init(_ payload: String?) { self.payload = payload }

  func read(service: String, account: String?) -> ExternalCredentialRecord? {
    guard service == MuseQuotaFetcher.keychainService,
      account == MuseQuotaFetcher.keychainAccount, let payload
    else { return nil }
    return ExternalCredentialRecord(data: Data(payload.utf8), account: account ?? "")
  }

  func compareAndSwap(service: String, account: String, expectedData: Data, newData: Data) -> Bool {
    false
  }
}

private actor MuseSession: QuotaHTTPSession {
  typealias Handler = @Sendable (URLRequest) -> (String, Int)
  private let handler: Handler
  private var requests = 0
  private var failing = false

  init(_ handler: @escaping Handler) { self.handler = handler }
  func count() -> Int { requests }
  func fail(_ value: Bool) { failing = value }

  func data(for request: URLRequest) -> (Data, URLResponse) {
    requests += 1
    let (body, status) = failing ? ("", 429) : handler(request)
    return (
      Data(body.utf8),
      HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    )
  }
}

private final class MuseClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date
  init(_ value: Date) { self.value = value }
  var date: Date { lock.withLock { value } }
  func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}
