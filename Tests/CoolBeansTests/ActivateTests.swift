// ABOUTME: The tracer bullet (issue #1) — configuration, device identity, storage, activate.
// ABOUTME: Device identity must survive a reinstall, or every restore burns an activation seat.

import XCTest
@testable import CoolBeans

final class ActivateTests: XCTestCase {
	func testActivateStoresTheInstanceId() async throws {
		let store = InMemoryStorage()
		let client = CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: store,
			transport: StubTransport { _, _ in
				(200, #"{"ok":true,"license":{"key":"CLEM-A2B3-C4D5-E6F7-G8H9","status":"active","kind":"subscription","product":"clementine","expires_at":null},"instance":{"id":"inst-1","name":"Mac"}}"#)
			}
		)
		let result = try await client.activate(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9", name: "Mac")
		XCTAssertEqual(result.instance.id, "inst-1")
		XCTAssertEqual(client.instanceId, "inst-1")
	}

	func testActivateFailsClosedOnAProductMismatch() async throws {
		// A server answering for a different product must never be treated as success:
		// the app would unlock on somebody else's licence.
		let client = CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: InMemoryStorage(),
			transport: StubTransport { _, _ in
				(200, #"{"ok":true,"license":{"key":"K","status":"active","kind":"subscription","product":"somebody-else","expires_at":null},"instance":{"id":"i","name":"n"}}"#)
			}
		)
		do {
			_ = try await client.activate(licenseKey: "K", name: "Mac")
			XCTFail("expected a product mismatch to throw")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "product_mismatch")
		}
	}

	func testServerErrorsCarryTheMachineReadableCode() async throws {
		// Callers branch on the code, so it has to survive rather than becoming prose.
		let client = CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: InMemoryStorage(),
			transport: StubTransport { _, _ in
				(404, #"{"ok":false,"error":"unknown_key","message":"We could not find that license key."}"#)
			}
		)
		do {
			_ = try await client.activate(licenseKey: "K", name: "Mac")
			XCTFail("expected a 404 to throw")
		} catch let error as CoolBeansError {
			XCTAssertEqual(error.code, "unknown_key")
			XCTAssertEqual(error.status, 404)
			XCTAssertTrue(error.localizedDescription.contains("could not find"))
		}
	}

	func testDeviceIdentityIsStableAcrossClients() throws {
		// Two clients over the same durable storage are the same machine. If this ever
		// mints a fresh id, every app restart quietly consumes another seat.
		let store = InMemoryStorage()
		let a = CoolBeans(configuration: .init(product: "p"), storage: store)
		let b = CoolBeans(configuration: .init(product: "p"), storage: store)
		XCTAssertEqual(a.fingerprint(), b.fingerprint())
		XCTAssertFalse(a.fingerprint().isEmpty)
	}
}
