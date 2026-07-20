// ABOUTME: Findings from the Codex review — device binding and credential persistence.
// ABOUTME: Both were the difference between a feature working and only appearing to.

import XCTest
@testable import CoolBeans

final class OfflineBindingTests: XCTestCase {
	func testACopiedActivationCannotUnlockAnotherMachine() async throws {
		// The hole: import stored the token's own instance id, then offlineState compared
		// the token against the value the token had just supplied. Circular, so a blob
		// minted for one machine unlocked any machine it was pasted into.
		let signed = try TestSigner.sign(
			.init(exp: Date().addingTimeInterval(86_400), fingerprint: "MACHINE-A"))
		let store = InMemoryStorage()
		store.set(StorageKey.device, "MACHINE-B")
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })

		do {
			try await cb.importActivation(signed.token)
			XCTFail("a blob for another machine must not import")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "wrong_device")
		}
		let unlocked = await cb.verifyOffline()
		XCTAssertFalse(unlocked)
	}

	func testAnActivationForThisMachineImports() async throws {
		let store = InMemoryStorage()
		store.set(StorageKey.device, "MACHINE-A")
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		let signed = try TestSigner.sign(
			.init(exp: Date().addingTimeInterval(86_400), fingerprint: cb.fingerprint()))
		let bound = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		try await bound.importActivation(signed.token)
		let state = await bound.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testABlobWithNoFingerprintClaimIsRefused() async throws {
		// An unbound blob is exactly the thing this check exists to stop, so it must not
		// be treated as "nothing to verify, therefore fine".
		let signed = try TestSigner.sign(.init(exp: Date().addingTimeInterval(86_400)))
		let store = InMemoryStorage()
		store.set(StorageKey.device, "MACHINE-A")
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		do {
			try await cb.importActivation(signed.token)
			XCTFail("an unbound activation must not import")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "unbound_activation")
		}
	}
}

@MainActor
final class CredentialPersistenceTests: XCTestCase {
	func testActivateRemembersTheLicenceKey() async throws {
		// Without this, nothing after activation can verify: the next launch has no key,
		// so refresh never calls the server and revocation never arrives.
		let store = InMemoryStorage()
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in
				(200, #"{"ok":true,"license":{"key":"K","status":"active","tier":"yearly","product":"clementine","expires_at":null},"instance":{"id":"i","name":"n"}}"#)
			})
		_ = try await cb.activate(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9", name: "Mac")
		XCTAssertEqual(cb.licenseKey, "CLEM-A2B3-C4D5-E6F7-G8H9")
	}

	func testTheGateVerifiesOnRelaunchWithoutBeingHandedTheKey() async throws {
		// The example app calls refresh() with no argument on every launch. If the key is
		// not persisted that call silently stops short of the server forever.
		let store = InMemoryStorage()
		store.set(StorageKey.instance, "inst-1")
		store.set(StorageKey.license, "CLEM-A2B3-C4D5-E6F7-G8H9")
		var validateCalls = 0
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { path, _ in
				if path == "/v1/validate" { validateCalls += 1 }
				if path == "/v1/pubkey" { return (200, #"{"ok":true,"keys":{}}"#) }
				return (200, #"{"ok":true,"license":{"key":"K","status":"disabled","tier":"yearly","product":"clementine","expires_at":null}}"#)
			})
		let gate = LicenseGate(client: cb)
		await gate.refresh()
		XCTAssertEqual(validateCalls, 1)
		// And a revocation that arrives this way actually locks the app.
		XCTAssertEqual(gate.status, .revoked)
	}

	func testDeactivateClearsTheStoredKey() async throws {
		let store = InMemoryStorage()
		store.set(StorageKey.instance, "i")
		store.set(StorageKey.license, "K")
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in (200, #"{"ok":true}"#) })
		try await cb.deactivate(licenseKey: "K", instanceId: "i")
		XCTAssertNil(cb.licenseKey)
	}
}
