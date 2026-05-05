import Foundation

/// Chunk-level transport contract used by `THPChannel` to talk to a
/// Trezor device.
///
/// This is the seam that lets unit tests drive the THP state machine
/// without a real BLE peripheral. The production conformer is
/// `TrezorBleTransport` (CoreBluetooth-backed); test code substitutes a
/// queue-driven mock that delivers canned chunk responses.
///
/// The connection lifecycle (scan/discover/connect/disconnect) and the
/// CoreBluetooth-specific surface stay on `TrezorBleTransport` directly,
/// since neither THPChannel nor a unit test cares about them.
protocol TrezorTransport: AnyObject {
    /// Whether the transport is in THP framing mode. THPChannel flips
    /// this once the noise handshake completes — the legacy-wire path
    /// uses a different chunk shape.
    var useTHPMode: Bool { get set }

    /// Write a single 64-byte (or smaller) chunk over the underlying
    /// transport. Awaits write confirmation when the medium supports it
    /// (BLE `.withResponse`).
    func writeRawChunk(_ data: Data) async throws

    /// Read the next inbound chunk, or throw on timeout.
    func readRawChunk(timeout: TimeInterval) async throws -> Data

    /// Drop any chunks queued for read but not yet consumed. Used by
    /// THPChannel when retrying a multi-chunk send so stale half-frames
    /// don't poison the next exchange.
    func clearRawChunkBuffer()

    /// Hint to keep the underlying connection awake during long idle
    /// gaps between THP messages (e.g. the wait between fee estimation
    /// and signing). Implemented as an RSSI read on BLE; no-op for mocks.
    func keepConnectionAlive()
}
