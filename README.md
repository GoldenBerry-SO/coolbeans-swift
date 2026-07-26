# CoolBeans for Apple platforms

Licence checks for macOS and iOS apps. Activate a device, verify online, and keep working
with no network at all. No service secret in the client — the key is the credential.

```swift
.package(url: "https://github.com/GoldenBerry-SO/coolbeans-swift.git", from: "0.1.0")
```

```swift
import CoolBeans

let cb = CoolBeans(configuration: .init(
  product: "clementine",
  publicKeys: ["1": "BASE64_PUBLIC_KEY"]   // embed these at build time
))

// On launch, and again whenever the user pastes a key. This is the whole integration.
let state = await cb.open(licenseKey: key)
if state.decision == .deny { lockOut(state) } else { unlock() }
```

`open()` activates on first run, validates after that, and falls back to the cached signed
token when the network is gone. There is no instance id to hold and no verify-or-verifyOffline
choice to get wrong. The key is stored, so later launches can call `await cb.open()` with
nothing in hand.

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

## How often to check

This SDK has no run loop of its own, so the cadence is yours: call `open()` on launch, then
roughly every TTL/3 to TTL/2 — daily on the 7-day default, which gives two or three chances
to reconnect before a user drifts into grace. Add jitter so every install does not wake on
the same tick.

For a **floating** product also call `await cb.holdSeat()` on a timer, at about a third of
the lease window it hands back, so one dropped request does not cost the user their seat. It
returns nil for a node-locked product, so there is no seat model to branch on.

**Do not** call `open()` on every feature use or window focus — that is what the cached token
is for, and it turns a network blip into visible flakiness. **Do not** treat a failed check as
a reason to do anything abrupt: it already resolved to the last good state.

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

## Distribution

This targets **direct distribution** — notarised, outside the App Store. On the App Store
Apple owns purchase and receipt validation and you would not use this for those builds.

## Examples

**`Examples/MacExample`** is a licence-gated SwiftUI app for macOS — key entry, activation,
gated content, the offline state shown honestly, and the device fingerprint an operator
needs for an air-gapped activation. It is the thing to copy.

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
