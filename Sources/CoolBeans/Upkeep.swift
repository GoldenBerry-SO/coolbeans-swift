// ABOUTME: The background work open() owns — re-checking on its own cadence and holding a floating
// ABOUTME: seat. An app that has to schedule this is an app deciding whether its users get locked out.

import Foundation

/// Two loops and the state they share, kept off `CoolBeans` so the client stays readable.
///
/// Deliberately not an actor: `stop()` has to be callable from anywhere, synchronously, including a
/// SwiftUI teardown, and awaiting an actor to cancel a task is worse than a lock held for a few
/// instructions.
final class Upkeep: @unchecked Sendable {
	private let lock = NSLock()
	private var refreshTask: Task<Void, Never>?
	private var beatTask: Task<Void, Never>?
	private var lastState: AccessState?
	private var cadence: TimeInterval?
	private var stopped = true

	/// Called when the verdict changes after `open()` returned. Not called for what `open()` itself
	/// returned, and not called again while the answer stays the same.
	var onChange: (@Sendable (AccessState) -> Void)?

	/// The seat cadence once the server has told us, nil for a node-locked product.
	var leaseCadence: TimeInterval? {
		get {
			lock.lock()
			defer { lock.unlock() }
			return cadence
		}
		set {
			lock.lock()
			cadence = newValue
			lock.unlock()
		}
	}

	/// Set once a heartbeat has answered, so a first-probe failure can be retried and a definitive
	/// "no leases here" is never asked about again.
	var leaseKnown = false

	/// Loops the current generation started: two on `start()`, zero after `stop()`.
	///
	/// Exists so a test can prove a second `open()` cancelled the first one's loops. A leaked loop
	/// sits in `Task.sleep` for hours before it misbehaves, which no assertion on request counts
	/// would ever catch. Counted synchronously and reset by `stop()`, because `Task {}` does not
	/// begin executing when you write it and a cancelled task decrements whenever it next wakes —
	/// so anything measured from inside the loop bodies is a race.
	private var started = 0
	var startedLoops: Int {
		lock.lock()
		defer { lock.unlock() }
		return started
	}

	var isRunning: Bool {
		lock.lock()
		defer { lock.unlock() }
		return !stopped
	}

	/// Record what `open()` returned, so the first background tick only reports a real change.
	func remember(_ state: AccessState) {
		lock.lock()
		lastState = state
		lock.unlock()
	}

	/// Report a verdict, but only if it actually moved.
	func publish(_ state: AccessState) {
		lock.lock()
		let before = lastState
		lastState = state
		let handler = onChange
		lock.unlock()
		guard before?.decision != state.decision || before?.reason != state.reason else { return }
		handler?(state)
	}

	/// Start both loops. Each sleeps first: `open()` has already done the immediate work.
	func start(
		refresh: @escaping @Sendable () async -> Void,
		refreshEvery: @escaping @Sendable () -> TimeInterval,
		beat: @escaping @Sendable () async -> String?,
		beatEvery: @escaping @Sendable () -> TimeInterval?
	) {
		lock.lock()
		stopped = false
		// Accumulates rather than assigns: only stop() clears it, so a start that skipped its stop
		// shows up as four where a restart shows two. Assigning would hide exactly the leak this
		// counter exists to catch.
		started += 2
		lock.unlock()

		refreshTask = Task { [weak self] in
			while self?.isRunning == true {
				// Jittered, so every install of an app does not wake on the same tick and stampede
				// one server. ±20%, the same spread the TypeScript SDK uses.
				let base = refreshEvery()
				let jitter = base * 0.2
				let delay = max(1, base - jitter + Double.random(in: 0...(jitter * 2)))
				guard await Upkeep.sleep(delay) else { return }
				guard self?.isRunning == true else { return }
				await refresh()
			}
		}

		beatTask = Task { [weak self] in
			while self?.isRunning == true {
				guard let next = beatEvery() else {
					// Nothing to renew. A node-locked product is done being asked; a first probe
					// that failed is retried on the next refresh, which re-enters holdSeat.
					return
				}
				guard await Upkeep.sleep(next) else { return }
				guard self?.isRunning == true else { return }
				_ = await beat()
			}
		}
	}

	/// Cancel everything. Idempotent, and safe to call without ever having started.
	func stop() {
		lock.lock()
		stopped = true
		started = 0
		let tasks = [refreshTask, beatTask]
		refreshTask = nil
		beatTask = nil
		lock.unlock()
		for task in tasks { task?.cancel() }
	}

	/// Sleep, reporting false if the task was cancelled while waiting.
	private static func sleep(_ seconds: TimeInterval) async -> Bool {
		do {
			try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
			return true
		} catch {
			return false
		}
	}
}
