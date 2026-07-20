// ABOUTME: The client. Activate a device, verify online, and verify offline with no network.
// ABOUTME: Mirrors @coolbeans/sdk method for method, so the two SDKs cannot drift apart quietly.

import Foundation

public struct Configuration: Sendable {
	public let product: String
	public let baseURL: URL
	/// Ed25519 public keys keyed by kid, embedded in the app. Bundling them is what makes
	/// offline verification possible on a machine that has never been online.
	public let publicKeys: [String: String]
	/// Whether Keychain items may sync to the user's other devices. Convenient, but each
	/// device that activates takes its own seat — decide deliberately.
	public let syncsViaICloud: Bool

	public init(
		product: String,
		baseURL: URL = URL(string: "https://app.coolbeans.tools")!,
		publicKeys: [String: String] = [:],
		syncsViaICloud: Bool = false
	) {
		self.product = product
		self.baseURL = baseURL
		self.publicKeys = publicKeys
		self.syncsViaICloud = syncsViaICloud
	}
}

public final class CoolBeans: @unchecked Sendable {
	let configuration: Configuration
	let storage: CoolBeansStorage
	let transport: CoolBeansTransport
	private let clock: @Sendable () -> Date

	public init(
		configuration: Configuration,
		storage: CoolBeansStorage? = nil,
		transport: CoolBeansTransport = URLSessionTransport(),
		clock: @escaping @Sendable () -> Date = { Date() }
	) {
		self.configuration = configuration
		self.storage = storage ?? CoolBeans.defaultStorage(configuration: configuration)
		self.transport = transport
		self.clock = clock
	}

	/// A stable id for this machine, hardware-derived where the platform offers one.
	public func fingerprint() -> String {
		resolveDeviceIdentifier(storage: storage)
	}

	/// The instance id from the last successful activation on this device.
	public var instanceId: String? { storage.get(StorageKey.instance) }

	/// The licence key this device activated with.
	///
	/// Persisted because everything after activation needs it: the next launch has to
	/// verify, and without a stored key that call never reaches the server, so revocation
	/// and token refresh quietly stop for the life of the install.
	public var licenseKey: String? { storage.get(StorageKey.license) }

	/// Activate this device against a licence. Fails closed if the server answers for a
	/// different product than the one configured.
	public func activate(licenseKey: String, name: String? = nil) async throws -> ActivateResult {
		let body = try JSONSerialization.data(withJSONObject: [
			"license_key": licenseKey,
			"instance_name": name ?? fingerprint(),
		])
		let (status, raw) = try await transport.post(url: url("/v1/activate"), body: body)
		guard status == 200 else { throw Self.error(status: status, raw: raw) }

		struct Payload: Decodable {
			let ok: Bool
			let license: LicenseObject
			let instance: InstanceObject
		}
		guard let data = raw.data(using: .utf8),
			let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.ok
		else {
			throw CoolBeansError(
				status: status, code: "bad_response", message: "The server sent an unreadable answer.")
		}
		guard payload.license.product == configuration.product else {
			throw CoolBeansError(
				status: status,
				code: "product_mismatch",
				message: "That licence is for a different product.")
		}
		storage.set(StorageKey.instance, payload.instance.id)
		storage.set(StorageKey.license, licenseKey)
		return ActivateResult(license: payload.license, instance: payload.instance)
	}

	func url(_ path: String) -> URL {
		URL(string: configuration.baseURL.absoluteString.trimmingTrailingSlash() + path)!
	}

	func now() -> Date { clock() }

	/// Map an error body to the machine-readable code, keeping the server's own sentence.
	static func error(status: Int, raw: String) -> CoolBeansError {
		struct Body: Decodable {
			let error: String?
			let message: String?
		}
		let decoded = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(Body.self, from: $0) }
		return CoolBeansError(
			status: status,
			code: decoded?.error ?? "request_failed",
			message: decoded?.message ?? "Cool Beans request failed (\(status)).")
	}

	private static func defaultStorage(configuration: Configuration) -> CoolBeansStorage {
		#if canImport(Security)
		return KeychainStorage(
			service: "tools.coolbeans.\(configuration.product)",
			synchronizable: configuration.syncsViaICloud)
		#else
		return InMemoryStorage()
		#endif
	}
}

extension String {
	func trimmingTrailingSlash() -> String {
		hasSuffix("/") ? String(dropLast()) : self
	}
}
