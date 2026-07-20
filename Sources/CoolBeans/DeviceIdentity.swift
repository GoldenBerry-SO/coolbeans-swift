// ABOUTME: A stable id for this machine, so a reinstall does not consume another seat.
// ABOUTME: Hardware-derived on Apple platforms; a persisted UUID is the portable fallback.

import Foundation

#if canImport(IOKit)
import IOKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Resolve the id this device activates under.
///
/// The TypeScript SDK persists a random UUID, which means clearing application support or
/// restoring a backup silently burns another activation seat. Prefer something derived
/// from the hardware: it survives an OS reinstall and changes when the machine does, which
/// is exactly the semantics node-locked licensing wants.
func resolveDeviceIdentifier(storage: CoolBeansStorage) -> String {
	if let hardware = hardwareIdentifier(), !hardware.isEmpty {
		return hardware
	}
	// No hardware id available (Linux, or a platform that withheld it): fall back to a
	// persisted UUID and accept that losing storage costs a seat.
	if let stored = storage.get(StorageKey.device) { return stored }
	let fresh = UUID().uuidString
	storage.set(StorageKey.device, fresh)
	return fresh
}

private func hardwareIdentifier() -> String? {
	#if os(macOS) && canImport(IOKit)
	// IOPlatformUUID is stable for the life of the machine and survives OS reinstalls.
	let matching = IOServiceMatching("IOPlatformExpertDevice")
	let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
	guard service != 0 else { return nil }
	defer { IOObjectRelease(service) }
	let key = kIOPlatformUUIDKey as CFString
	guard
		let cf = IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?
			.takeRetainedValue() as? String
	else { return nil }
	return cf
	#elseif canImport(UIKit)
	// Stable per vendor per device; resets only when every app from this vendor is
	// removed, which is the closest iOS offers.
	return UIDevice.current.identifierForVendor?.uuidString
	#else
	return nil
	#endif
}
