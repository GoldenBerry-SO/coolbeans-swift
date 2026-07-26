// ABOUTME: open() — the one call an app makes on launch, and the verdict it cannot misread.
// ABOUTME: Ported from @coolbeans/sdk decision for decision; the shared contract fixtures pin both.

import Foundation

extension CoolBeans {
	/// The one call to make on launch. Activates if this device has never been activated,
	/// refreshes when it can reach us, falls back to the cached signed token when it cannot, and
	/// returns a single verdict:
	///
	/// ```swift
	/// let state = await cb.open(licenseKey: key)
	/// if state.decision == .deny { lockOut(state) }
	/// ```
	///
	/// It exists because the alternative — hold the instance id, choose `verify` or
	/// `verifyOffline`, and read `inconclusive` correctly — is three chances to lock out a paying
	/// customer. Everything inconclusive (offline, 5xx, timeout, an unknown key) keeps the last
	/// known-good state. Only a fetched `disabled` or a signed expiry denies.
	///
	/// The licence key is optional after the first run: activation persists it.
	@discardableResult
	public func open(licenseKey: String? = nil) async -> AccessState {
		// Before anything reads the clock: record how late it has ever been on this install.
		advanceTrustedTime(to: now())
		let key = licenseKey ?? self.licenseKey
		if let key, let online = await openOnline(key) { return online }
		return await offlineVerdict().state
	}

	/// A floating product needs its seat held while the app runs. Returns the new lease expiry, or
	/// nil when there was nothing to renew — a node-locked product, or a seat we could not hold.
	///
	/// Kept explicit rather than scheduled for you: this SDK has no run loop of its own, and an
	/// app that owns its timers should own this one too. Beat at about a third of the window the
	/// server hands back, so one dropped request does not cost the user their seat.
	@discardableResult
	public func holdSeat() async -> String? {
		guard let key = licenseKey, let instanceId else { return nil }
		return try? await heartbeat(licenseKey: key, instanceId: instanceId)
	}

	/// Free this device's seat and forget the licence locally. Call it on sign-out.
	///
	/// Needs nothing handed to it: activation stored the key and the instance id. Returns false
	/// when there was nothing to release, or when we could not reach the server — telling a
	/// caller the seat is free when it is not makes them stop retrying, and the seat stays taken
	/// until the lease lapses, or forever on a node-locked product.
	@discardableResult
	public func release() async -> Bool {
		guard let key = licenseKey, let instanceId else { return false }
		do {
			try await deactivate(licenseKey: key, instanceId: instanceId)
		} catch {
			return false
		}
		// deactivate clears the credential; a stale revocation marker would otherwise make the
		// next launch say "revoked" about a licence nobody is holding.
		storage.remove(StorageKey.revoked)
		return true
	}

	/// The online half of `open()`. Nil for every inconclusive answer, which is the caller's cue to
	/// fall back to the cached token rather than deny anything.
	private func openOnline(_ licenseKey: String) async -> AccessState? {
		// Spelled out rather than `??`, whose right side is an autoclosure and cannot await.
		var seat = self.instanceId
		if seat == nil { seat = await claimSeat(licenseKey) }
		guard let instanceId = seat else { return nil }
		var result = try? await verify(licenseKey: licenseKey, instanceId: instanceId)
		if let current = result, !current.inconclusive, !current.valid,
			current.license?.status == "active"
		{
			result = await reclaimSeat(licenseKey, previous: instanceId) ?? current
		}
		guard let result, !result.inconclusive, let license = result.license else { return nil }

		if license.status == "disabled" {
			// verify() already dropped the token. Remember that we were told, so a later launch
			// with no network says "revoked" rather than "never activated".
			storage.set(StorageKey.revoked, "1")
			return AccessState(
				decision: .deny, reason: .revoked, license: license, expiresAt: nil, entitlements: nil)
		}
		if result.valid {
			// A server that answers is authoritative on both counts: the licence stands, and the
			// local clock has no penalty left to serve.
			storage.remove(StorageKey.revoked)
			resetTrustedTime(to: now())
			// Entitlements ride in the token, not the frozen licence object.
			let claims = cachedTokenClaims()
			return AccessState(
				decision: .allow,
				reason: .online,
				license: license,
				expiresAt: license.expiresAt,
				entitlements: claims?.entitlements)
		}
		// Conclusive, active, still not valid. A past expiry is definitive; anything else (no free
		// seat, for instance) is not ours to turn into a lockout.
		if let raw = license.expiresAt, let expiry = Self.parseDate(raw), expiry <= effectiveNow() {
			return AccessState(
				decision: .deny, reason: .expired, license: license, expiresAt: raw, entitlements: nil)
		}
		return nil
	}

	/// Activate and return the instance id, or nil if we could not. Every failure here is
	/// inconclusive by contract — an unknown key is a 404, a full product is a 4xx, and neither
	/// revokes anything — so the error is swallowed. An app that needs the reason (a key-entry
	/// screen, say) calls `activate` directly and reads the CoolBeansError.
	private func claimSeat(_ licenseKey: String) async -> String? {
		try? await activate(licenseKey: licenseKey).instance.id
	}

	/// A live licence that does not recognise this device: the seat was freed from the console, or
	/// storage was restored onto a machine we have no record of. Take a seat again rather than lock
	/// out someone who is paying.
	private func reclaimSeat(_ licenseKey: String, previous: String) async -> VerifyResult? {
		guard let fresh = await claimSeat(licenseKey), fresh != previous else { return nil }
		guard let result = try? await verify(licenseKey: licenseKey, instanceId: fresh) else {
			storage.set(StorageKey.instance, previous)
			return nil
		}
		if result.inconclusive {
			// The new seat is claimed but unproven, and the cached token still names the old
			// instance. Leaving the new id stored would make that token look like another
			// device's, which the offline path reads as "never activated" — a lockout on an
			// inconclusive answer, which is the one thing we must never do.
			storage.set(StorageKey.instance, previous)
			return nil
		}
		return result
	}

	/// The verdict from local state alone, plus whether the token is still inside its own lifetime
	/// — which `offlineState()` needs and the verdict deliberately folds into a reason.
	func offlineVerdict() async -> (state: AccessState, withinTtl: Bool) {
		let wasRevoked = storage.get(StorageKey.revoked) == "1"
		func nothingKnown() -> (AccessState, Bool) {
			(
				AccessState(
					decision: .deny,
					reason: wasRevoked ? .revoked : .uninitialized,
					license: nil,
					expiresAt: nil,
					entitlements: nil),
				false
			)
		}

		guard let token = storage.get(StorageKey.token), !token.isEmpty else { return nothingKnown() }
		// Only signature-verified tokens count, and an unverifiable one is not evidence of a
		// revocation either — it is a token we know nothing about.
		let keys = trustedKeys()
		guard !keys.isEmpty, let payload = TokenVerifier.verify(token, keys: keys) else {
			return nothingKnown()
		}
		guard payload.product == configuration.product else { return nothingKnown() }
		if let bound = storage.get(StorageKey.instance), payload.instanceId != bound {
			return nothingKnown()
		}

		let license = LicenseObject(payload: payload)
		if payload.status == "disabled" {
			return (
				AccessState(
					decision: .deny,
					reason: .revoked,
					license: license,
					expiresAt: payload.expiresAt,
					entitlements: payload.entitlements),
				false
			)
		}

		let now = effectiveNow()
		// A signed expiry that has passed is our own credential saying the licence ended, so
		// honouring it is not inferring revocation from a network failure.
		if let raw = payload.expiresAt, let expiry = Self.parseDate(raw), expiry <= now {
			return (
				AccessState(
					decision: .deny,
					reason: .expired,
					license: license,
					expiresAt: raw,
					entitlements: payload.entitlements),
				false
			)
		}
		let withinTtl = Date(timeIntervalSince1970: TimeInterval(payload.exp)) > now
		// Trials get no grace: an unbounded one turns a blocked endpoint into a free licence.
		if payload.kind == "trial", !withinTtl {
			return (
				AccessState(
					decision: .deny,
					reason: .expired,
					license: license,
					expiresAt: payload.expiresAt,
					entitlements: payload.entitlements),
				false
			)
		}
		let rolledBack = now > self.now()
		return (
			AccessState(
				decision: .allow,
				reason: rolledBack ? .clockRollback : (withinTtl ? .cached : .grace),
				license: license,
				expiresAt: payload.expiresAt,
				entitlements: payload.entitlements),
			withinTtl
		)
	}

	/// The cached token's claims, decoded only if the signature verifies.
	private func cachedTokenClaims() -> TokenPayload? {
		guard let token = storage.get(StorageKey.token), !token.isEmpty else { return nil }
		return TokenVerifier.verify(token, keys: trustedKeys())
	}
}

extension LicenseObject {
	/// The §9 licence object is exactly the display half of a token payload.
	init(payload: TokenPayload) {
		self.init(
			key: payload.key,
			status: payload.status,
			kind: payload.kind,
			plan: payload.plan,
			product: payload.product,
			expiresAt: payload.expiresAt)
	}
}
