// ABOUTME: Import a vendor-issued activation for a machine that will never reach us.
// ABOUTME: Entirely local — no request is made here, and none ever will be.

import Foundation

extension CoolBeans {
	/// Accept an offline activation blob produced by the vendor from this device's
	/// fingerprint. Mirrors `importActivation` in @coolbeans/sdk.
	///
	/// Only trusted if the signature verifies against a key this app already carries: the
	/// blob is handed around as text, which makes tampering the obvious attack. It must
	/// also name this product and still be within its lifetime, since importing a dead
	/// activation would leave the app silently locked.
	public func importActivation(_ token: String) async throws {
		let keys = trustedKeys()
		guard !keys.isEmpty else {
			throw CoolBeansError(
				status: 0, code: "no_trusted_keys",
				message: "No public keys are available to verify this activation.")
		}
		guard let payload = TokenVerifier.verify(token, keys: keys) else {
			throw CoolBeansError(
				status: 0, code: "invalid_activation",
				message: "That activation could not be verified. Check it was pasted in full.")
		}
		guard payload.product == configuration.product else {
			throw CoolBeansError(
				status: 0, code: "product_mismatch",
				message: "That activation is for a different product.")
		}
		guard Date(timeIntervalSince1970: TimeInterval(payload.exp)) > effectiveNow() else {
			throw CoolBeansError(
				status: 0, code: "activation_expired",
				message: "That activation has expired. Ask for a fresh one.")
		}
		// The binding check, and the whole reason a blob can be handed around as text.
		// Comparing against the token's own instance_id would be circular — we are about
		// to store that value ourselves — so the signed fingerprint is the only claim that
		// says anything about *this* machine.
		guard let boundTo = payload.fingerprint else {
			throw CoolBeansError(
				status: 0, code: "unbound_activation",
				message: "That activation is not bound to a machine. Ask for one issued for this device.")
		}
		guard boundTo == fingerprint() else {
			throw CoolBeansError(
				status: 0, code: "wrong_device",
				message: "That activation was issued for a different machine.")
		}
		// Bind the device before storing the token, so the instance check in offlineState
		// has something to compare against rather than silently passing.
		guard storage.set(StorageKey.instance, payload.instanceId),
			storage.set(StorageKey.token, token)
		else {
			throw CoolBeansError(
				status: 0,
				code: "storage_failed",
				message: "That activation could not be saved on this device. Check Keychain access and try again.")
		}
		acceptTrustedTime(from: payload)
	}

	/// A token's `iat` is stamped by the server, so it is a moment we have reason to trust
	/// even on a machine whose own clock is wrong or has been moved.
	func acceptTrustedTime(from payload: TokenPayload) {
		advanceTrustedTime(to: Date(timeIntervalSince1970: TimeInterval(payload.iat)))
	}
}
