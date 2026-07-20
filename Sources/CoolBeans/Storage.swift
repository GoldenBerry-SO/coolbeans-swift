// ABOUTME: Where the device id, cached token and trusted keys live between launches.
// ABOUTME: Durability matters: losing the device id mints a new one and burns a seat.

import Foundation

public protocol CoolBeansStorage: AnyObject, Sendable {
	func get(_ key: String) -> String?
	/// Reports whether the value was actually stored. The Keychain refuses writes for
	/// reasons the caller cannot predict, and an activation that cannot be persisted has
	/// to fail rather than look successful until the next launch.
	@discardableResult
	func set(_ key: String, _ value: String) -> Bool
	func remove(_ key: String)
}

/// Test and fallback storage. Deliberately not the default on Apple platforms, where a
/// process restart would otherwise consume another activation seat every time.
public final class InMemoryStorage: CoolBeansStorage, @unchecked Sendable {
	private var values: [String: String] = [:]
	private let lock = NSLock()

	public init() {}

	public func get(_ key: String) -> String? {
		lock.lock()
		defer { lock.unlock() }
		return values[key]
	}

	@discardableResult
	public func set(_ key: String, _ value: String) -> Bool {
		lock.lock()
		defer { lock.unlock() }
		values[key] = value
		return true
	}

	public func remove(_ key: String) {
		lock.lock()
		defer { lock.unlock() }
		values.removeValue(forKey: key)
	}
}

extension CoolBeansStorage {
	/// Write several values together, putting back what was there if any of them fails.
	///
	/// Half a credential is worse than none. `offlineState` locks the app when the cached
	/// token and the stored instance id disagree, so a write that left a new instance id
	/// beside an old token would take away access the machine already had — and on an
	/// air-gapped machine there is no way to get it back.
	///
	/// Best effort, not a transaction: the rollback writes can fail too, on a store that is
	/// already refusing them. It is still strictly better than leaving the mismatch, and the
	/// caller fails loudly either way.
	func setAll(_ pairs: [(key: String, value: String)]) -> Bool {
		var undo: [(key: String, previous: String?)] = []
		for pair in pairs {
			let previous = get(pair.key)
			guard set(pair.key, pair.value) else {
				for step in undo.reversed() {
					if let value = step.previous { set(step.key, value) } else { remove(step.key) }
				}
				return false
			}
			undo.append((pair.key, previous))
		}
		return true
	}
}

enum StorageKey {
	static let device = "coolbeans.device_id"
	static let token = "coolbeans.token"
	static let instance = "coolbeans.instance_id"
	static let keys = "coolbeans.pubkeys"
	static let license = "coolbeans.license_key"
	static let watermark = "coolbeans.trusted_time"
}
