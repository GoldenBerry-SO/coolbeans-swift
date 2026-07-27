// ABOUTME: Monotonic trusted-time watermark (issue #5) — winding the clock back must not help.
// ABOUTME: Never a lockout: a clock behind the mark is distrusted, not punished.

import Foundation

extension CoolBeans {
	/// The highest timestamp we have ever had reason to trust.
	var trustedTime: Date? {
		guard let raw = storage.get(StorageKey.watermark), let seconds = TimeInterval(raw) else {
			return nil
		}
		return Date(timeIntervalSince1970: seconds)
	}

	/// Advance the watermark. Never moves backwards, which is the whole point.
	func advanceTrustedTime(to candidate: Date) {
		if let current = trustedTime, current >= candidate { return }
		storage.set(StorageKey.watermark, String(candidate.timeIntervalSince1970))
	}

	/// Put the mark back to a time the server has just confirmed.
	///
	/// The only thing allowed to move it backwards, and only because a reachable server is the
	/// authority on what time it is not. Without this a machine whose clock ran far ahead once
	/// would serve that penalty forever, judged against a mark it can never reach again.
	func resetTrustedTime(to confirmed: Date) {
		storage.set(StorageKey.watermark, String(confirmed.timeIntervalSince1970))
	}

	/// The time offline evaluation should trust.
	///
	/// Offline expiry checks read the system clock, and a user can set it back — which
	/// would otherwise return an expired licence to `valid` indefinitely. Take the later of
	/// the clock and the watermark.
	///
	/// Deliberately not a lockout. A clock that appears to have gone backwards is treated
	/// as untrustworthy rather than as evidence of tampering, so a dead CMOS battery or a
	/// fresh VM behaves sensibly instead of bricking the app. That population is real and
	/// entirely innocent.
	func effectiveNow() -> Date {
		guard let mark = trustedTime else { return now() }
		return max(now(), mark)
	}
}
