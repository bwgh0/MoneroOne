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
    /// The outgoing transfers that are in a block: a claim or reclaim that
    /// can no longer drop.
    var minedSpendTxids: [String] = []
    /// Hashes of the incoming transfers (fundings), oldest first.
    var fundingTxids: [String] = []
    /// Block height of the oldest mined incoming transfer; nil while every
    /// funding waits in the pool.
    var fundingHeight: UInt64? = nil
    /// The block height the scan reached; 0 when unknown.
    var height: UInt64 = 0
    /// wallet2's fee estimate for a sweep of the balance, piconero. Nil when
    /// the check did not ask for one, the envelope is empty or the estimate
    /// failed.
    var sweepFee: UInt64? = nil

    static let empty = EnvelopeObservation(fundingSeen: false, fundingConfirmations: 0, balance: 0, unlockedBalance: 0, spendTxids: [])
}

enum EnvelopeStatusRules {
    /// How long our claim or reclaim may stay unseen in a block, and absent
    /// from this wallet's history, before it counts as dropped.
    static let settleGrace: TimeInterval = 60 * 60

    /// How far past a funding attempt with no known funding the envelope is
    /// scanned for it: about one day of blocks.
    static let fundingScanBlocks: UInt64 = 720

    /// The status table of the spec, as one pure function.
    /// - Parameters:
    ///   - observation: what the envelope sync saw.
    ///   - current: the record's stored status. A settled link keeps it
    ///     unless the scan shows money its settle left behind
    ///     (``settledStatus(_:role:settleTxid:observation:)``).
    ///   - role: whose link it is.
    ///   - settleTxid: our own claim or reclaim, if we sent one.
    ///   - spendsBeforeSettle: the envelope's spends from before it (our
    ///     earlier sweeps, and spends seen while the link was open). Ours, or
    ///     older than ours: never a claim that beat it.
    ///   - settleFailed: that claim or reclaim dropped
    ///     (``settleHasFailed(settleTxid:settledAt:observation:transactions:now:)``).
    ///   - fundingKnown: a funding transaction is known (a sent link's
    ///     txid). The wallet's own history wins over a scan that missed it:
    ///     the link waits, never reads "not funded".
    static func status(
        for observation: EnvelopeObservation,
        current: EnvelopeStatus = .pending,
        role: EnvelopeRecord.Role = .sent,
        settleTxid: String? = nil,
        spendsBeforeSettle: [String] = [],
        settleFailed: Bool = false,
        fundingKnown: Bool = false
    ) -> EnvelopeStatus {
        if current.isSettled {
            return settledStatus(current, role: role, settleTxid: settleTxid, spendsBeforeSettle: spendsBeforeSettle,
                                 settleFailed: settleFailed, observation: observation)
        }
        guard observation.fundingSeen else { return fundingKnown ? .pending : .notFunded }
        if observation.balance == 0 {
            // Claimed only once a spend is on chain (wallet2 sees another
            // device's spend when it is mined). Zero balance and no spend
            // is a funding still in the pool, or a balance not read yet.
            if observation.spendTxids.isEmpty { return .pending }
            // Our earlier reclaim, mined after the link opened again (it
            // read as dropped), took the money: still ours.
            if role == .sent, Set(spendsBeforeSettle).isSuperset(of: observation.spendTxids) { return .reclaimed }
            return .claimed
        }
        // wallet2 unlocks an output after 10 confirmations; unlocked money
        // is claimable whatever a second, newer funding still waits for.
        return observation.unlockedBalance > 0 ? .ready : .pending
    }

    /// A claimed or reclaimed link stays settled. It opens again (Ready)
    /// when the scan sees spendable money still in the envelope and either
    /// the spend that settled it is in a block (the money came later, or was
    /// still locked at the sweep) or our claim or reclaim dropped. A fresh
    /// envelope may not see our spend while it waits in the pool, so a scan
    /// from before it is mined still sees the money; inside its grace that
    /// scan must not reopen it.
    /// A spend that is neither our reclaim nor one from before it
    /// (`spendsBeforeSettle`), with our reclaim not seen, is a claim that
    /// beat it.
    static func settledStatus(_ settled: EnvelopeStatus, role: EnvelopeRecord.Role, settleTxid: String?, spendsBeforeSettle: [String] = [], settleFailed: Bool = false, observation: EnvelopeObservation) -> EnvelopeStatus {
        let ours = settleTxid.flatMap { $0.isEmpty ? nil : $0 }
        if role == .sent, let ours {
            // A claim beat our reclaim: final.
            if settled == .claimed { return .claimed }
            let otherSpend = observation.spendTxids.contains { $0 != ours && !spendsBeforeSettle.contains($0) }
            if otherSpend && !observation.spendTxids.contains(ours) {
                return .claimed
            }
        }
        // Our sweep dropped: the money it took is spendable again.
        if ours != nil, settleFailed, observation.unlockedBalance > 0 { return .ready }
        // Our claim or reclaim, or a claim or reclaim made elsewhere: the
        // spends the envelope saw (wallet2 sees another device's spend once
        // mined).
        let spends = ours.map { [$0] } ?? observation.spendTxids
        return reopens(settledBy: spends, observation) ? .ready : settled
    }

    /// Our claim or reclaim dropped (or a reorg took it out): the envelope
    /// does not see it, in the pool or in a block, and this wallet's history
    /// marks it failed or, past `settleGrace`, does not show it waiting or
    /// mined. A sweep to another wallet is judged by the grace alone.
    static func settleHasFailed(settleTxid: String?, settledAt: Date?, observation: EnvelopeObservation, transactions: [MoneroTransaction], now: Date) -> Bool {
        guard let txid = settleTxid, !txid.isEmpty, !observation.spendTxids.contains(txid) else { return false }
        if let transaction = transactions.first(where: { $0.id == txid }) {
            return transaction.status == .failed
        }
        guard let settledAt else { return false }
        return now.timeIntervalSince(settledAt) > settleGrace
    }

    /// Our claim or reclaim went out, no scan has seen it in a block, and
    /// this wallet's history does not show it waiting or mined: a background
    /// look tells whether it dropped or a claim beat it. Not for a reclaim a
    /// claim already beat (final).
    static func needsSettleLook(_ record: EnvelopeRecord, transactions: [MoneroTransaction]) -> Bool {
        guard record.status.isSettled, record.link != nil, let txid = record.settleTxid, !txid.isEmpty,
              record.settleSeenMined != true else { return false }
        if record.role == .sent, record.status == .claimed { return false }
        return !transactions.contains { $0.id == txid && $0.status != .failed }
    }

    /// A hidden sent link whose funding attempt may have reached the
    /// network: the node can take a funding the app never heard back about.
    /// Its envelope is scanned until the scan has covered about a day of
    /// blocks past the attempt with no funding; the secret stays. An attempt
    /// that failed before anything was sent needs no scan, and one the app
    /// closed during waits a while, so a send still running can finish.
    static func needsFundingScan(_ record: EnvelopeRecord, now: Date) -> Bool {
        guard record.role == .sent, record.link != nil, record.fundingTxid == nil,
              let started = record.fundingStartedAt, record.fundingNotSent != true else { return false }
        switch record.status {
        case .notFunded: break
        case .created: guard now.timeIntervalSince(started) > 10 * 60 else { return false }
        default: return false
        }
        // The link is made at the tip less the restore margin, just before
        // its one funding attempt.
        let attemptHeight = record.restoreHeight + EnvelopeLink.restoreHeightMargin
        return (record.lastScannedHeight ?? 0) < attemptHeight + fundingScanBlocks
    }

    /// Every spend that settled the link is in a block, and unlocked money
    /// is still in the envelope.
    static func reopens(settledBy spends: [String], _ observation: EnvelopeObservation) -> Bool {
        !spends.isEmpty && observation.unlockedBalance > 0 && Set(observation.minedSpendTxids).isSuperset(of: spends)
    }

    /// The leftover check of a settled link reached its answer: the spend
    /// that settled it is in a block, and the envelope holds nothing still
    /// locked. A later look cannot change the status.
    static func leftoverCheckIsConclusive(role: EnvelopeRecord.Role, settleTxid: String?, observation: EnvelopeObservation) -> Bool {
        let spends = settleTxid.flatMap { $0.isEmpty ? nil : [$0] } ?? observation.spendTxids
        guard !spends.isEmpty, Set(observation.minedSpendTxids).isSuperset(of: spends) else { return false }
        return observation.balance == 0 || observation.unlockedBalance > 0
    }

    /// Whether a settled link's detail should look at its envelope for money
    /// its settle left behind. Not for a reclaim a claim beat (final), not
    /// while our spend still waits in this wallet's pool (a scan cannot
    /// reopen it yet), and at most once per `interval`.
    static func isLeftoverCheckDue(_ record: EnvelopeRecord, transactions: [MoneroTransaction], now: Date, interval: TimeInterval) -> Bool {
        guard record.status.isSettled, record.link != nil else { return false }
        if record.role == .sent, record.status == .claimed, record.settleTxid != nil { return false }
        if let txid = record.settleTxid, transactions.contains(where: { $0.id == txid && $0.status == .pending }) {
            return false
        }
        if let last = record.lastCheckedAt, now.timeIntervalSince(last) < interval { return false }
        return true
    }

    /// "Expired" is a label over pending and ready, not a stored status:
    /// the money is still there and the sender should take it back.
    /// An expiry of 0 means none (a received v2 link carries no expiry).
    static func isExpired(_ status: EnvelopeStatus, expiry: Int64, now: Date) -> Bool {
        guard expiry > 0, status == .pending || status == .ready else { return false }
        return now.timeIntervalSince1970 > TimeInterval(expiry)
    }

    /// When a received link's days to claim end: its own expiry (a v1
    /// link carries one), else 30 days after this device got it (a v2
    /// link carries none).
    static func claimDeadline(expiry: Int64, receivedAt: Date) -> Date {
        expiry > 0 ? Date(timeIntervalSince1970: TimeInterval(expiry)) : receivedAt.addingTimeInterval(EnvelopeLink.defaultLifetime)
    }

    /// A received link whose money never arrived (no check saw any) and
    /// whose days to claim are over: it leaves Open and the balance card's
    /// line for History, as Expired. It keeps its secret, so money that
    /// shows up later (a check reads pending or ready) brings it back.
    static func isReceivedExpired(_ status: EnvelopeStatus, role: EnvelopeRecord.Role, expiry: Int64, receivedAt: Date, now: Date) -> Bool {
        guard role == .received, status == .created || status == .notFunded else { return false }
        return now > claimDeadline(expiry: expiry, receivedAt: receivedAt)
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

    /// Saved envelope files hold a scan that started at `savedStart`: it
    /// was written once the envelope's first refresh ran and was saved, so
    /// a scan cut off later (a timeout, a close) resumes. Those files are
    /// used when that scan started at or below `floor`. Files with no saved
    /// start (the app was killed before the first save, or files from
    /// before this record) are rebuilt from the words.
    static func canReuseScan(savedStart: UInt64?, floor: UInt64) -> Bool {
        guard let savedStart else { return false }
        return savedStart <= floor
    }

    /// The envelope's first refresh ran: wallet2 pulled the block hashes
    /// up to the scan start and scans from there. Before it, the wallet
    /// holds one block (height 1, or 0 before the kit reports), and a save
    /// then makes the next open skip to the chain tip.
    static func hasRefreshed(walletHeight: UInt64, scanFrom: UInt64) -> Bool {
        walletHeight >= max(scanFrom, 2)
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
