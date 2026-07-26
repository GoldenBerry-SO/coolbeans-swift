// ABOUTME: The single verdict open() returns — the same vocabulary @coolbeans/sdk uses, by name.
// ABOUTME: Branch on `decision`; `license` is for display and `entitlements` is for gating features.

import Foundation

public enum AccessDecision: String, Sendable, Equatable {
	case allow
	case deny
}

/// Why access stands or does not. The raw values are the wire names the TypeScript SDK uses, so
/// the two cannot drift into different vocabularies for the same state.
public enum AccessReason: String, Sendable, Equatable, CaseIterable {
	/// The server just confirmed it.
	case online
	/// No fresh answer, but the cached token is still within its lifetime.
	case cached
	/// Past the token's lifetime and still inside the licence. Nudge them online.
	case grace
	/// The machine's clock went backwards. Access stands, judged against the trusted mark.
	case clockRollback = "clock_rollback"
	/// A fetched answer said `disabled`. The only revocation signal there is.
	case revoked
	/// A signed expiry has passed, which is our own credential saying the licence ended.
	case expired
	/// No entitlement has ever been established on this device. Ask for a key.
	case uninitialized
}

/// A capability value a vendor priced. Flat by design: booleans, numbers and strings, nothing nested.
public enum EntitlementValue: Sendable, Equatable, Codable {
	case bool(Bool)
	case number(Double)
	case string(String)

	public init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		// Bool first: a JSON true decoded as a number would silently become 1.
		if let value = try? container.decode(Bool.self) {
			self = .bool(value)
		} else if let value = try? container.decode(Double.self) {
			self = .number(value)
		} else {
			self = .string(try container.decode(String.self))
		}
	}

	public func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .bool(let value): try container.encode(value)
		case .number(let value): try container.encode(value)
		case .string(let value): try container.encode(value)
		}
	}

	public var boolValue: Bool? {
		if case .bool(let value) = self { return value }
		return nil
	}

	public var intValue: Int? {
		if case .number(let value) = self { return Int(value) }
		return nil
	}

	public var doubleValue: Double? {
		if case .number(let value) = self { return value }
		return nil
	}

	public var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}
}

/// What `open()` concluded.
///
/// A decision plus a reason rather than a boolean, because "we have never established an
/// entitlement" must not share a name with "you were revoked": one screen asks for a licence key,
/// the other says the licence is gone.
public struct AccessState: Sendable, Equatable {
	public let decision: AccessDecision
	public let reason: AccessReason
	/// The frozen §9 licence object, for display. Never gate a feature on `plan` or `kind`.
	public let license: LicenseObject?
	/// The licence's own end date, nil for perpetual.
	public let expiresAt: String?
	/// What this licence buys, when the vendor priced capabilities. Signed, so it is safe to gate
	/// on. Nil — not empty — when the licence has none.
	public let entitlements: [String: EntitlementValue]?

	public var isUnlocked: Bool { decision == .allow }

	/// Whether a capability is switched on. False for a licence with no capability map, which is
	/// what makes this safe to call unconditionally.
	public func isEntitled(_ name: String) -> Bool {
		entitlements?[name]?.boolValue == true
	}

	/// A numeric capability, e.g. a batch limit. Nil when the vendor priced no such thing.
	public func limit(_ name: String) -> Int? {
		entitlements?[name]?.intValue
	}
}
