// ABOUTME: One error type carrying the server's machine-readable code and its sentence.
// ABOUTME: Callers branch on `code`; `message` is written for a human and shown as-is.

import Foundation

public struct CoolBeansError: Error, LocalizedError, Equatable {
	/// HTTP status, or 0 for a check made locally with no request.
	public let status: Int
	/// The machine-readable code, e.g. `unknown_key`, so callers branch on it rather than
	/// pattern-matching prose that may be reworded.
	public let code: String
	public let message: String

	public init(status: Int, code: String, message: String) {
		self.status = status
		self.code = code
		self.message = message
	}

	public var errorDescription: String? { message }
}
