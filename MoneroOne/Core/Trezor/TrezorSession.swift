import Foundation

// TrezorSession was the actor sketch for the cold-sign blob-exchange
// architecture (Path B). That approach turned out incompatible with
// wallet2's API gates for HW wallets — wallet2 can't produce signed
// key-image blobs without the spend secret, so the cold/hot blob
// dance can't work.
//
// The dual-cache architecture (Path A's evolution) replaces it. The
// session driver lives on `WalletManager.runHardware{Sync,Send}Session`
// directly, with state observable via `walletManager.hardwareSessionState`
// and the UI in `HardwareSessionSheet`.
//
// File kept (empty) so we don't have to surgically remove it from
// xcodeproj — it's still listed in the build phase.
