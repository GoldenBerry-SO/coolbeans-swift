// ABOUTME: A runnable end-to-end example — activate, verify, offline state, deactivate.
// ABOUTME: Deliberately headless so it builds and runs anywhere, including CI.

import CoolBeans
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Point at a locally running Cool Beans: COOLBEANS_URL, COOLBEANS_PRODUCT, COOLBEANS_KEY.
let base = ProcessInfo.processInfo.environment["COOLBEANS_URL"] ?? "http://localhost:3000"
let product = ProcessInfo.processInfo.environment["COOLBEANS_PRODUCT"] ?? "clementine"
let licenseKey = ProcessInfo.processInfo.environment["COOLBEANS_KEY"] ?? ""

guard !licenseKey.isEmpty else {
	print("Set COOLBEANS_KEY to a licence key. See the README.")
	exit(1)
}

// In a real app the public keys are embedded at build time. Fetching them here keeps the
// example to one command; it is NOT what you should ship.
func fetchKeys() async -> [String: String] {
	guard let url = URL(string: "\(base)/v1/pubkey?product=\(product)"),
		let (data, _) = try? await URLSession.shared.data(from: url),
		let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		let keys = body["keys"] as? [String: String]
	else { return [:] }
	return keys
}

let keys = await fetchKeys()
// A file-backed store stands in for the Keychain, which needs an Apple platform.
let storage = InMemoryStorage()
let cb = CoolBeans(
	configuration: .init(product: product, baseURL: URL(string: base)!, publicKeys: keys),
	storage: storage)

print("fingerprint : \(cb.fingerprint())")

do {
	let activated = try await cb.activate(licenseKey: licenseKey, name: "example-cli")
	print("activated   : \(activated.instance.id) (\(activated.license.kind))")

	let verified = try await cb.verify(licenseKey: licenseKey, instanceId: activated.instance.id)
	print("verified    : valid=\(verified.valid) inconclusive=\(verified.inconclusive)")

	let state = await cb.offlineState()
	print("offline     : \(state.rawValue)")

	try await cb.deactivate(licenseKey: licenseKey, instanceId: activated.instance.id)
	print("deactivated : seat freed")
} catch let error as CoolBeansError {
	// Branch on the code, never on the prose.
	print("failed      : [\(error.code)] \(error.message)")
	exit(1)
}
