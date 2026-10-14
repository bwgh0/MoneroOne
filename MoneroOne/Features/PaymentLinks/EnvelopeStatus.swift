import Foundation

/// Where a payment link stands. Stored on the record as the last known value
/// and recomputed from the record plus an envelope sync.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Status".
enum EnvelopeStatus: String, Codable, Equatable {
    /// Saved before the funding broadcast; nothing known yet.
    case created
    /// No funding seen (the broadcast failed, or the chain has not shown it).
    case notFunded
    /// Funding seen, fewer than 10 confirmations.
    case pending
    /// Balance > 0 and unlocked: claimable.
    case ready
    /// Funding seen, balance now 0, and we did not take it. On a received
    /// record with a settle txid, we are the ones who claimed it.
    case claimed
    /// The sender swept it back.
    case reclaimed

    /// No further chain change can alter it.
    var isSettled: Bool { self == .claimed || self == .reclaimed }
}

/// What one envelope sync saw.
struct EnvelopeObservation: Equatable {
    /// Any incoming transfer, in the pool or mined.
    var fundingSeen: Bool
    /// Confirmations of the oldest incoming transfer (the one that unlocks
    /// first); 0 while it waits in the pool.
    var fundingConfirmations: Int
    /// Piconero.
    var balance: UInt64
    var unlockedBalance: UInt64
    /// Hashes of outgoing transfers (claims or reclaims) the envelope saw.
    var spendTxids: [String]
    /// Block height of the oldest mined incoming transfer; nil while every
    /// funding waits in the pool.
    var fundingHeight: UInt64? = nil

    static let empty = EnvelopeObservation(fundingSeen: false, fundingConfirmations: 0, balance: 0, unlockedBalance: 0, spendTxids: [])
}

enum EnvelopeStatusRules {
    /// How long a reclaim may stay unseen while the money is still in the
    /// envelope before it counts as dropped.
    static let reclaimGrace: TimeInterval = 30 * 60

    /// The status table of the spec, as one pure function.
    /// - Parameters:
    ///   - observation: what the envelope sync saw.
    ///   - reclaimTxid: our own reclaim sweep, if we sent one.
    ///   - reclaimAge: seconds since that reclaim went out.
    static func status(for observation: EnvelopeObservation, reclaimTxid: String?, reclaimAge: TimeInterval? = nil) -> EnvelopeStatus {
        if let reclaimTxid {
            // Our reclaim went out. It stays "reclaimed" unless the chain
            // shows a different spend, which means a claim won the race.
            let ours = observation.spendTxids.contains(reclaimTxid)
            let otherSpend = observation.spendTxids.contains { $0 != reclaimTxid }
            if otherSpend && !ours {
                return .claimed
            }
            // Not seen long after it went out, and the money is still
            // there: the reclaim dropped. The normal rules offer it again.
            let dropped = !ours && !otherSpend && observation.balance > 0 && (reclaimAge ?? 0) > reclaimGrace
            if !dropped {
                return .reclaimed
            }
        }
        guard observation.fundingSeen else { return .notFunded }
        if observation.balance == 0 {
            // Claimed only once a spend is on chain (wallet2 sees another
            // device's spend when it is mined). Zero balance and no spend
            // is a funding still in the pool, or a balance not read yet.
            return observation.spendTxids.isEmpty ? .pending : .claimed
        }
        // wallet2 unlocks an output after 10 confirmations; unlocked money
        // is claimable whatever a second, newer funding still waits for.
        return observation.unlockedBalance > 0 ? .ready : .pending
    }

    /// "Expired" is a label over pending and ready, not a stored status:
    /// the money is still there and the sender should take it back.
    /// An expiry of 0 means none (a received v2 link carries no expiry).
    static func isExpired(_ status: EnvelopeStatus, expiry: Int64, now: Date) -> Bool {
        guard expiry > 0, status == .pending || status == .ready else { return false }
        return now.timeIntervalSince1970 > TimeInterval(expiry)
    }

    /// Minutes until a pending envelope unlocks, at 2 minutes per block.
    static func minutesUntilReady(confirmations: Int) -> Int {
        max(0, EnvelopeLink.confirmationsToUnlock - confirmations) * 2
    }
}
