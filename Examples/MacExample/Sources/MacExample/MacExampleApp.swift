// ABOUTME: A licence-gated macOS app — the thing to copy when wiring Cool Beans into yours.
// ABOUTME: All decisions live in LicenseGate; this file is only presentation.

import CoolBeans
import SwiftUI

// Replace with your product and the public key from the console. Embedding the key is the
// point: it is what lets a machine that has never been online verify a token.
private let product = "clementine"
private let publicKeys: [String: String] = ["1": "REPLACE_WITH_YOUR_PUBLIC_KEY"]

@main
struct MacExampleApp: App {
	@StateObject private var gate = LicenseGate(
		client: CoolBeans(
			configuration: .init(
				product: product,
				baseURL: URL(string: ProcessInfo.processInfo.environment["COOLBEANS_URL"] ?? "http://localhost:3000")!,
				publicKeys: publicKeys)))

	var body: some Scene {
		WindowGroup {
			ContentView(gate: gate)
				// Gate on the cached token, which is instant. Blocking the window on a
				// network call is how an app comes to feel broken on a bad connection.
				.task { await gate.refresh() }
		}
		.windowResizability(.contentSize)
	}
}

struct ContentView: View {
	@ObservedObject var gate: LicenseGate
	@State private var key = ""
	@State private var busy = false

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			if gate.isUnlocked {
				unlocked
			} else {
				entry
			}
		}
		.padding(24)
		.frame(width: 420)
	}

	private var unlocked: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("You're all set").font(.title2).bold()
			Text("This is the part of the app a licence pays for.")
				.foregroundStyle(.secondary)

			// grace is NOT an error. It means we have not been able to check for a while,
			// which happens to anyone on a plane. Mention it quietly or not at all.
			if gate.status == .grace {
				Label("Offline — we'll re-check when you're back online.", systemImage: "wifi.slash")
					.font(.callout)
					.foregroundStyle(.secondary)
			}

			Button("Deactivate this Mac") {
				Task { await gate.deactivate(licenseKey: key) }
			}
			.padding(.top, 8)
		}
	}

	private var entry: some View {
		VStack(alignment: .leading, spacing: 12) {
			Text("Enter your licence key").font(.title2).bold()

			if gate.status == .revoked {
				// The one state that genuinely warrants an error presentation.
				Label("This licence was disabled.", systemImage: "exclamationmark.triangle")
					.foregroundStyle(.red)
			}

			TextField("CLEM-XXXX-XXXX-XXXX-XXXX", text: $key)
				.textFieldStyle(.roundedBorder)
				.disableAutocorrection(true)

			if let error = gate.lastError {
				// Show the server's own sentence; it is written for a person.
				Text(error.message).font(.callout).foregroundStyle(.red)
			}

			HStack {
				Button(busy ? "Activating…" : "Activate") {
					busy = true
					Task {
						await gate.activate(licenseKey: key)
						busy = false
					}
				}
				.disabled(key.isEmpty || busy)
				.keyboardShortcut(.defaultAction)

				Spacer()

				// The fingerprint an operator needs for an air-gapped activation.
				Text(verbatim: "ID \(gate.deviceFingerprint.prefix(8))")
					.font(.caption.monospaced())
					.foregroundStyle(.tertiary)
					.textSelection(.enabled)
			}
		}
	}
}
