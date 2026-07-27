// ABOUTME: The online decision table (issue #2) and the seat endpoints (issue #4).
// ABOUTME: Everything ambiguous resolves in the user's favour; only explicit disabled revokes.

import XCTest
@testable import CoolBeans

final class VerifyTests: XCTestCase {
	private func make(_ handler: @escaping @Sendable (String, String) -> (Int, String))
		-> (CoolBeans, InMemoryStorage)
	{
		let store = InMemoryStorage()
		store.set(StorageKey.token, "cached.token.value")
		let cb = CoolBeans(
			configuration: .init(product: "clementine"),
			storage: store,
			transport: StubTransport(handler: handler))
		return (cb, store)
	}

	private static let ok =
		#"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"clementine","expires_at":null},"token":"fresh.token.value"}"#

	func testActiveRefreshesTheCachedToken() async throws {
		let (cb, store) = make { _, _ in (200, Self.ok) }
		let result = try await cb.verify(licenseKey: "K", instanceId: "i")
		XCTAssertTrue(result.valid)
		XCTAssertFalse(result.inconclusive)
		XCTAssertEqual(store.get(StorageKey.token), "fresh.token.value")
	}

	func testNetworkFailureIsInconclusiveAndLeavesTheTokenAlone() async throws {
		// §8: an inconclusive answer must never lock anyone out.
		let (cb, store) = make { _, _ in (-1, "") }
		let result = try await cb.verify(licenseKey: "K", instanceId: "i")
		XCTAssertTrue(result.inconclusive)
		XCTAssertTrue(result.offline)
		XCTAssertEqual(store.get(StorageKey.token), "cached.token.value")
	}

	func testServerErrorsAreInconclusiveAndNotOffline() async throws {
		for status in [404, 429, 500] {
			let (cb, store) = make { _, _ in (status, #"{"ok":false,"error":"nope"}"#) }
			let result = try await cb.verify(licenseKey: "K", instanceId: "i")
			XCTAssertTrue(result.inconclusive, "status \(status)")
			XCTAssertFalse(result.offline, "status \(status)")
			XCTAssertEqual(store.get(StorageKey.token), "cached.token.value", "status \(status)")
		}
	}

	func testMalformedBodyIsInconclusive() async throws {
		let (cb, store) = make { _, _ in (200, "not json at all") }
		let result = try await cb.verify(licenseKey: "K", instanceId: "i")
		XCTAssertTrue(result.inconclusive)
		XCTAssertEqual(store.get(StorageKey.token), "cached.token.value")
	}

	func testAProductMismatchIsInconclusiveNotSuccess() async throws {
		let (cb, store) = make { _, _ in
			(200, #"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"other","expires_at":null},"token":"t"}"#)
		}
		let result = try await cb.verify(licenseKey: "K", instanceId: "i")
		XCTAssertTrue(result.inconclusive)
		XCTAssertFalse(result.valid)
		XCTAssertEqual(store.get(StorageKey.token), "cached.token.value")
	}

	func testDisabledIsTheOneDefinitiveRevocation() async throws {
		// The only path that takes access away. It must clear the cached token, or the
		// app would keep unlocking offline after being revoked.
		let (cb, store) = make { _, _ in
			(200, #"{"ok":true,"license":{"key":"K","status":"disabled","kind":"subscription","product":"clementine","expires_at":null}}"#)
		}
		let result = try await cb.verify(licenseKey: "K", instanceId: "i")
		XCTAssertFalse(result.valid)
		XCTAssertFalse(result.inconclusive)
		XCTAssertNil(store.get(StorageKey.token))
	}
}

final class SeatTests: XCTestCase {
	func testDeactivateClearsLocalState() async throws {
		let store = InMemoryStorage()
		store.set(StorageKey.token, "t")
		store.set(StorageKey.instance, "i")
		let cb = CoolBeans(
			configuration: .init(product: "p"),
			storage: store,
			transport: StubTransport { _, _ in (200, #"{"ok":true}"#) })
		try await cb.deactivate(licenseKey: "K", instanceId: "i")
		// Believing we still hold a released seat is how an app ends up wrong about itself.
		XCTAssertNil(store.get(StorageKey.instance))
		XCTAssertNil(store.get(StorageKey.token))
	}

	func testHeartbeatReturnsTheRenewedLease() async throws {
		let cb = CoolBeans(
			configuration: .init(product: "p"),
			storage: InMemoryStorage(),
			transport: StubTransport { _, _ in
				(200, #"{"ok":true,"lease_expires_at":"2027-01-01T00:00:00Z"}"#)
			})
		let lease = try await cb.heartbeat(licenseKey: "K", instanceId: "i")
		XCTAssertEqual(lease, "2027-01-01T00:00:00Z")
	}

	func testANullLeaseIsADistinctOutcome() async throws {
		// null means nothing was renewed — unknown instance, lapsed lease with no free
		// seat, or a node-locked product. A caller needs to tell that from "renewed".
		let cb = CoolBeans(
			configuration: .init(product: "p"),
			storage: InMemoryStorage(),
			transport: StubTransport { _, _ in (200, #"{"ok":true,"lease_expires_at":null}"#) })
		let lease = try await cb.heartbeat(licenseKey: "K", instanceId: "i")
		XCTAssertNil(lease)
	}
}
