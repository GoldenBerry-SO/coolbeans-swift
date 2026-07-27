// ABOUTME: The offline decision table (PRD §8, §11) — the rules that decide whether to unlock.
// ABOUTME: Ported line for line from @coolbeans/sdk; the edges carry real product decisions.

import Foundation

extension CoolBeans {
	/// Local, no-network check of the cached token. True to unlock (valid or grace).
	public func verifyOffline() async -> Bool {
		await offlineState() != .expired
	}

	/// Detailed offline state. Performs no network call, ever.
	///
	/// The three states are a projection of the same table `open()` reads, deliberately: two
	/// copies of the offline decision rules is two chances to lock somebody out.
	public func offlineState() async -> OfflineState {
		let (state, withinTtl) = await offlineVerdict()
		if state.decision == .deny { return .expired }
		return withinTtl ? .valid : .grace
	}

	/// Every key this app trusts: the ones embedded at build time, plus any persisted from
	/// a previous fetch. Embedded keys always win, so a fetched set can never displace the
	/// trust anchor that shipped inside a signed binary.
	func trustedKeys() -> [String: String] {
		var merged: [String: String] = [:]
		if let raw = storage.get(StorageKey.keys),
			let data = raw.data(using: .utf8),
			let stored = try? JSONDecoder().decode([String: String].self, from: data)
		{
			merged = stored
		}
		for (kid, key) in configuration.publicKeys { merged[kid] = key }
		return merged
	}

	static func parseDate(_ value: String) -> Date? {
		let withFraction = ISO8601DateFormatter()
		withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return withFraction.date(from: value) ?? ISO8601DateFormatter().date(from: value)
	}
}
