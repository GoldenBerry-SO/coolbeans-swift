// ABOUTME: Signs tokens the way the server does, so tests exercise real Ed25519 verification.
// ABOUTME: A throwaway key per call; the public half is handed to the client as trusted.

import Foundation
@testable import CoolBeans

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

enum TestSigner {
	struct Claims {
		var key = "CLEM-A2B3-C4D5-E6F7-G8H9"
		var status = "active"
		var kind = "subscription"
		var plan: String?
		var product = "clementine"
		var instanceId = "inst-1"
		var expiresAt: Date?
		var exp: Date
		var fingerprint: String?
		var iat = Date(timeIntervalSince1970: 1_700_000_000)

		init(
			key: String = "CLEM-A2B3-C4D5-E6F7-G8H9",
			status: String = "active",
			kind: String = "subscription",
			plan: String? = nil,
			product: String = "clementine",
			instanceId: String = "inst-1",
			exp: Date,
			expiresAt: Date? = nil,
			fingerprint: String? = nil
		) {
			self.key = key
			self.status = status
			self.kind = kind
			self.plan = plan
			self.product = product
			self.instanceId = instanceId
			self.exp = exp
			self.expiresAt = expiresAt
			self.fingerprint = fingerprint
		}
	}

	static func sign(_ claims: Claims, kid: String = "1") throws -> (token: String, keys: [String: String]) {
		let priv = Curve25519.Signing.PrivateKey()
		let formatter = ISO8601DateFormatter()
		var payload: [String: Any] = [
			"key": claims.key,
			"status": claims.status,
			"kind": claims.kind,
			"plan": claims.plan ?? NSNull(),
			"product": claims.product,
			"instance_id": claims.instanceId,
			"iat": Int(claims.iat.timeIntervalSince1970),
			"exp": Int(claims.exp.timeIntervalSince1970),
		]
		payload["expires_at"] = claims.expiresAt.map { formatter.string(from: $0) } ?? NSNull()
		if let fingerprint = claims.fingerprint { payload["fingerprint"] = fingerprint }

		let header = try JSONSerialization.data(
			withJSONObject: ["alg": "EdDSA", "typ": "CBT", "kid": kid])
		let body = try JSONSerialization.data(withJSONObject: payload)
		let signingInput = "\(base64url(header)).\(base64url(body))"
		let signature = try priv.signature(for: Data(signingInput.utf8))
		let token = "\(signingInput).\(base64url(signature))"
		return (token, [kid: base64url(priv.publicKey.rawRepresentation)])
	}

	private static func base64url(_ data: Data) -> String {
		data.base64EncodedString()
			.replacingOccurrences(of: "+", with: "-")
			.replacingOccurrences(of: "/", with: "_")
			.replacingOccurrences(of: "=", with: "")
	}
}
