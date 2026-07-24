// ABOUTME: The offline decision table (issue #3), mirroring the TypeScript suite case for case.
// ABOUTME: Three of these lines carry product decisions, not implementation detail.

import XCTest
@testable import CoolBeans

final class OfflineStateTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	private func client(_ token: String?, keys: [String: String], product: String = "clementine")
		-> CoolBeans
	{
		let store = InMemoryStorage()
		if let token { store.set(StorageKey.token, token) }
		store.set(StorageKey.instance, "inst-1")
		return CoolBeans(
			configuration: .init(product: product, publicKeys: keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") },
			clock: { self.now })
	}

	func testValidInsideTheTokenTTL() async throws {
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testPaidTierGetsUnboundedGracePastTheTTL() async throws {
		// §8: a network failure alone never locks anyone out, however long it lasts.
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(-3600)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .grace)
		let unlocked = await cb.verifyOffline()
		XCTAssertTrue(unlocked)
	}

	func testASignedExpiryInThePastEndsAccessForAPaidTier() async throws {
		// The token states the licence ended. Honouring it is reading our own credential,
		// not guessing from a failed request — which is what makes revocation reach a
		// machine that has gone offline.
		let signed = try TestSigner.sign(
			.init(exp: now.addingTimeInterval(3600), expiresAt: now.addingTimeInterval(-86_400)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testLifetimeLicenceKeepsUnboundedGrace() async throws {
		let signed = try TestSigner.sign(
			.init(kind: "perpetual", exp: now.addingTimeInterval(-86_400), expiresAt: nil))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .grace)
	}

	func testTrialGetsNoGraceAtAll() async throws {
		// Unbounded grace on a trial would make a blocked endpoint an unlimited trial.
		let signed = try TestSigner.sign(.init(kind: "trial", exp: now.addingTimeInterval(-1)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testDisabledTokenIsExpired() async throws {
		let signed = try TestSigner.sign(.init(status: "disabled", exp: now.addingTimeInterval(3600)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testWrongProductIsExpired() async throws {
		let signed = try TestSigner.sign(.init(product: "somebody-else", exp: now.addingTimeInterval(3600)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testWrongInstanceIsExpired() async throws {
		// A token copied to another machine must not unlock it.
		let signed = try TestSigner.sign(
			.init(instanceId: "some-other-machine", exp: now.addingTimeInterval(3600)))
		let cb = client(signed.token, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testATamperedSignatureIsExpired() async throws {
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let other = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let parts = signed.token.split(separator: ".").map(String.init)
		let tampered = "\(parts[0]).\(parts[1]).\(other.token.split(separator: ".").map(String.init)[2])"
		let cb = client(tampered, keys: signed.keys)
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testNoTrustedKeyFailsClosed() async throws {
		// Someone who has never been online has nothing to check a signature against.
		// Unlocking there would make the token meaningless.
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let cb = client(signed.token, keys: [:])
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}

	func testNoTokenIsExpired() async throws {
		let cb = client(nil, keys: ["1": "irrelevant"])
		let state = await cb.offlineState()
		XCTAssertEqual(state, .expired)
	}
}
