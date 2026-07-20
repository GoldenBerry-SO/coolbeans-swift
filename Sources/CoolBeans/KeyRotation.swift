// ABOUTME: Keyset refresh so a server-side rotation does not need an app update (issue #6).
// ABOUTME: Embedded keys are the trust anchor and can never be displaced by a fetched set.

import Foundation

extension CoolBeans {
	/// Fetch the product's current keyset and persist it beside the embedded ones.
	///
	/// A failed, empty or unreadable response changes nothing: this is a refresh, not a
	/// dependency, and an app that cannot reach the endpoint must carry on verifying with
	/// the keys it already trusts. Called only from online verification — `offlineState()`
	/// stays network-free.
	func refreshKeys() async {
		guard
			let (status, raw) = try? await transport.get(
				url: url("/v1/pubkey?product=\(configuration.product)")),
			status == 200,
			let data = raw.data(using: .utf8)
		else { return }

		struct Payload: Decodable {
			let ok: Bool
			let keys: [String: String]
		}
		guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
			payload.ok,
			!payload.keys.isEmpty,
			let encoded = try? JSONEncoder().encode(payload.keys)
		else { return }
		storage.set(StorageKey.keys, String(decoding: encoded, as: UTF8.self))
	}
}
