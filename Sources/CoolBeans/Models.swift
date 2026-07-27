// ABOUTME: The wire shapes and result types of the frozen §9 contract.
// ABOUTME: Mirrors @coolbeans/sdk deliberately, so the two SDKs read as one design.

import Foundation

public struct LicenseObject: Codable, Sendable, Equatable {
	public let key: String
	public let status: String
	/// Entitlement lifecycle (perpetual | subscription | trial), not pricing. Do not branch on it.
	public let kind: String
	/// The vendor's free-form plan label (display only), or nil.
	public let plan: String?
	public let product: String
	public let expiresAt: String?

	enum CodingKeys: String, CodingKey {
		case key, status, kind, plan, product
		case expiresAt = "expires_at"
	}
}

public struct InstanceObject: Codable, Sendable, Equatable {
	public let id: String
	public let name: String
}

public struct ActivateResult: Sendable, Equatable {
	public let license: LicenseObject
	public let instance: InstanceObject
}

/// What a local, network-free check concluded.
public enum OfflineState: String, Sendable {
	/// Cached token verified and inside its TTL.
	case valid
	/// Past the TTL but the licence has not expired — still unlock (§8).
	case grace
	/// No token, unverifiable, wrong device or product, disabled, or the licence ended.
	case expired
}

public struct VerifyResult: Sendable {
	public let valid: Bool
	public let license: LicenseObject?
	public let token: String?
	/// The server could not be reached at all.
	public let offline: Bool
	/// The answer was not definitive. Per §8 this must never lock anyone out — fall back
	/// to the cached token. Only `status == "disabled"` with `inconclusive == false` revokes.
	public let inconclusive: Bool
}
