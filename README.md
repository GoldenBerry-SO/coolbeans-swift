# CoolBeans for Apple platforms

Licence checks for macOS and iOS apps. Activate a device, verify online, and keep working
with no network at all. No service secret in the client — the key is the credential.

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/GoldenBerry-SO/coolbeans-swift.git", from: "0.1.0")
```

Add the `CoolBeans` product to your target:

```swift
.target(name: "YourApp", dependencies: [.product(name: "CoolBeans", package: "coolbeans-swift")])
```

In Xcode: File ▸ Add Package Dependencies, paste the URL above, and add the `CoolBeans`
library to your app target.

Requires macOS 11 or iOS 14, at minimum.

## Quick start

```swift
import CoolBeans

let cb = CoolBeans(configuration: .init(
  product: "clementine",
  publicKeys: ["1": "BASE64_PUBLIC_KEY"]   // embed these at build time
))

// On launch, and again whenever the user pastes a key. This is the whole integration.
let state = await cb.open(licenseKey: key) { next in
  if next.decision == .deny { lockOut(next) }   // fires when the verdict changes later
}
if state.decision == .deny { lockOut(state) } else { unlock() }

// On shutdown
cb.stop()
```

`open()` activates on first run, validates after that, and falls back to the cached signed
token when the network is gone. There is no instance id to hold and no verify-or-verifyOffline
choice to get wrong. The key is stored, so later launches can call `await cb.open()` with
nothing in hand.

## Configuration

Four things, all on `Configuration`:

- **`product`**: the product slug from the Cool Beans console. `activate` and `verify` fail
  closed if the server ever answers for a different one.
- **`baseURL`**: defaults to `https://app.coolbeans.tools`. Override it to point at a
  self-hosted instance, or at a local server while you build against the SDK: that is what
  `coolbeans-example` and `Examples/MacExample` both do, via the `COOLBEANS_URL` environment
  variable.
- **`publicKeys`**: Ed25519 public keys keyed by `kid`, embedded at build time. See
  "Where the public key comes from" below.
- **`syncsViaICloud`**: whether Keychain items sync to the user's other devices. Off by
  default. See "Keychain and iCloud" below.

```swift
CoolBeans(configuration: .init(
  product: "clementine",
  baseURL: URL(string: "https://app.coolbeans.tools")!,
  publicKeys: ["1": "BASE64_PUBLIC_KEY"],
  syncsViaICloud: false
))
```

## The verdict

```swift
state.decision   // .allow | .deny
state.reason     // .online .cached .grace .clockRollback | .revoked .expired .uninitialized
state.license    // the frozen §9 object, for display only
state.entitlements
```

Branch on `decision`. Nothing else. `reason` is for what you say to the user: `.grace` means
nudge them online, `.uninitialized` means ask for a key, `.revoked` means the licence is gone.

A decision plus a reason rather than a boolean, because "we have never established an
entitlement" and "you were revoked" are different screens, and a boolean loses that.

Every inconclusive answer — offline, a 5xx, a timeout, an unknown key — keeps the last
known-good state. Only a fetched `disabled` or a signed expiry in the past denies.

These names are the same strings the TypeScript SDK uses, and both SDKs run the same shared
contract fixtures (`Tests/CoolBeansTests/access-states.json`, copied from the coolbeans repo).
If the two ever disagree about who keeps working, a test fails.

## Gating features

```swift
if state.isEntitled("export_4k") { enableExport4k() }
let batchLimit = state.limit("batch_limit") ?? 1
```

Entitlements are authored on the server and signed into the token, which is what makes them
safe here. `license.plan` is a label a vendor types and `license.kind` is our lifecycle
bookkeeping: both are display only, and `if plan == "Pro"` breaks the day somebody renames a
tier.

## Where the public key comes from

Copy it out of the Cool Beans console and paste it into your source. Embedding it is the
point: a machine that has never been online still has something to check a signature
against, and on a notarised app tampering with the bundle breaks the code signature.

Keys fetched later from `/v1/pubkey` are merged with the embedded ones so a server-side
rotation does not need an app update. **Embedded keys are never displaced** — they are the
trust anchor that shipped inside your signed binary.

## What `open()` does after it returns

It keeps itself fresh, so there is no cadence for you to pick:

- **Re-checks on its own**, at a third of the token's lifetime, jittered so every install of your
  app does not wake on the same tick. A changed verdict arrives through `onChange:`.
- **Holds a floating seat itself**, on the cadence the server's own lease implies — about a third
  of the window, so one dropped beat does not cost the user their seat. A node-locked product
  returns no lease and nothing further is scheduled, so there is no seat model to branch on.
- `cb.stop()` cancels both, for app shutdown. `await cb.release()` gives the seat back on sign-out
  and returns false if it could not reach us, so you know to retry.

**Do not** call `open()` on every feature use or window focus — that is what the cached token is
for, and it turns a network blip into visible flakiness. **Do not** treat a failed check as a
reason to do anything abrupt: it already resolved to the last good state.

## Threading

`CoolBeans` is `Sendable` and safe to call from anywhere at once. Its own lock guards the
device fingerprint, and the background refresh and seat loops run as independent tasks so
`stop()` can cancel them synchronously from any thread, including a SwiftUI teardown.

`onChange` (passed to `open()`) fires from that background task, not necessarily the main
actor. Hop to `@MainActor` yourself before touching UI state from it. `LicenseGate` does
exactly this internally, which is why it is safe to observe from a view with no extra hopping
of your own (see "LicenseGate for SwiftUI" below).

A custom `CoolBeansStorage` can be called from more than one task at once, since the launch
check and the background upkeep loop both read and write it. Guard its state the way
`KeychainStorage` and `InMemoryStorage` do.

## The three offline states

| State | Meaning | In your UI |
|---|---|---|
| `valid` | Verified and inside the token TTL | Unlock, say nothing |
| `grace` | Past the TTL, licence has not expired | **Unlock.** Normal, not an error |
| `expired` | No token, unverifiable, wrong device, disabled, or the licence ended | Lock, ask them to sign in |

`grace` is the one people get wrong. It means "we have not been able to check for a while",
which happens on a plane. Do not shout about it.

Three rules carry real product decisions:

**A network failure never locks anyone out.** Grace past the TTL is unbounded for paid
tiers. That is the offline-tolerant contract.

**A signed `expires_at` in the past ends access, for every tier.** The token states the
licence ended, so honouring it is reading the credential rather than guessing from a failed
request. The server issues that date with a buffer, so someone who renews while offline has
room to reconnect.

**Trials get no grace at all**, or blocking the endpoint would be an unlimited trial.

## Seats

Activating consumes a seat; `deactivate` frees one. Device identity is hardware-derived —
`IOPlatformUUID` on macOS, `identifierForVendor` on iOS — so a reinstall or a backup
restore does **not** quietly burn another seat. That is a real failure mode with a
random-UUID approach and worth keeping in mind if you supply your own storage.

## Keychain and iCloud

The licence key is a credential, so it lives in the Keychain. Whether items sync to the
user's other devices is your call:

```swift
CoolBeans(configuration: .init(product: "clementine", syncsViaICloud: true))
```

On means "it already works on my laptop". Off means each machine activates separately and
takes its own seat. Neither is wrong — pick on purpose. Default is off.

### Supplying your own storage

`CoolBeansStorage` has three requirements, and `set` returns whether the value actually
landed:

```swift
func get(_ key: String) -> String?
@discardableResult func set(_ key: String, _ value: String) -> Bool
func remove(_ key: String)
```

Return `false` when a write fails rather than swallowing it. Activation spends a seat on
the server before anything is stored, so a write that quietly fails leaves the app looking
activated until it quits, then activating again on the next launch and taking another seat
every time. `activate` and `importActivation` turn a `false` into a thrown
`storage_failed`, which is the only way a user finds out in time to fix it.

## Offline activation (air-gapped machines)

A machine that has never had internet cannot activate normally, because activation is a
round trip. The vendor mediates instead: your app shows `cb.fingerprint()`, the customer
sends it over, an operator generates a blob in the console, and it comes back by hand.

```swift
try await cb.importActivation(pastedBlob)
```

Verified against your embedded keys, checked for product and expiry, and **bound to this
machine by a signed fingerprint claim** — a blob minted for one Mac is refused on another.
After that `offlineState()` behaves exactly as after a normal activation.

Offline activation needs a **node-locked** product. A floating seat is held by a lease the
machine renews, which an offline machine can never do, so the server refuses to mint one.

**An air-gapped machine cannot be revoked before its token expires.** That is inherent to
licensing something you cannot reach, not a defect. The token TTL is the dial.

## Clock rollback

Offline expiry reads the system clock, and a user can set it back. The SDK remembers the
highest server-stamped time it has seen and refuses to believe the clock has gone behind
it. A clock that appears to have moved backwards is distrusted, never punished — a dead
CMOS battery or a fresh VM keeps working.

## Errors

`CoolBeansError` carries `status`, a machine-readable `code`, and the server's own
sentence. Branch on `code`, show `message`.

```swift
catch let error as CoolBeansError {
  if error.code == "activation_limit_reached" { showSeatHelp() }
}
```

## Calling the pieces directly

`open()` is the call to make in an app. The pieces underneath are public too, for a CLI
tool, a diagnostics screen, or your own tests. This is what `coolbeans-example` runs end to
end:

```swift
let cb = CoolBeans(configuration: .init(product: "clementine", publicKeys: keys))

let activated = try await cb.activate(licenseKey: key)
print(activated.instance.id, activated.license.kind)

let verified = try await cb.verify(licenseKey: key, instanceId: activated.instance.id)
print(verified.valid, verified.inconclusive)

let offline = await cb.offlineState()   // .valid, .grace, or .expired: no network, ever
print(offline)

try await cb.deactivate(licenseKey: key, instanceId: activated.instance.id)
```

`verifyOffline()` is the same offline check collapsed to a bool, for a launch-time gate that
only needs yes or no:

```swift
if await cb.verifyOffline() { unlock() }
```

Prefer `open()` when you can. It runs these same calls plus the fallback and upkeep logic
as one tested unit, so there is no step to miss.

## LicenseGate for SwiftUI

`LicenseGate` wraps `CoolBeans` for a SwiftUI app: hold one, call `refresh()` on launch, and
read `isUnlocked`. It conforms to `ObservableObject` wherever Combine exists, and carries a
plain `onChange` closure everywhere else, including Linux. That portable hook is what keeps
the decision logic behind the example app's UI testable off a Mac.

```swift
@StateObject private var gate = LicenseGate(client: CoolBeans(configuration: .init(
  product: "clementine",
  publicKeys: ["1": "BASE64_PUBLIC_KEY"]
)))

var body: some Scene {
  WindowGroup {
    ContentView(gate: gate)
      // Gate on the cached token, which is instant. Blocking the window on a network call is
      // how an app comes to feel broken on a bad connection.
      .task { await gate.refresh() }
  }
}
```

```swift
struct ContentView: View {
  @ObservedObject var gate: LicenseGate

  var body: some View {
    if gate.isUnlocked {
      // gate.status == .grace means we haven't checked in a while: unlock, and mention it
      // quietly or not at all
    } else {
      // gate.status == .revoked is the one state worth an error colour
      // gate.lastError?.message is the server's own sentence, written for a person
    }
  }
}
```

`gate.activate(licenseKey:name:)` and `gate.deactivate()` wrap the `CoolBeans` calls of the
same name and map the result onto `LicenseStatus` (`.active`, `.grace`, `.revoked`,
`.locked`), so a view never reads `AccessState` directly. `gate.deviceFingerprint` is what
an air-gapped activation needs (see "Offline activation" above).

This is optional: the raw `CoolBeans` verdict works just as well on its own. `LicenseGate`
exists because the logic behind `Examples/MacExample`'s UI needed to be testable off a
device.

## Testing your integration

`CoolBeansTransport` and `CoolBeansStorage` are the two seams. Swap `URLSessionTransport`
for a `StubTransport` (canned responses, keyed on path and request body) and the
Keychain-backed default for `InMemoryStorage`, and a test drives the whole decision table
with no network and no device Keychain:

```swift
let transport = StubTransport { path, _ in
  path == "/v1/activate"
    ? (200, #"{"ok":true,"license":{"key":"K","status":"active","kind":"perpetual","product":"clementine","expires_at":null},"instance":{"id":"i","name":"n"}}"#)
    : (200, #"{"ok":true}"#)
}
let cb = CoolBeans(
  configuration: .init(product: "clementine"),
  storage: InMemoryStorage(),
  transport: transport)
```

This is exactly how the SDK's own suite drives every case in
`Tests/CoolBeansTests/access-states.json`, the contract fixture this SDK and the TypeScript
one both run so they cannot quietly disagree about who keeps working.

## Distribution

This targets **direct distribution** — notarised, outside the App Store. On the App Store
Apple owns purchase and receipt validation and you would not use this for those builds.

## Examples

**`Examples/MacExample`** is a licence-gated SwiftUI app for macOS — key entry, activation,
gated content, the offline state shown honestly, and the device fingerprint an operator
needs for an air-gapped activation. It is the thing to copy, and it is what "LicenseGate for
SwiftUI" above walks through.

All of its decisions live in `LicenseGate`, which is plain Swift and covered by tests. The
SwiftUI file is presentation only. Logic that lives in a view is logic nobody can test.

```bash
cd Examples/MacExample && swift build
```

**`coolbeans-example`** is a headless executable that runs anywhere, including Linux CI:

```bash
COOLBEANS_URL=http://localhost:3000 COOLBEANS_PRODUCT=clementine \
COOLBEANS_KEY=CLEM-XXXX-XXXX-XXXX-XXXX swift run coolbeans-example
```

Activates, verifies, prints the offline state and frees the seat.

## Platform support

macOS 11+, iOS 14+. Ed25519 uses the system CryptoKit on Apple platforms. On Linux —
where the test suite runs in CI — Apple's source-compatible `swift-crypto` is linked
instead, so the whole decision table is tested on every push rather than only on a Mac.

## Development

```bash
swift test
```

runs the full suite (69 tests) with no network and no Apple-only dependency: `InMemoryStorage`
stands in for the Keychain, which is what lets the whole decision table run on Linux too. CI
(`.github/workflows/ci.yml`) runs that suite on a `swift:6.0` Linux container, plus a macOS
job that additionally builds the Keychain/IOKit-backed pieces, the iOS target, and
`Examples/MacExample`. SwiftUI and AppKit exist nowhere else, so that macOS job is the only
place the example app is ever compiled, which keeps it from rotting silently.

There is no separate lint or format step. Every source file opens with two `// ABOUTME:`
comment lines; match that when you add one.

## License

MIT. See [LICENSE](LICENSE).
