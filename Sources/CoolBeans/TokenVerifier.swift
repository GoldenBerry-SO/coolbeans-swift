// ABOUTME: Ed25519 token verification with no network (PRD §11).
// ABOUTME: CryptoKit on Apple platforms; Apple's swift-crypto elsewhere, same API.

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

struct TokenPayload: Decodable {
	let key: String
	let status: String
	let kind: String
	let plan: String?
	let product: String
	let expiresAt: String?
	/// What this licence buys, when the vendor priced capabilities. Absent when it has none, so
	/// an app checking one is told the truth rather than handed an empty map.
	let entitlements: [String: EntitlementValue]?
	/// Present only on an offline activation: the machine it was minted for.
	let fingerprint: String?
	let instanceId: String
	let iat: Int
	let exp: Int

	enum CodingKeys: String, CodingKey {
		case key, status, kind, plan, product, iat, exp, entitlements
		case expiresAt = "expires_at"
		case fingerprint
		case instanceId = "instance_id"
	}
}

enum TokenVerifier {
	/// Verify a compact `header.payload.signature` token against a keyset, returning the
	/// claims only when the signature genuinely checks out. Every failure is nil — a
	/// caller must not be able to tell a malformed token from a forged one and act
	/// differently on it.
	static func verify(_ token: String, keys: [String: String]) -> TokenPayload? {
		let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
		guard parts.count == 3 else { return nil }
		guard
			let headerData = base64urlDecode(parts[0]),
			let header = try? JSONDecoder().decode(TokenHeader.self, from: headerData),
			let signature = base64urlDecode(parts[2]),
			let payloadData = base64urlDecode(parts[1])
		else { return nil }

		// Try the named key first, then every other trusted one. Rotation means a token
		// signed before the change must still verify against a key we already hold.
		let candidates = [keys[header.kid]].compactMap { $0 } + keys.values.filter { $0 != keys[header.kid] }
		let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
		let verified = candidates.contains { raw in
			guard
				let rawKey = base64urlDecode(raw),
				let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
			else { return false }
			return publicKey.isValidSignature(signature, for: signingInput)
		}
		guard verified else { return nil }
		return try? JSONDecoder().decode(TokenPayload.self, from: payloadData)
	}

	private struct TokenHeader: Decodable {
		let alg: String
		let kid: String
	}

	static func base64urlDecode(_ value: String) -> Data? {
		var s = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		while s.count % 4 != 0 { s += "=" }
		return Data(base64Encoded: s)
	}
}
