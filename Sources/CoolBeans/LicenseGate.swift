// ABOUTME: Observable licence state for an app's UI — what to unlock and what to say.
// ABOUTME: Deliberately free of SwiftUI, so the gating behaviour is testable off a Mac.

import Foundation

#if canImport(Combine)
import Combine
#endif

/// What the app should tell the user, if anything.
public enum LicenseStatus: Equatable, Sendable {
	/// Verified and current. Say nothing.
	case active
	/// Past the token TTL but the licence is fine. **Still unlocked.** Not a problem to
	/// report — it happens to anyone offline for a while, and shouting about it trains
	/// people to ignore real warnings.
	case grace
	/// Explicitly revoked by the server. The one state that takes access away.
	case revoked
	/// Nothing valid stored. Ask for a key.
	case locked

	/// Whether this deserves an error presentation. `grace` deliberately does not.
	public var isError: Bool { self == .revoked }
}

/// Drives a licence-gated UI. Hold one per app, call `refresh()` on launch, and read
/// `isUnlocked`.
///
/// The split matters: everything here is plain Swift and covered by tests, so the only
/// thing left in the SwiftUI layer is presentation. Logic that lives in a view is logic
/// nobody can test.
///
/// Combine is not available on Linux, so `ObservableObject` is conditional and the
/// portable `onChange` hook carries the same signal. That is what keeps the whole of this
/// file under test on Linux CI rather than only on a Mac.
@MainActor
public final class LicenseGate {
	public private(set) var status: LicenseStatus = .locked {
		didSet { if status != oldValue { notifyChange() } }
	}
	public private(set) var lastError: CoolBeansError? {
		didSet { notifyChange() }
	}

	/// Called whenever the state changes. SwiftUI users can ignore this and observe the
	/// object directly.
	public var onChange: (() -> Void)?

	private let client: CoolBeans

	public init(client: CoolBeans) {
		self.client = client
	}

	private func notifyChange() {
		onChange?()
		#if canImport(Combine)
		objectWillChange.send()
		#endif
	}

	public var isUnlocked: Bool { status == .active || status == .grace }

	/// This machine's fingerprint, for the air-gapped activation flow. Show it somewhere a
	/// user can copy it — an operator needs it to mint an offline activation.
	public var deviceFingerprint: String { client.fingerprint() }

	/// Instant, network-free check for gating the UI at launch.
	public func unlockedOffline() async -> Bool {
		await client.verifyOffline()
	}

	/// The last verdict `open()` returned, for an app that wants the reason or the entitlements
	/// rather than just a status.
	public private(set) var access: AccessState?

	/// Settle the current state, with the one call that owns the whole decision: it activates if
	/// it must, refreshes when it can, and falls back to the cached token when it cannot.
	///
	/// The gate deliberately holds no rules of its own. Two copies of "when do we lock the app"
	/// is two chances to lock out somebody who paid.
	public func refresh(licenseKey: String? = nil) async {
		// The UI should be right immediately rather than after a round trip, so read what we
		// already hold before going anywhere.
		let cached = await client.offlineState()
		status = Self.map(cached)

		let state = await client.open(licenseKey: licenseKey)
		access = state
		status = Self.map(state)
	}

	/// Activate this device, then settle. Surfaces the server's own sentence on failure.
	public func activate(licenseKey: String, name: String? = nil) async {
		lastError = nil
		do {
			_ = try await client.activate(licenseKey: licenseKey, name: name)
			await refresh(licenseKey: licenseKey)
		} catch let error as CoolBeansError {
			lastError = error
			status = .locked
		} catch {
			lastError = CoolBeansError(
				status: 0, code: "unknown", message: "Something went wrong activating this licence.")
			status = .locked
		}
	}

	/// Free this device's seat and lock the app.
	public func deactivate(licenseKey: String? = nil) async {
		let key = licenseKey ?? client.licenseKey
		if let key, let instanceId = client.instanceId {
			try? await client.deactivate(licenseKey: key, instanceId: instanceId)
		}
		status = .locked
	}

	private static func map(_ state: AccessState) -> LicenseStatus {
		switch (state.decision, state.reason) {
		case (.allow, .grace): return .grace
		case (.allow, _): return .active
		case (.deny, .revoked): return .revoked
		case (.deny, _): return .locked
		}
	}

	private static func map(_ state: OfflineState) -> LicenseStatus {
		switch state {
		case .valid: return .active
		case .grace: return .grace
		case .expired: return .locked
		}
	}
}

#if canImport(Combine)
extension LicenseGate: ObservableObject {}
#endif
