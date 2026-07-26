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

/// Signing out (#78) — the last place an app had to keep an instance id.
final class ReleaseTests: XCTestCase {
	private func client(_ handler: @escaping @Sendable (String, String) -> (Int, String)) -> CoolBeans {
		CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: InMemoryStorage(),
			transport: StubTransport(handler: handler))
	}

	func testReleaseFreesTheSeatWithNothingHandedToIt() async throws {
		let cb = client { path, _ in
			switch path {
			case "/v1/activate":
				return (
					200,
					#"{"ok":true,"license":{"key":"K","status":"active","kind":"perpetual","product":"clementine","expires_at":null},"instance":{"id":"inst-1","name":"Mac"}}"#
				)
			default: return (200, #"{"ok":true}"#)
			}
		}
		_ = try await cb.activate(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		let released = await cb.release()
		XCTAssertTrue(released)
		XCTAssertNil(cb.instanceId)
		XCTAssertNil(cb.licenseKey)
	}

	func testReleaseSaysSoRatherThanThrowingWhenThereIsNothingToFree() async {
		let released = await client { _, _ in (200, #"{"ok":true}"#) }.release()
		XCTAssertFalse(released)
	}

	func testReleaseKeepsTheSeatWhenTheServerCouldNotBeReached() async throws {
		// Reporting a freed seat that was never freed makes the app stop retrying, and the seat
		// stays taken until the lease lapses — or forever, on a node-locked product.
		let cb = client { path, _ in
			path == "/v1/activate"
				? (
					200,
					#"{"ok":true,"license":{"key":"K","status":"active","kind":"perpetual","product":"clementine","expires_at":null},"instance":{"id":"inst-1","name":"Mac"}}"#
				)
				: (-1, "")
		}
		_ = try await cb.activate(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		let released = await cb.release()
		XCTAssertFalse(released)
		XCTAssertEqual(cb.instanceId, "inst-1")
	}
}

/// The SDK holds a floating seat itself, like the TypeScript one (Codex on #77).
final class SeatUpkeepTests: XCTestCase {
	private let lease = "2030-01-01T00:00:00Z"

	/// A transport that counts what it was asked for and answers like the real server.
	private final class CountingTransport: CoolBeansTransport, @unchecked Sendable {
		private let lock = NSLock()
		private var counts: [String: Int] = [:]
		let leaseExpiresAt: String?

		init(leaseExpiresAt: String?) { self.leaseExpiresAt = leaseExpiresAt }

		func count(_ path: String) -> Int {
			lock.lock()
			defer { lock.unlock() }
			return counts[path] ?? 0
		}

		func post(url: URL, body: Data) async throws -> (status: Int, body: String) {
			lock.lock()
			counts[url.path, default: 0] += 1
			lock.unlock()
			let license =
				#"{"key":"K","status":"active","kind":"perpetual","product":"clementine","expires_at":null}"#
			switch url.path {
			case "/v1/activate":
				return (200, #"{"ok":true,"license":\#(license),"instance":{"id":"inst-1","name":"Mac"}}"#)
			case "/v1/validate":
				return (200, #"{"ok":true,"valid":true,"license":\#(license)}"#)
			case "/v1/heartbeat":
				let lease = leaseExpiresAt.map { "\"\($0)\"" } ?? "null"
				return (200, #"{"ok":true,"lease_expires_at":\#(lease)}"#)
			default:
				return (200, #"{"ok":true}"#)
			}
		}

		func get(url: URL) async throws -> (status: Int, body: String) {
			lock.lock()
			counts[url.path, default: 0] += 1
			lock.unlock()
			return (200, #"{"ok":true,"keys":{}}"#)
		}
	}

	private func client(_ transport: CountingTransport) -> CoolBeans {
		CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: InMemoryStorage(),
			transport: transport)
	}

	func testOpenHoldsAFloatingSeatWithoutTheAppAskingForIt() async throws {
		// The app is told nothing about lease windows and schedules nothing. Making an app pick a
		// heartbeat interval is making it decide whether its own users lose their seat.
		let transport = CountingTransport(leaseExpiresAt: lease)
		let cb = client(transport)
		await cb.open(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		defer { cb.stop() }
		XCTAssertEqual(transport.count("/v1/heartbeat"), 1)
	}

	func testANodeLockedProductIsProbedOnceAndNeverAgain() async throws {
		// A null lease is the server saying there is nothing to renew.
		let transport = CountingTransport(leaseExpiresAt: nil)
		let cb = client(transport)
		await cb.open(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		defer { cb.stop() }
		XCTAssertEqual(transport.count("/v1/heartbeat"), 1)
		XCTAssertNil(cb.leaseCadence, "a node-locked product must schedule nothing")
	}

	func testStopEndsTheUpkeep() async throws {
		let transport = CountingTransport(leaseExpiresAt: lease)
		let cb = client(transport)
		await cb.open(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		XCTAssertTrue(cb.isRunning)
		cb.stop()
		XCTAssertFalse(cb.isRunning, "stop() must leave nothing scheduled")
		XCTAssertEqual(cb.upkeep.startedLoops, 0)
		cb.stop()  // idempotent
		XCTAssertFalse(cb.isRunning)
	}

	func testOpeningTwiceDoesNotLeaveTwoLoopsRunning() async throws {
		let transport = CountingTransport(leaseExpiresAt: lease)
		let cb = client(transport)
		await cb.open(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		await cb.open(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
		defer { cb.stop() }
		// Two beats because two opens each probe, which is right. What must not happen is two
		// loops: a leaked pair sits in Task.sleep for hours and then beats forever, which no
		// assertion on request counts would ever catch — hence counting the loops themselves.
		XCTAssertEqual(transport.count("/v1/heartbeat"), 2)
		XCTAssertEqual(cb.upkeep.startedLoops, 2, "one refresh loop and one beat loop, not two pairs")
	}
}

/// Telling "there is nothing to renew" apart from "we could not ask" (careful review).
final class LeaseKnowledgeTests: XCTestCase {
	private func client(_ handler: @escaping @Sendable (String, String) -> (Int, String)) -> CoolBeans
	{
		CoolBeans(
			configuration: .init(product: "clementine", baseURL: URL(string: "https://x.test")!),
			storage: InMemoryStorage(),
			transport: StubTransport(handler: handler))
	}

	private static let license =
		#"{"key":"K","status":"active","kind":"perpetual","product":"clementine","expires_at":null}"#

	private func activated(_ cb: CoolBeans) async throws {
		_ = try await cb.activate(licenseKey: "CLEM-A2B3-C4D5-E6F7-G8H9")
	}

	func testANullLeaseIsDefinitiveAndEndsTheBeats() async throws {
		let cb = client { path, _ in
			path == "/v1/activate"
				? (200, #"{"ok":true,"license":\#(Self.license),"instance":{"id":"i","name":"Mac"}}"#)
				: (200, #"{"ok":true,"lease_expires_at":null}"#)
		}
		try await activated(cb)
		await cb.holdSeat()
		XCTAssertNil(cb.leaseCadence)
		XCTAssertTrue(cb.upkeep.leaseKnown, "a null lease is the server saying there is nothing to renew")
	}

	func testAFailedBeatIsNotAnAnswerAboutLeases() async throws {
		// `try?` used to collapse a thrown request into the same nil the server sends for a
		// node-locked product, so one dropped beat stopped the loop for good and a floating seat
		// lapsed while the app was still running.
		let cb = client { path, _ in
			path == "/v1/activate"
				? (200, #"{"ok":true,"license":\#(Self.license),"instance":{"id":"i","name":"Mac"}}"#)
				: (-1, "")
		}
		try await activated(cb)
		await cb.holdSeat()
		XCTAssertNil(cb.leaseCadence)
		XCTAssertFalse(cb.upkeep.leaseKnown, "a failed beat must leave us still asking")
	}

	func testTakingAFreshSeatReopensTheLeaseQuestion() async throws {
		// A seat freed from the console answers null. The refresh then re-activates, and the new
		// seat has to be held too — otherwise it lapses, gets re-activated, and churns forever.
		let cb = client { path, _ in
			path == "/v1/activate"
				? (200, #"{"ok":true,"license":\#(Self.license),"instance":{"id":"i","name":"Mac"}}"#)
				: (200, #"{"ok":true,"lease_expires_at":null}"#)
		}
		try await activated(cb)
		await cb.holdSeat()
		XCTAssertTrue(cb.upkeep.leaseKnown)
		try await activated(cb)
		XCTAssertFalse(cb.upkeep.leaseKnown, "a new seat is a new lease question")
	}

	func testALiveLeaseSetsACadenceOfAboutAThirdOfTheWindow() async throws {
		let expiry = ISO8601DateFormatter().string(from: Date().addingTimeInterval(1800))
		let cb = client { path, _ in
			path == "/v1/activate"
				? (200, #"{"ok":true,"license":\#(Self.license),"instance":{"id":"i","name":"Mac"}}"#)
				: (200, #"{"ok":true,"lease_expires_at":"\#(expiry)"}"#)
		}
		try await activated(cb)
		await cb.holdSeat()
		let cadence = try XCTUnwrap(cb.leaseCadence)
		XCTAssertEqual(cadence, 600, accuracy: 30)
		XCTAssertTrue(cb.upkeep.leaseKnown)
	}
}

/// Reading a capability the same way both SDKs do (careful review).
final class EntitlementValueTests: XCTestCase {
	private func state(_ entitlements: [String: EntitlementValue]) -> AccessState {
		AccessState(
			decision: .allow, reason: .cached, license: nil, expiresAt: nil,
			entitlements: entitlements)
	}

	func testABooleanFlagReadsAsItself() {
		XCTAssertTrue(state(["a": .bool(true)]).isEntitled("a"))
		XCTAssertFalse(state(["a": .bool(false)]).isEntitled("a"))
	}

	func testAnAbsentNameIsOff() {
		XCTAssertFalse(state([:]).isEntitled("a"))
		XCTAssertFalse(
			AccessState(decision: .allow, reason: .cached, license: nil, expiresAt: nil, entitlements: nil)
				.isEntitled("a"))
	}

	func testANumberOrStringFlagReadsTheWayJavaScriptReadsIt() {
		// The TypeScript SDK's documented gate is `state.entitlements?.export_4k`, which is plain
		// truthiness. A vendor who types `export_4k=1` must not get the feature on one platform and
		// not the other — that is a support ticket nobody can reproduce.
		XCTAssertTrue(state(["a": .number(1)]).isEntitled("a"))
		XCTAssertFalse(state(["a": .number(0)]).isEntitled("a"))
		XCTAssertTrue(state(["a": .string("yes")]).isEntitled("a"))
		XCTAssertFalse(state(["a": .string("")]).isEntitled("a"))
	}

	func testALimitReadsANumericStringToo() {
		// Same reason: `Number(entitlements?.batch_limit ?? 1)` in TypeScript accepts "100".
		XCTAssertEqual(state(["n": .number(100)]).limit("n"), 100)
		XCTAssertEqual(state(["n": .string("100")]).limit("n"), 100)
		XCTAssertNil(state(["n": .string("lots")]).limit("n"))
		XCTAssertNil(state([:]).limit("n"))
	}
}
