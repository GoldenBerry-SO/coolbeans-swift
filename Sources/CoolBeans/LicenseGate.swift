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

	/// Settle the current state. Reads the cached token first so the UI is correct
	/// immediately, then confirms online when a key is available.
	public func refresh(licenseKey: String? = nil) async {
		let offline = await client.offlineState()
		status = Self.map(offline)

		guard let licenseKey, let instanceId = client.instanceId else { return }
		guard let result = try? await client.verify(licenseKey: licenseKey, instanceId: instanceId)
		else { return }

		if !result.inconclusive, result.license?.status == "disabled" {
			// The single definitive revocation. Everything else leaves the app as it was.
			status = .revoked
			return
		}
		// Re-read: verify may have refreshed the token, which can move grace back to active.
		status = Self.map(await client.offlineState())
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
	public func deactivate(licenseKey: String) async {
		if let instanceId = client.instanceId {
			try? await client.deactivate(licenseKey: licenseKey, instanceId: instanceId)
		}
		status = .locked
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
