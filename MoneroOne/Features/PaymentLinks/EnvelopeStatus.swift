import Foundation

/// Where a payment link stands. Stored on the record as the last known value
/// and recomputed from the record plus an envelope sync.
/// Spec: docs/2026-10-03-payment-links-spec.md, "Status".
enum EnvelopeStatus: String, Codable, Equatable {
    /// Saved before the funding broadcast; nothing known yet.
    case created
    /// No funding anywhere: no funding transaction is known and the scan
    /// saw nothing. A sent link in this state is hidden (the Send flow
    /// showed the failure); it comes back when a funding turns up.
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
    /// Hashes of the incoming transfers (fundings), oldest first.
    var fundingTxids: [String] = []
    /// Block height of the oldest mined incoming transfer; nil while every
    /// funding waits in the pool.
    var fundingHeight: UInt64? = nil
    /// wallet2's fee estimate for a sweep of the balance, piconero. Nil when
    /// the check did not ask for one, the envelope is empty or the estimate
    /// failed.
    var sweepFee: UInt64? = nil

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
    ///   - fundingKnown: a funding transaction is known (a sent link's
    ///     txid). The wallet's own history wins over a scan that missed it:
    ///     the link waits, never reads "not funded".
    static func status(for observation: EnvelopeObservation, reclaimTxid: String?, reclaimAge: TimeInterval? = nil, fundingKnown: Bool = false) -> EnvelopeStatus {
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
        guard observation.fundingSeen else { return fundingKnown ? .pending : .notFunded }
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

    /// A sent record whose funding transaction is known reads at least
    /// pending: "created" and "not funded" would contradict the wallet's
    /// own history.
    static func reconciled(_ status: EnvelopeStatus, role: EnvelopeRecord.Role, fundingTxid: String?) -> EnvelopeStatus {
        guard role == .sent, fundingTxid != nil, status == .created || status == .notFunded else { return status }
        return .pending
    }

    /// The height the envelope scan must start at or below: the link's
    /// restore height, or the funding block when that is lower.
    static func scanFloor(restoreHeight: UInt64, fundingHeight: UInt64?) -> UInt64 {
        guard let fundingHeight, fundingHeight > 0 else { return restoreHeight }
        return min(restoreHeight, fundingHeight)
    }

    /// The envelope wallet must be scanned again from `floor`. wallet2
    /// moves the start of a wallet that was saved before its first scan to
    /// the chain tip when it opens again (WalletImpl::doInit,
    /// isNewWallet) and skips the blocks below it, so a scan that starts
    /// above the floor misses the funding. Once that cache is saved, the
    /// start reads right again (it comes from the keys file) while the
    /// skipped blocks stay skipped: a funding mined below the scanned
    /// height that the scan did not see asks for one more scan, once per
    /// app run.
    static func needsRescan(scanStart: UInt64, floor: UInt64, fundingSeen: Bool, fundingHeight: UInt64?, walletHeight: UInt64, alreadyRescanned: Bool) -> Bool {
        if scanStart > floor { return true }
        guard !alreadyRescanned, !fundingSeen, let fundingHeight, fundingHeight > 0 else { return false }
        return walletHeight > fundingHeight
    }

    /// Minutes until a pending envelope unlocks, at 2 minutes per block.
    static func minutesUntilReady(confirmations: Int) -> Int {
        max(0, EnvelopeLink.confirmationsToUnlock - confirmations) * 2
    }
}
