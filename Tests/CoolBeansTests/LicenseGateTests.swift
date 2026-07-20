// ABOUTME: The behaviour behind the example app's UI (issue #7), testable without a Mac.
// ABOUTME: Keeping this out of the SwiftUI view is what lets the gating logic be verified at all.

import XCTest
@testable import CoolBeans

@MainActor
final class LicenseGateTests: XCTestCase {
	private let now = Date(timeIntervalSince1970: 1_800_000_000)

	private func gate(token: String?, keys: [String: String], handler: @escaping @Sendable (String, String) -> (Int, String)) -> LicenseGate {
		let store = InMemoryStorage()
		if let token { store.set(StorageKey.token, token) }
		store.set(StorageKey.instance, "inst-1")
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: keys),
			storage: store,
			transport: StubTransport(handler: handler),
			clock: { self.now })
		return LicenseGate(client: cb)
	}

	func testExposesTheDeviceFingerprintForAirGappedActivation() {
		// The example app shows this so an operator can mint an offline activation from it.
		let g = gate(token: nil, keys: [:]) { _, _ in (-1, "") }
		XCTAssertFalse(g.deviceFingerprint.isEmpty)
	}

	func testStartsLockedWithNothingStored() async {
		let g = gate(token: nil, keys: [:]) { _, _ in (-1, "") }
		await g.refresh()
		XCTAssertFalse(g.isUnlocked)
		XCTAssertEqual(g.status, .locked)
	}

	func testUnlocksOfflineWithoutTouchingTheNetwork() async throws {
		// The app must be usable the instant it launches, before any request settles.
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let g = gate(token: signed.token, keys: signed.keys) { _, _ in
			XCTFail("refresh must not block on the network")
			return (-1, "")
		}
		let unlocked = await g.unlockedOffline()
		XCTAssertTrue(unlocked)
	}

	func testGraceStillUnlocksAndIsNotShownAsAnError() async throws {
		// grace means "we have not checked in a while", which happens on a plane. It is a
		// normal state, and an app that shouts about it trains users to ignore warnings.
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(-3600)))
		let g = gate(token: signed.token, keys: signed.keys) { _, _ in (-1, "") }
		await g.refresh()
		XCTAssertTrue(g.isUnlocked)
		XCTAssertEqual(g.status, .grace)
		XCTAssertFalse(g.status.isError)
	}

	func testANetworkFailureNeverLocksAnUnlockedApp() async throws {
		// §8, expressed in UI terms: a failed check must not take away what works.
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let g = gate(token: signed.token, keys: signed.keys) { _, _ in (-1, "") }
		await g.refresh()
		XCTAssertTrue(g.isUnlocked)
		XCTAssertEqual(g.status, .active)
	}

	func testAnExplicitDisableLocksTheApp() async throws {
		let signed = try TestSigner.sign(.init(exp: now.addingTimeInterval(3600)))
		let g = gate(token: signed.token, keys: signed.keys) { path, _ in
			if path == "/v1/pubkey" { return (200, #"{"ok":true,"keys":{}}"#) }
			return (200, #"{"ok":true,"license":{"key":"K","status":"disabled","tier":"yearly","product":"clementine","expires_at":null}}"#)
		}
		await g.refresh(licenseKey: "K")
		XCTAssertFalse(g.isUnlocked)
		XCTAssertEqual(g.status, .revoked)
		XCTAssertTrue(g.status.isError)
	}

	func testASeatLimitSurfacesTheServerSentence() async {
		// Callers show this to a person, so it must be the server's words, not a code.
		let g = gate(token: nil, keys: [:]) { _, _ in
			(409, #"{"ok":false,"error":"activation_limit_reached","message":"This license is already active on 3 devices."}"#)
		}
		await g.activate(licenseKey: "K")
		XCTAssertFalse(g.isUnlocked)
		let error = g.lastError
		XCTAssertEqual(error?.code, "activation_limit_reached")
		XCTAssertTrue(error?.message.contains("already active on 3") ?? false)
	}
}
