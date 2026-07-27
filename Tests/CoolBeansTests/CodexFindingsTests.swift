// ABOUTME: Findings from the Codex review — device binding and credential persistence.
// ABOUTME: Both were the difference between a feature working and only appearing to.

import Foundation
import XCTest

@testable import CoolBeans

/// Counts calls from inside a transport stub, which is a Sendable closure.
final class CallCounter: @unchecked Sendable {
	private let lock = NSLock()
	private var value = 0

	var count: Int {
		lock.lock()
		defer { lock.unlock() }
		return value
	}

	func bump() {
		lock.lock()
		defer { lock.unlock() }
		value += 1
	}
}

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
				(200, #"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"clementine","expires_at":null},"instance":{"id":"i","name":"n"}}"#)
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
		// A plain captured var is a data race inside a Sendable closure, and Swift 6.3
		// rejects it outright even though the 6.0 toolchain on the Linux job lets it pass.
		let validateCalls = CallCounter()
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { path, _ in
				if path == "/v1/validate" { validateCalls.bump() }
				if path == "/v1/pubkey" { return (200, #"{"ok":true,"keys":{}}"#) }
				return (200, #"{"ok":true,"license":{"key":"K","status":"disabled","kind":"subscription","product":"clementine","expires_at":null}}"#)
			})
		let gate = LicenseGate(client: cb)
		await gate.refresh()
		XCTAssertEqual(validateCalls.count, 1)
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

/// Storage that reports every write as failed, the way the Keychain does when it refuses
/// an item. Nothing else in the suite can reach that path: `InMemoryStorage` always succeeds.
final class RefusingStorage: CoolBeansStorage, @unchecked Sendable {
	// Reads still work, which is what a Keychain that refuses an add actually looks like.
	// Serving a device id keeps the fingerprint the same across two clients built on this
	// store, so these tests fail on the write rather than on a device check.
	func get(_ key: String) -> String? { key == StorageKey.device ? "MACHINE-A" : nil }
	func set(_ key: String, _ value: String) -> Bool { false }
	func remove(_ key: String) {}
}

final class StorageFailureTests: XCTestCase {
	func testActivationFailsLoudlyWhenTheCredentialCannotBeStored() async throws {
		// A silent failure here is the worst kind: the server has spent a seat, the UI says
		// "activated", and the credential is gone the moment the app quits. The user then
		// re-activates and burns another seat, every launch, until the licence is exhausted.
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: RefusingStorage(),
			transport: StubTransport { _, _ in
				(
					200,
					#"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"clementine","expires_at":null},"instance":{"id":"inst-1","name":"Mac"}}"#
				)
			})
		do {
			_ = try await cb.activate(licenseKey: "K")
			XCTFail("activation must not report success it cannot persist")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "storage_failed")
		}
	}

	func testImportingAnActivationFailsLoudlyWhenItCannotBeStored() async throws {
		let store = RefusingStorage()
		let probe = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		// Bind to the fingerprint this machine actually reports, so the import gets past
		// the device check and fails on the write, which is what is under test.
		let signed = try TestSigner.sign(
			.init(exp: Date().addingTimeInterval(86_400), fingerprint: probe.fingerprint()))
		let cb = CoolBeans(
			configuration: .init(product: "clementine", publicKeys: signed.keys),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		do {
			try await cb.importActivation(signed.token)
			XCTFail("import must not report success it cannot persist")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "storage_failed")
		}
	}
}

/// Storage that refuses writes to one key and serves the rest normally, the way the
/// Keychain can reject a single item while the store keeps working.
final class RefusingOneKeyStorage: CoolBeansStorage, @unchecked Sendable {
	private let inner = InMemoryStorage()
	private let refused: String

	init(refusing: String) { self.refused = refusing }

	/// Write past the refusal, to set up state the machine already had.
	func seed(_ key: String, _ value: String) { inner.set(key, value) }

	func get(_ key: String) -> String? { inner.get(key) }
	func set(_ key: String, _ value: String) -> Bool {
		key == refused ? false : inner.set(key, value)
	}
	func remove(_ key: String) { inner.remove(key) }
}

final class PartialWriteTests: XCTestCase {
	/// A machine with a working activation, and a storage that will refuse one key.
	private func machineWithAWorkingActivation(refusing: String) throws -> (
		cb: CoolBeans, store: RefusingOneKeyStorage, newToken: String
	) {
		let store = RefusingOneKeyStorage(refusing: refusing)
		// Resolve the fingerprint through the same storage, so this reads the hardware id on
		// a Mac and the persisted one elsewhere rather than assuming either.
		let probe = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport { _, _ in (-1, "") })
		let device = probe.fingerprint()

		let old = try TestSigner.sign(
			.init(
				instanceId: "inst-old", exp: Date().addingTimeInterval(86_400), fingerprint: device),
			kid: "1")
		let new = try TestSigner.sign(
			.init(
				instanceId: "inst-new", exp: Date().addingTimeInterval(86_400), fingerprint: device),
			kid: "2")
		store.seed(StorageKey.token, old.token)
		store.seed(StorageKey.instance, "inst-old")

		let cb = CoolBeans(
			configuration: .init(
				product: "clementine", publicKeys: old.keys.merging(new.keys) { a, _ in a }),
			storage: store,
			transport: StubTransport { _, _ in
				(
					200,
					#"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"clementine","expires_at":null},"instance":{"id":"inst-new","name":"Mac"}}"#
				)
			})
		return (cb, store, new.token)
	}

	func testAFailedImportLeavesTheWorkingActivationAlone() async throws {
		// Half a write is worse than none. The instance id lands, the token does not, and
		// offlineState then sees the old token bound to an instance it no longer matches
		// and locks the app — taking away access the machine already had, on a machine
		// that by definition cannot call us to get it back.
		let (cb, store, newToken) = try machineWithAWorkingActivation(refusing: StorageKey.token)
		do {
			try await cb.importActivation(newToken)
			XCTFail("import must not report success it cannot persist")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "storage_failed")
		}
		XCTAssertEqual(store.get(StorageKey.instance), "inst-old")
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}

	func testAFailedActivationLeavesTheWorkingActivationAlone() async throws {
		let (cb, store, _) = try machineWithAWorkingActivation(refusing: StorageKey.license)
		do {
			_ = try await cb.activate(licenseKey: "K")
			XCTFail("activation must not report success it cannot persist")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "storage_failed")
		}
		XCTAssertEqual(store.get(StorageKey.instance), "inst-old")
		let state = await cb.offlineState()
		XCTAssertEqual(state, .valid)
	}
}

/// Storage that forgets everything: reads find nothing, writes do not stick.
final class AmnesiacStorage: CoolBeansStorage, @unchecked Sendable {
	func get(_ key: String) -> String? { nil }
	func set(_ key: String, _ value: String) -> Bool { false }
	func remove(_ key: String) {}
}

final class FingerprintStabilityTests: XCTestCase {
	func testTheFingerprintDoesNotChangeBetweenCalls() {
		// The portable fallback mints a UUID and persists it. When the store cannot keep it,
		// every call used to mint a new one, so the fingerprint a user copied out of the UI
		// was not the one checked at import — a permanent "issued for a different machine"
		// on a machine that cannot call us to sort it out.
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: AmnesiacStorage(),
			transport: StubTransport { _, _ in (-1, "") })
		XCTAssertEqual(cb.fingerprint(), cb.fingerprint())
	}
}
