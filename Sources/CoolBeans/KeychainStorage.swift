// ABOUTME: Keychain-backed storage for Apple platforms — the licence key is a credential.
// ABOUTME: Compiles only where Security exists; Linux CI uses InMemoryStorage instead.

#if canImport(Security)
import Foundation
import Security

/// Durable storage in the Keychain.
///
/// Durability is the point. The device id lives here, and losing it mints a new one, which
/// consumes another activation seat on the next launch — a user restoring a backup should
/// not quietly burn through their allowance.
///
/// `synchronizable` decides whether items travel to the user's other devices via iCloud.
/// Convenient ("it already works on my laptop"), but each device that activates takes its
/// own seat, so it is an explicit choice rather than a default to drift into.
public final class KeychainStorage: CoolBeansStorage, @unchecked Sendable {
	private let service: String
	private let synchronizable: Bool

	public init(service: String, synchronizable: Bool = false) {
		self.service = service
		self.synchronizable = synchronizable
	}

	private func query(_ key: String) -> [String: Any] {
		var q: [String: Any] = [
			kSecClass as String: kSecClassGenericPassword,
			kSecAttrService as String: service,
			kSecAttrAccount as String: key,
		]
		if synchronizable { q[kSecAttrSynchronizable as String] = kCFBooleanTrue }
		return q
	}

	public func get(_ key: String) -> String? {
		var q = query(key)
		q[kSecReturnData as String] = kCFBooleanTrue
		q[kSecMatchLimit as String] = kSecMatchLimitOne
		var item: CFTypeRef?
		guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
			let data = item as? Data
		else { return nil }
		return String(data: data, encoding: .utf8)
	}

	@discardableResult
	public func set(_ key: String, _ value: String) -> Bool {
		let data = Data(value.utf8)
		let q = query(key)
		// Update in place when present, so we never briefly delete a credential and leave
		// a window where a crash loses it.
		let updated = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
		if updated == errSecSuccess { return true }
		guard updated == errSecItemNotFound else { return false }

		var insert = q
		insert[kSecValueData as String] = data
		// Keychain refuses a ThisDeviceOnly accessibility class on a synchronizable item,
		// and SecItemAdd then fails for every write — so with iCloud sync on, nothing
		// would persist at all and activation state would vanish on relaunch.
		insert[kSecAttrAccessible as String] =
			synchronizable
			? kSecAttrAccessibleAfterFirstUnlock
			: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
		return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
	}

	public func remove(_ key: String) {
		SecItemDelete(query(key) as CFDictionary)
	}
}
#endif
