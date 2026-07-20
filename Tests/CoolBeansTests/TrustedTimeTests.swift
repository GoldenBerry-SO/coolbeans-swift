// ABOUTME: Clock-rollback protection (issue #5) and rotation-safe keysets (issue #6).
// ABOUTME: Rolling the clock back must not resurrect an expired licence, but must not lock out either.

import XCTest
@testable import CoolBeans

final class TrustedTimeTests: XCTestCase {
	private let real = Date(timeIntervalSince1970: 1_800_000_000)

	func testWatermarkAdvancesAndNeverRetreats() {
		let store = InMemoryStorage()
		let cb = CoolBeans(configuration: .init(product: "p"), storage: store, clock: { self.real })
		cb.advanceTrustedTime(to: real)
		cb.advanceTrustedTime(to: real.addingTimeInterval(-86_400))
		XCTAssertEqual(cb.trustedTime, real)
		cb.advanceTrustedTime(to: real.addingTimeInterval(3600))
		XCTAssertEqual(cb.trustedTime, real.addingTimeInterval(3600))
	}

	func testRollingTheClockBackDoesNotResurrectAnExpiredLicence() async throws {
		// The attack this closes: set the date back and every expiry comparison passes again.
		let signed = try TestSigner.sign(
			.init(exp: real.addingTimeInterval(86_400), expiresAt: real.addingTimeInterval(-3600)))
		let store = InMemoryStorage()
		store.set(StorageKey.token, signed.token)
		store.set(StorageKey.instance, "inst-1")

		// Clock wound back a year, but we have seen the real time.
		let rewound = real.addingTimeInterval(-365 * 86_400)
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") },
			clock: { rewound })
		cb.advanceTrustedTime(to: self.real)

		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testAClockBehindTheWatermarkIsNeverALockout() async throws {
		// A dead CMOS battery or a fresh VM is innocent. Distrust the clock, do not punish.
		let signed = try TestSigner.sign(.init(exp: real.addingTimeInterval(86_400)))
		let store = InMemoryStorage()
		store.set(StorageKey.token, signed.token)
		store.set(StorageKey.instance, "inst-1")
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") },
			clock: { self.real.addingTimeInterval(-86_400 * 30) })
		cb.advanceTrustedTime(to: self.real)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testAFreshInstallWithNoWatermarkTrustsTheClock() async throws {
		let signed = try TestSigner.sign(.init(exp: real.addingTimeInterval(86_400)))
		let store = InMemoryStorage()
		store.set(StorageKey.token, signed.token)
		store.set(StorageKey.instance, "inst-1")
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") },
			clock: { self.real })
		XCTAssertNil(cb.trustedTime)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}
}

final class KeyRotationTests: XCTestCase {
	func testATokenSignedByARotatedInKeyVerifiesAfterRefresh() async throws {
		// Rotation is why the server supports several active keys at once.
		let rotated = try TestSigner.sign(
			.init(exp: Date().addingTimeInterval(3600)), kid: "2")
		let store = InMemoryStorage()
		store.set(StorageKey.instance, "inst-1")
		let keysJSON = "{\"2\":\"\(rotated.keys["2"]!)\"}"

		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: [:]),
			storage: store,
			transport: StubTransport { path, _ in
				if path == "/v1/pubkey" { return (200, #"{"ok":true,"keys":\#(keysJSON)}"#) }
				return (200, #"{"ok":true,"license":{"key":"K","status":"active","tier":"yearly","product":"clementine","expires_at":null},"token":"\#(rotated.token)"}"#)
			})
		_ = try await cb.verify(licenseKey: "K", instanceId: "inst-1")
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testEmbeddedKeysSurviveAFetchedSet() async throws {
		// The embedded key ships inside a signed binary and is the trust anchor. A fetched
		// response must never be able to replace it.
		let embedded = try TestSigner.sign(.init(exp: Date().addingTimeInterval(3600)), kid: "emb")
		let store = InMemoryStorage()
		store.set(StorageKey.instance, "inst-1")
		store.set(StorageKey.token, embedded.token)
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: embedded.keys),
			storage: store,
			transport: StubTransport { _, _ in (200, #"{"ok":true,"keys":{"other":"AAAA"}}"#) })
		await cb.refreshKeys()
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testAMalformedKeysetIsIgnored() async throws {
		let embedded = try TestSigner.sign(.init(exp: Date().addingTimeInterval(3600)), kid: "emb")
		let store = InMemoryStorage()
		store.set(StorageKey.instance, "inst-1")
		store.set(StorageKey.token, embedded.token)
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: embedded.keys),
			storage: store,
			transport: StubTransport { _, _ in (200, "garbage") })
		await cb.refreshKeys()
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}
}

final class WatermarkWiringTests: XCTestCase {
	func testASuccessfulVerifyAdvancesTheWatermarkOnItsOwn() async throws {
		// Without this the watermark is never set in a real app, and the whole
		// rollback protection is inert while looking implemented.
		let issued = Date(timeIntervalSince1970: 1_700_000_000)
		let signed = try TestSigner.sign(.init(exp: Date().addingTimeInterval(3600)))
		let store = InMemoryStorage()
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { path, _ in
				if path == "/v1/pubkey" { return (200, #"{"ok":true,"keys":{}}"#) }
				return (200, #"{"ok":true,"license":{"key":"K","status":"active","tier":"yearly","product":"clementine","expires_at":null},"token":"\#(signed.token)"}"#)
			})
		XCTAssertNil(cb.trustedTime)
		_ = try await cb.verify(licenseKey: "K", instanceId: "inst-1")
		// The token's iat is server-stamped, so it is a time we have reason to trust.
		XCTAssertEqual(cb.trustedTime, issued)
	}

	func testImportingAnOfflineActivationAlsoAdvancesIt() async throws {
		let issued = Date(timeIntervalSince1970: 1_700_000_000)
		let store = InMemoryStorage()
		store.set(StorageKey.device, "THIS-MACHINE")
		let probe = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		// The blob must be minted for this machine, or the binding check refuses it.
		let signed = try TestSigner.sign(
			.init(exp: Date().addingTimeInterval(86_400), fingerprint: probe.fingerprint()))
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		try await cb.importActivation(signed.token)
		XCTAssertEqual(cb.trustedTime, issued)
	}
}
