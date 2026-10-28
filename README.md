# Monero One

A native iOS wallet for Monero, built with SwiftUI.

[![CI](https://github.com/bwgh0/MoneroOne/actions/workflows/ci.yml/badge.svg)](https://github.com/bwgh0/MoneroOne/actions/workflows/ci.yml)

## Features

- Create, restore, and manage multiple Monero wallets
- Polyseed and legacy 25-word seed support
- Send and receive XMR with QR code scanning
- Face ID / Touch ID unlock
- Live price charts and price alerts
- Home screen widgets
- Live Activity sync progress in Dynamic Island
- iPad support
- Connect to any Monero node (remote or local)
- SOCKS proxy / Tor support

## Building from source

### Requirements

- Xcode 16+
- iOS 17.0+ deployment target
- [MoneroKit.Swift](https://github.com/bwgh0/MoneroKit.Swift) cloned alongside this repo

### Setup

```bash
# Clone both repos side by side
git clone https://github.com/bwgh0/MoneroOne.git
git clone https://github.com/bwgh0/MoneroKit.Swift.git

# Open in Xcode
open MoneroOne/MoneroOne.xcodeproj
```

The project expects `MoneroKit.Swift` at `../MoneroKit.Swift` relative to the MoneroOne directory:

```
parent/
  MoneroOne/
  MoneroKit.Swift/
```

Select the `MoneroOne` scheme, pick a simulator or your device, and build.

### Username development branch (2026-10-21)

The native claim flow uses the existing `oah-core` and registry, through the new `oah-mobile` C boundary. This branch is based on `feature/motion-moments` (`0648931`). It needs the signing kit at `0df961d` (`feature/handles-sign`), alongside this checkout. CI checks out that kit commit and builds the verifier from `bwgh0/oah` at `ef77ae2` with the `OAH_DEPLOY_KEY` secret (`.github/actions/build-oah`).

Build the local verifier before opening Xcode:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
OAH_REPO=/path/to/oah bash scripts/build-oah-ios.sh
```

The generated XCFramework is ignored by Git. The simulator slice is arm64, matching the existing MoneroKit binary. The local OAH repository must contain `crates/oah-mobile` (`feature/mobile-claim`). Do not regenerate the Xcode project; its package and file references are maintained directly.

Release builds talk only to the production registry (`https://registry.monero.one`) and mirror (`https://mirror.monero.one/oah/v1/`), with the pins in `UsernameEnvironment.production` (UsernameRegistry.swift). Debug builds use the staging registry and mirror by default and never reach production. To test against a local registry, set these launch environment variables; each one replaces its staging value:

- `USERNAME_REGISTRY_URL=http://localhost:8787`
- `USERNAME_MIRROR_URL=<the local mirror URL>`
- `USERNAME_GENESIS_ROOT=<64 lowercase hex, the local epoch 0 root>`
- `USERNAME_REGISTRAR_KEY=<64 lowercase hex, pinned from the local registry setup>`
- `USERNAME_RULES_HASH=<64 lowercase hex, pinned from the local rules>`
- `USERNAME_TERMS_VERSION=<optional, sent as terms_version>`

`USERNAME_TEST_RESET=1` (debug builds only) starts the app with no saved usernames and a new device ID; `keep-device` keeps the device ID.

Initialize the local registry using its README, including its development epoch 0. The app checks those pins against `/v1/info` and the canonical rules; fetching an untrusted key is not a substitute for supplying the expected pin. The production build cannot enable this local device-proof implementation. Home and Welcome make no eligibility or username requests; network work begins at the final Claim tap.

Approved design: 27R with one balance-card surface, an orange outer top edge, a straight separator, and only `@username` on Home. The existing glass wallet switcher and inline History behavior remain. The strip opens the Inset + Core card, which shows both `@Joe` and `joe@monero.one`, with `MONERO ONE` at top right. Each size uses fixed type regardless of name length; the shared rules enforce 3–15 characters. Both appearances use the same structure. Copy offers the two formats and the share link; Share includes a native rendering of the card.

Bindings are stored in the device-only Keychain and scoped by network plus the wallet's primary address. Development and production use separate Keychain services. The cache ID is intentionally not used: it changes during a rescan. The primary address is never sent as an identity key; registration uses a designated subaddress. The signed pending request is saved before POST. Recovery verifies the exact signed genesis, wallet address, rules and registrar pin before publishing the binding. A wallet switch or lock dismisses the flow, while an admitted claim still saves against its captured wallet. The local 12-month eligibility date is only a hint; the registry enforces the phone slot.

Verification: `MoneroOneTests/UsernameTests` covers rules, wallet/network scoping, rescan identity, failed writes, concurrency, interrupted-response recovery with a real wallet2 vector, registrar pin failures and forged signatures. Run this unit class on an arm64 simulator, not the UI test target.

Offline native preview (simulator Debug only, no signing or Keychain writes): launch with `--uitesting --balance-history-fixture --username-preview`. Optional flags: `--username-details`, `--username-switcher`, `--username-history`. Set `USERNAME_PREVIEW_HANDLE` to compare `Joe`, `xmr_garden_club` or 15-character names.

This implements the local claim-and-card milestone. Public registration still needs the existing launch gates: real device verification, production pins/epoch 0, hosted registry/DNS, finalized terms and the outstanding wallet-file protection work. First-contact username resolution and Send verification, ownership restoration on a new phone, rotation and owner notices remain separate work. A development card is not a publicly resolvable username.

### CI

CI runs automatically on every push to `main` or a `feature/**` branch and on every pull request to `main` — it builds for the iOS Simulator (no signing required). Tagged releases (`v*`) trigger a TestFlight deploy and publish a sideloadable IPA to [GitHub Releases](https://github.com/bwgh0/MoneroOne/releases).

## Releases

Every tagged release publishes:
- **TestFlight build** — available through the App Store
- **Sideloadable IPA** — attached to the [GitHub Release](https://github.com/bwgh0/MoneroOne/releases) with a SHA-256 hash for verification

## Security

Found a vulnerability? See [SECURITY.md](SECURITY.md) for responsible disclosure guidelines.

## License

MIT — see [LICENSE](LICENSE).


### Username payments (2026-10-21)

Send classifies `@Joe` and `joe@monero.one` into the shared signature verifier.
A username is one label: the `@` form never takes a dot (`@getmonero.org` is
invalid), and a dotted name under monero.one stays reserved, with no lookup. The operator's `donate@monero.one` continues through
the existing DNSSEC/OpenAlias path. Home still shows only the short username.
The client fetches the chain from the operator and the signed snapshot from a
separate mirror, checks the pinned namespace genesis/rules/key, and persists
root identity pins and signed receipts before exposing a payment address.
Receipt write failures stop resolution.

The UI distinguishes “Signature checked,” “Not yet in the public log,” and stale
records. A first payment asks the user to confirm the username. The provisional
cap of 0.1 XMR applies to stale, expired and pending records, and Max is off
while it applies; Send rechecks the username before broadcasting and
stops only if the address changed during review. A new trust level alone does not
stop it; the limit of the new trust level applies. The cap awaits
founder preference. API and mirror requests respect Tor with no direct fallback.
No public resolution configuration is enabled yet.

Local testing additionally requires a separate mirror serving the registry's
public objects plus a pinned genesis epoch root. iOS reads `USERNAME_MIRROR_URL`
and `USERNAME_GENESIS_ROOT`; Android reads the Gradle properties
`usernameMirrorUrl` and `usernameGenesisRoot`. Both are development-only and
restricted to localhost, alongside the existing registrar/rules pins. iOS debug
builds also accept an HTTPS `*.ts.net` (Tailscale) address, for tests on a real
phone. Run a separate local HTTP server for `var/objects`; do not use the API as
its own mirror.
