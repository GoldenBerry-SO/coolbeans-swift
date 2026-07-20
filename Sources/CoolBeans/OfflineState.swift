// ABOUTME: The offline decision table (PRD §8, §11) — the rules that decide whether to unlock.
// ABOUTME: Ported line for line from @coolbeans/sdk; the edges carry real product decisions.

import Foundation

extension CoolBeans {
	/// Local, no-network check of the cached token. True to unlock (valid or grace).
	public func verifyOffline() async -> Bool {
		await offlineState() != .expired
	}

	/// Detailed offline state. Performs no network call, ever.
	public func offlineState() async -> OfflineState {
		guard let token = storage.get(StorageKey.token) else { return .expired }

		// Fail closed with no trusted key. A caller who has never been online has nothing
		// to check a signature against, and unlocking there would make the token pointless.
		let keys = trustedKeys()
		guard !keys.isEmpty, let payload = TokenVerifier.verify(token, keys: keys) else {
			return .expired
		}

		// Claim binding: this token must be for this product and this device.
		guard payload.product == configuration.product else { return .expired }
		if let bound = storage.get(StorageKey.instance), payload.instanceId != bound {
			return .expired
		}
		guard payload.status != "disabled" else { return .expired }

		let now = effectiveNow()

		// A signed expiry that has passed is definitive, whatever the tier. The token we
		// were issued says this licence ended, so honouring it is reading our own
		// credential rather than inferring revocation from a network failure — §8 is
		// untouched, and it is what makes revocation reach a machine that has gone dark.
		// Lifetime licences carry no expires_at and are unaffected.
		if let raw = payload.expiresAt, let expiry = Self.parseDate(raw), expiry <= now {
			return .expired
		}

		let tokenExpiry = Date(timeIntervalSince1970: TimeInterval(payload.exp))
		if payload.tier == "trial" {
			// Trials get no TTL grace either, or a blocked endpoint becomes an unlimited trial.
			return tokenExpiry > now ? .valid : .expired
		}
		// Past the TTL on a licence that has not expired: grace, never a lockout.
		return tokenExpiry > now ? .valid : .grace
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
