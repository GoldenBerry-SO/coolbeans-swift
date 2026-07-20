// ABOUTME: The online decision table (PRD §8, §9) and the two seat endpoints.
// ABOUTME: Deliberately lopsided — everything ambiguous resolves in the user's favour.

import Foundation

extension CoolBeans {
	/// Verify online, refreshing the cached offline token.
	///
	/// Anything short of a definitive 200 for this product is inconclusive and never a
	/// lockout. Only `status == "disabled"` revokes, and it is the single path that clears
	/// the cached token so later offline checks stop unlocking.
	@discardableResult
	public func verify(licenseKey: String, instanceId: String) async throws -> VerifyResult {
		func inconclusive(offline: Bool) -> VerifyResult {
			VerifyResult(valid: false, license: nil, token: nil, offline: offline, inconclusive: true)
		}

		let body = try JSONSerialization.data(withJSONObject: [
			"license_key": licenseKey, "instance_id": instanceId,
		])
		let status: Int
		let raw: String
		do {
			(status, raw) = try await transport.post(url: url("/v1/validate"), body: body)
		} catch {
			// Could not reach the server at all. The cached token stands.
			return inconclusive(offline: true)
		}

		struct Payload: Decodable {
			let ok: Bool
			let license: LicenseObject?
			let token: String?
		}
		guard status == 200,
			let data = raw.data(using: .utf8),
			let payload = try? JSONDecoder().decode(Payload.self, from: data),
			payload.ok,
			let license = payload.license
		else {
			// 404/429/5xx and unreadable bodies are all inconclusive per the frozen contract.
			return inconclusive(offline: false)
		}
		guard license.product == configuration.product else {
			// An answer about a different product tells us nothing about this one.
			return inconclusive(offline: false)
		}

		if license.status == "disabled" {
			// The definitive revocation signal: drop the token so verifyOffline stops unlocking.
			storage.remove(StorageKey.token)
			return VerifyResult(
				valid: false, license: license, token: nil, offline: false, inconclusive: false)
		}

		if let token = payload.token {
			storage.set(StorageKey.token, token)
			await refreshKeys()
			// Advance the rollback watermark from the token we just accepted. Without this
			// the watermark is never set in a real app and the protection is inert.
			if let claims = TokenVerifier.verify(token, keys: trustedKeys()) {
				acceptTrustedTime(from: claims)
			}
		}
		return VerifyResult(
			valid: true, license: license, token: payload.token, offline: false, inconclusive: false)
	}

	/// Free this device's seat. Idempotent server-side.
	public func deactivate(licenseKey: String, instanceId: String) async throws {
		let body = try JSONSerialization.data(withJSONObject: [
			"license_key": licenseKey, "instance_id": instanceId,
		])
		let (status, raw) = try await transport.post(url: url("/v1/deactivate"), body: body)
		guard status == 200 else { throw Self.error(status: status, raw: raw) }
		// Believing we still hold a seat we have released is worse than forgetting one.
		storage.remove(StorageKey.instance)
		storage.remove(StorageKey.token)
		storage.remove(StorageKey.license)
	}

	/// Renew a floating lease. Returns the new expiry, or nil when nothing was renewed —
	/// an unknown instance, a lapsed lease with no free seat, or a node-locked product.
	/// The caller needs that difference to tell "seat held" from "re-activate first".
	public func heartbeat(licenseKey: String, instanceId: String) async throws -> String? {
		let body = try JSONSerialization.data(withJSONObject: [
			"license_key": licenseKey, "instance_id": instanceId,
		])
		let (status, raw) = try await transport.post(url: url("/v1/heartbeat"), body: body)
		guard status == 200 else { throw Self.error(status: status, raw: raw) }
		struct Payload: Decodable {
			let ok: Bool
			let leaseExpiresAt: String?
			enum CodingKeys: String, CodingKey {
				case ok
				case leaseExpiresAt = "lease_expires_at"
			}
		}
		guard let data = raw.data(using: .utf8),
			let payload = try? JSONDecoder().decode(Payload.self, from: data)
		else { return nil }
		return payload.leaseExpiresAt
	}
}
