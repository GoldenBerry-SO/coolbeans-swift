// ABOUTME: The HTTP seam, so tests drive the decision table without a network.
// ABOUTME: URLSession in production; a stub in tests. No third-party networking.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol CoolBeansTransport: Sendable {
	/// Returns the status and raw body. Throwing means the request never completed, which
	/// the decision table treats as offline rather than as an answer.
	func post(url: URL, body: Data) async throws -> (status: Int, body: String)
	func get(url: URL) async throws -> (status: Int, body: String)
}

public struct URLSessionTransport: CoolBeansTransport {
	private let session: URLSession

	public init(session: URLSession = .shared) {
		self.session = session
	}

	public func post(url: URL, body: Data) async throws -> (status: Int, body: String) {
		var request = URLRequest(url: url)
		request.httpMethod = "POST"
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.httpBody = body
		return try await send(request)
	}

	public func get(url: URL) async throws -> (status: Int, body: String) {
		return try await send(URLRequest(url: url))
	}

	private func send(_ request: URLRequest) async throws -> (status: Int, body: String) {
		let (data, response) = try await session.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		return (status, String(decoding: data, as: UTF8.self))
	}
}

/// Canned responses for tests. Handler receives the path and the request body.
public final class StubTransport: CoolBeansTransport, @unchecked Sendable {
	public private(set) var calls: [String] = []
	private let handler: @Sendable (String, String) -> (Int, String)
	private let lock = NSLock()

	public init(handler: @escaping @Sendable (String, String) -> (Int, String)) {
		self.handler = handler
	}

	public func post(url: URL, body: Data) async throws -> (status: Int, body: String) {
		record(url.path)
		let result = handler(url.path, String(decoding: body, as: UTF8.self))
		if result.0 == -1 { throw CoolBeansError(status: 0, code: "network", message: "down") }
		return (result.0, result.1)
	}

	public func get(url: URL) async throws -> (status: Int, body: String) {
		record(url.path)
		let result = handler(url.path, "")
		if result.0 == -1 { throw CoolBeansError(status: 0, code: "network", message: "down") }
		return (result.0, result.1)
	}

	public func count(_ path: String) -> Int {
		lock.lock()
		defer { lock.unlock() }
		return calls.filter { $0 == path }.count
	}

	private func record(_ path: String) {
		lock.lock()
		calls.append(path)
		lock.unlock()
	}
}
