// ABOUTME: Where the device id, cached token and trusted keys live between launches.
// ABOUTME: Durability matters: losing the device id mints a new one and burns a seat.

import Foundation

public protocol CoolBeansStorage: AnyObject, Sendable {
	func get(_ key: String) -> String?
	func set(_ key: String, _ value: String)
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

	public func set(_ key: String, _ value: String) {
		lock.lock()
		defer { lock.unlock() }
		values[key] = value
	}

	public func remove(_ key: String) {
		lock.lock()
		defer { lock.unlock() }
		values.removeValue(forKey: key)
	}
}

enum StorageKey {
	static let device = "coolbeans.device_id"
	static let token = "coolbeans.token"
	static let instance = "coolbeans.instance_id"
	static let keys = "coolbeans.pubkeys"
	static let watermark = "coolbeans.trusted_time"
}
