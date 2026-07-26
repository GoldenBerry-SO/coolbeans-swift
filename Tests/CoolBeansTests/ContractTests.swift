// ABOUTME: The shared access-state contract (#77) — the same cases @coolbeans/sdk runs, verbatim.
// ABOUTME: If the two SDKs ever disagree about who keeps working, one of these fails.

import XCTest

@testable import CoolBeans

private struct Contract: Decodable {
	let version: Int
	let product: String
	let instance: String
	let cases: [Case]

	struct Case: Decodable {
		let name: String
		let token: TokenSpec?
		let revoked: Bool?
		let steps: [Double]
		let expect: Expectation
	}

	struct TokenSpec: Decodable {
		let status: String
		let kind: String
		/// Seconds from T0 to the licence's end, or nil for a licence that has none.
		let expiresIn: Double?
		/// The token's own lifetime in seconds.
		let ttl: Double
		let entitlements: [String: EntitlementValue]?
	}

	struct Expectation: Decodable {
		let decision: String
		let reason: String
		let entitlements: [String: EntitlementValue]?
		/// Distinguishes "expects no capabilities" from "does not check them".
		let checksEntitlements: Bool

		enum CodingKeys: String, CodingKey { case decision, reason, entitlements }

		init(from decoder: Decoder) throws {
			let c = try decoder.container(keyedBy: CodingKeys.self)
			decision = try c.decode(String.self, forKey: .decision)
			reason = try c.decode(String.self, forKey: .reason)
			entitlements = try c.decodeIfPresent([String: EntitlementValue].self, forKey: .entitlements)
			checksEntitlements = c.contains(.entitlements)
		}
	}
}

final class ContractTests: XCTestCase {
	private let t0 = Date(timeIntervalSince1970: 1_772_236_800)

	private func loadContract() throws -> Contract {
		let url = try XCTUnwrap(
			Bundle.module.url(forResource: "access-states", withExtension: "json"),
			"access-states.json is missing from the test bundle")
		return try JSONDecoder().decode(Contract.self, from: Data(contentsOf: url))
	}

	func testEveryContractCase() async throws {
		let contract = try loadContract()
		XCTAssertEqual(contract.version, 1, "the contract moved; re-read it before bumping this")

		for testCase in contract.cases {
			let store = InMemoryStorage()
			var keys: [String: String] = [:]
			if let spec = testCase.token {
				let signed = try TestSigner.sign(
					.init(
						status: spec.status,
						kind: spec.kind,
						product: contract.product,
						instanceId: contract.instance,
						exp: t0.addingTimeInterval(spec.ttl),
						expiresAt: spec.expiresIn.map { t0.addingTimeInterval($0) },
						entitlements: spec.entitlements),
					iat: t0)
				store.set(StorageKey.token, signed.token)
				store.set(StorageKey.instance, contract.instance)
				keys = signed.keys
			}
			if testCase.revoked == true { store.set(StorageKey.revoked, "1") }

			// Every evaluation is offline: these cases are about what the SDK concludes from what
			// it already holds, which is exactly where a lockout bug hides.
			let clock = MovableClock(now: t0)
			let cb = CoolBeans(
				configuration: .init(product: contract.product, publicKeys: keys),
				storage: store,
				// -1 is this stub's "could not reach the server at all".
				transport: StubTransport { _, _ in (-1, "") },
				clock: { clock.now })

			var state = await cb.open()
			for step in testCase.steps {
				clock.advance(by: step)
				state = await cb.open()
			}

			XCTAssertEqual(state.decision.rawValue, testCase.expect.decision, testCase.name)
			XCTAssertEqual(state.reason.rawValue, testCase.expect.reason, testCase.name)
			if testCase.expect.checksEntitlements {
				XCTAssertEqual(state.entitlements, testCase.expect.entitlements, testCase.name)
			}
		}
	}

	func testTheContractCoversEveryReasonThisSDKCanReturn() throws {
		// A reason nobody has a case for is a reason nobody has agreed on. `online` is the one
		// these offline cases cannot produce, and the one state that is not in dispute.
		let contract = try loadContract()
		let covered = Set(contract.cases.map(\.expect.reason))
		for reason in AccessReason.allCases where reason != .online {
			XCTAssertTrue(covered.contains(reason.rawValue), "no contract case for \(reason.rawValue)")
		}
	}
}

/// A clock a test can move. A plain captured `var` is a data race the compiler is right to
/// complain about, and Swift 6 makes it an error.
private final class MovableClock: @unchecked Sendable {
	private let lock = NSLock()
	private var current: Date

	init(now: Date) { current = now }

	var now: Date {
		lock.lock()
		defer { lock.unlock() }
		return current
	}

	func advance(by seconds: Double) {
		lock.lock()
		defer { lock.unlock() }
		current = current.addingTimeInterval(seconds)
	}
}
