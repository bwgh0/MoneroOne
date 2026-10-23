import XCTest
@testable import MoneroOne

/// Money arrives trigger rules, the confirmation ring and the Sent check.
final class MotionMomentsTests: XCTestCase {

    private func tx(
        _ id: String,
        _ type: MoneroTransaction.TransactionType = .incoming,
        amount: String = "1",
        confirmations: Int?,
        height: UInt64?,
        status: MoneroTransaction.TransactionStatus = .confirmed
    ) -> MoneroTransaction {
        MoneroTransaction(id: id, type: type, amount: Decimal(string: amount)!, fee: 0, address: "", timestamp: Date(),
                          confirmations: confirmations, status: status, memo: nil, blockHeight: height)
    }

    // MARK: - Rows at new blocks

    /// `MoneroTransaction`'s `==` compares ids only, so SwiftUI kept a row
    /// whose input was only the transaction. The row state and the list row
    /// change at each confirmation, so the row draws again; the row keeps
    /// its identity, so its ring animates.
    func testRowStateChangesAtEachConfirmation() {
        let nine = tx("a", confirmations: 9, height: 100)
        let ten = tx("a", confirmations: 10, height: 100)
        XCTAssertEqual(nine, ten, "MoneroTransaction == compares ids only")
        XCTAssertNotEqual(nine.rowState, ten.rowState)
        XCTAssertNotEqual(ActivityListRow(.transaction(nine)), ActivityListRow(.transaction(ten)))
        XCTAssertEqual(ActivityListRow(.transaction(nine)).id, ActivityListRow(.transaction(ten)).id)

        // A send leaves the pool: "Pending" with no ring fill, then 1 of 10.
        let pool = tx("s", .outgoing, confirmations: 0, height: nil, status: .pending)
        let mined = tx("s", .outgoing, confirmations: 1, height: 101)
        XCTAssertEqual(pool, mined)
        XCTAssertNotEqual(pool.rowState, mined.rowState)
        XCTAssertEqual(ConfirmationRing.state(of: pool), .filling(0))
        XCTAssertEqual(ConfirmationRing.state(of: mined), .filling(0.1))
        XCTAssertEqual(ConfirmationRing.state(of: ten), .confirmed)
    }

    /// The kit reports the history only at a transaction's first block and
    /// at its unlock. Each new block counts the rings again, so a ring fills
    /// one tenth per block while the list stays open. The count is no new
    /// history for Money arrives, so it does not end a block's hold.
    func testNewBlockCountsTheRingsAgain() {
        let ring = tx("r", confirmations: 1, height: 100)
        XCTAssertEqual(ring.counted(at: 105).confirmations, 5)
        XCTAssertNotEqual(ring.counted(at: 105).rowState, ring.rowState)
        XCTAssertEqual(ConfirmationRing.state(of: ring.counted(at: 109)), .filling(0.9))
        XCTAssertEqual(ConfirmationRing.state(of: ring.counted(at: 110)), .confirmed)
        XCTAssertEqual(ring.counted(at: 105).arrivalState, ring.arrivalState)

        // No ring: no change.
        let pool = tx("p", confirmations: 0, height: nil, status: .pending)
        let spendable = tx("s", confirmations: 30, height: 70)
        let failed = tx("f", confirmations: 3, height: 100, status: .failed)
        for other in [pool, spendable, failed] {
            XCTAssertEqual(other.counted(at: 105).rowState, other.rowState)
        }

        // A pool payment's first block is a new history.
        XCTAssertNotEqual(pool.arrivalState, tx("p", confirmations: 1, height: 104).arrivalState)
    }

    // MARK: - Money arrives

    /// Only incoming payments in a block above the baseline count. Pool
    /// payments, failed ones, sends, old ones and our reclaims do not.
    func testArrivalsAreNewIncomingPaymentsInABlock() {
        let transactions = [
            tx("new", confirmations: 1, height: 101),
            tx("pool", confirmations: 0, height: nil, status: .pending),
            tx("failed", confirmations: 3, height: 102, status: .failed),
            tx("send", .outgoing, confirmations: 1, height: 101),
            tx("old", confirmations: 30, height: 70),
            tx("atBaseline", confirmations: 5, height: 100),
            tx("reclaim", confirmations: 1, height: 101),
        ]
        let arrivals = MoneyArrivalRules.arrivals(in: transactions, baseline: 100, excluding: ["reclaim"])
        XCTAssertEqual(arrivals.map(\.id), ["new"])
    }

    /// Several payments found in one check give one +amount: their sum.
    func testSeveralArrivalsCombineIntoOneAmount() {
        let transactions = [
            tx("a", amount: "0.25", confirmations: 1, height: 103),
            tx("b", amount: "1.5", confirmations: 2, height: 102),
            tx("c", amount: "0.004", confirmations: 4, height: 100),
        ]
        let arrivals = MoneyArrivalRules.arrivals(in: transactions, baseline: 99)
        XCTAssertEqual(arrivals.count, 3)
        XCTAssertEqual(MoneyArrivalRules.total(of: arrivals), Decimal(string: "1.754"))
        // After the moment, the baseline covers them: nothing plays twice.
        let next = MoneyArrivalRules.baseline(after: arrivals, current: 99)
        XCTAssertEqual(next, 103)
        XCTAssertTrue(MoneyArrivalRules.arrivals(in: transactions, baseline: next).isEmpty)
    }

    /// The first sync, a restore or a rescan sets the baseline at the top:
    /// everything it found is seen, with no moment.
    func testFinishedSyncSetsTheBaselineWithNoArrivals() {
        let restored = [
            tx("year-old", confirmations: 50_000, height: 1_000),
            tx("yesterday", confirmations: 700, height: 2_300),
        ]
        let baseline = MoneyArrivalRules.baseline(transactions: restored, walletHeight: 3_001)
        XCTAssertEqual(baseline, 3_000)
        XCTAssertTrue(MoneyArrivalRules.arrivals(in: restored, baseline: baseline).isEmpty)
        // A payment in the next block plays.
        let next = restored + [tx("next", confirmations: 1, height: 3_001)]
        XCTAssertEqual(MoneyArrivalRules.arrivals(in: next, baseline: baseline).map(\.id), ["next"])
    }

    /// No baseline while the wallet syncs: the sync must reach the top.
    func testSyncIsDoneOnlyAtTheTop() {
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: false, walletHeight: 3_000, daemonHeight: 3_000))
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 0, daemonHeight: 3_000))
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 2_000, daemonHeight: 3_000))
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 3_000, daemonHeight: 0))
        XCTAssertTrue(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 3_000, daemonHeight: 3_000))
        XCTAssertTrue(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 2_999, daemonHeight: 3_000))
    }

    /// A baseline above the wallet's top block is from another chain.
    func testBaselineAboveTheChainIsInvalid() {
        XCTAssertTrue(MoneyArrivalRules.isBaselineValid(150, walletHeight: 200))
        XCTAssertFalse(MoneyArrivalRules.isBaselineValid(3_000_000, walletHeight: 200))
        XCTAssertTrue(MoneyArrivalRules.isBaselineValid(3_000_000, walletHeight: 0))
    }

    /// The bigger moment: an eligible wallet whose history is only the
    /// arrivals, with no payment link claim among them.
    func testFirstPaymentRules() {
        let first = tx("first", confirmations: 1, height: 101)
        XCTAssertTrue(MoneyArrivalRules.isFirstPayment(isEligible: true, transactions: [first], arrivals: [first]))
        // Restored or imported, or already used.
        XCTAssertFalse(MoneyArrivalRules.isFirstPayment(isEligible: false, transactions: [first], arrivals: [first]))
        // The history holds more than the arrivals.
        let older = tx("older", confirmations: 20, height: 90)
        XCTAssertFalse(MoneyArrivalRules.isFirstPayment(isEligible: true, transactions: [first, older], arrivals: [first]))
        // A payment link claim.
        XCTAssertFalse(MoneyArrivalRules.isFirstPayment(isEligible: true, transactions: [first], arrivals: [first], claimIds: ["first"]))
        // No arrivals.
        XCTAssertFalse(MoneyArrivalRules.isFirstPayment(isEligible: true, transactions: [], arrivals: []))
    }

    /// The hero keeps the old balance while payments wait, and while a rise
    /// waits for the history that shows its payment.
    func testHeroHoldsTheOldBalance() {
        // Payments that wait for their moment stay out.
        XCTAssertEqual(MoneyArrivalRules.heroBalance(balance: 5, pendingTotal: 2, balanceAtHistory: nil, hasPoolPayment: false), 3)
        // The balance rose before the history: hold while a payment is in the pool.
        XCTAssertEqual(MoneyArrivalRules.heroBalance(balance: 5, pendingTotal: 0, balanceAtHistory: 3, hasPoolPayment: true), 3)
        // No pool payment: the rise shows at once.
        XCTAssertEqual(MoneyArrivalRules.heroBalance(balance: 5, pendingTotal: 0, balanceAtHistory: 3, hasPoolPayment: false), 5)
        // A send shows at once.
        XCTAssertEqual(MoneyArrivalRules.heroBalance(balance: 2, pendingTotal: 0, balanceAtHistory: 3, hasPoolPayment: true), 2)
        // Never below zero.
        XCTAssertEqual(MoneyArrivalRules.heroBalance(balance: 1, pendingTotal: 2, balanceAtHistory: nil, hasPoolPayment: false), 0)
    }

    /// A launch after a payment came while the app was closed. The hero
    /// keeps the old balance through the catch-up, and through the last
    /// balance and history that come after Synced. It never ticks up and
    /// back before the moment.
    func testColdLaunchCatchUpHoldsTheHeroUntilTheMoment() {
        let baseline: UInt64 = 100
        let old = tx("old", amount: "2", confirmations: 30, height: 70)
        var hold = MoneyArrivalHold()
        var balance: Decimal = 2
        var history: [MoneroTransaction] = []
        var balanceAtHistory: Decimal? = balance
        var shown: [Decimal] = []

        func hero() -> Decimal {
            let pending = MoneyArrivalRules.arrivals(in: history, baseline: baseline)
            return hold.held ?? MoneyArrivalRules.heroBalance(
                balance: balance,
                pendingTotal: MoneyArrivalRules.total(of: pending),
                balanceAtHistory: balanceAtHistory,
                hasPoolPayment: MoneyArrivalRules.hasPoolPayment(in: history)
            )
        }
        // The kit publishes a balance before the history of the same scan.
        func scanned(balance newBalance: Decimal, history newHistory: [MoneroTransaction]) {
            balance = newBalance
            shown.append(hero())
            history = newHistory
            balanceAtHistory = balance
            hold.historyChanged()
            shown.append(hero())
        }

        // Launch: the stored balance, while the wallet connects.
        shown.append(hero())
        hold.syncMoved(from: .waiting, to: .syncing, shown: hero(), canHold: true)
        XCTAssertEqual(hold.held, 2)
        // A chunk of blocks finds the payment.
        scanned(balance: Decimal(string: "3.5")!, history: [tx("new", amount: "1.5", confirmations: 2, height: 103), old])
        XCTAssertEqual(hold.held, 2, "A history while the wallet syncs keeps the hold")
        // Synced comes before the last balance and history.
        hold.syncMoved(from: .syncing, to: .synced, shown: hero(), canHold: true)
        XCTAssertTrue(hold.awaitsHistory)
        shown.append(hero())
        scanned(balance: Decimal(string: "3.5")!, history: [tx("new", amount: "1.5", confirmations: 3, height: 103), old])

        XCTAssertNil(hold.held, "The history after Synced ends the hold")
        XCTAssertEqual(Set(shown), [2], "The hero showed only the old balance")
        // The moment: +1.5 from the balance on screen.
        let arrivals = MoneyArrivalRules.arrivals(in: history, baseline: baseline)
        XCTAssertEqual(MoneyArrivalRules.total(of: arrivals), Decimal(string: "1.5"))
        XCTAssertEqual(hero(), 2)
    }

    /// The hero's value, as the wallet home computes it.
    private func hero(
        _ hold: MoneyArrivalHold,
        balance: Decimal,
        history: [MoneroTransaction],
        baseline: UInt64,
        balanceAtHistory: Decimal?
    ) -> Decimal {
        let pending = MoneyArrivalRules.arrivals(in: history, baseline: baseline)
        return hold.held ?? MoneyArrivalRules.heroBalance(
            balance: balance,
            pendingTotal: MoneyArrivalRules.total(of: pending),
            balanceAtHistory: balanceAtHistory,
            hasPoolPayment: MoneyArrivalRules.hasPoolPayment(in: history)
        )
    }

    /// A payment that the pool never showed, in a new block while Synced.
    /// The new height comes first, then the balance, then the history. The
    /// hero holds until the history, and the moment plays from the old
    /// balance.
    func testNewBlockWhileSyncedHoldsTheHeroUntilItsHistory() {
        let baseline: UInt64 = 200
        let old = tx("old", amount: "2", confirmations: 30, height: 170)
        var hold = MoneyArrivalHold()
        var balance: Decimal = 2
        var history = [old]
        var balanceAtHistory: Decimal? = balance
        var shown: [Decimal] = []
        func shownNow() -> Decimal {
            hero(hold, balance: balance, history: history, baseline: baseline, balanceAtHistory: balanceAtHistory)
        }

        shown.append(shownNow())
        // The height goes up.
        hold.blockAdded(shown: shownNow(), canHold: true)
        XCTAssertEqual(hold.held, 2)
        let firstWait = hold.historyWait
        XCTAssertNotNil(firstWait)
        // The balance comes before the history.
        balance = Decimal(string: "2.75")!
        shown.append(shownNow())
        // A second block before the history: the same hold, a new 3 s wait.
        hold.blockAdded(shown: shownNow(), canHold: true)
        XCTAssertEqual(hold.held, 2)
        XCTAssertNotEqual(hold.historyWait, firstWait)
        // The history ends the hold.
        history = [tx("new", amount: "0.75", confirmations: 1, height: 201), old]
        balanceAtHistory = balance
        hold.historyChanged()
        shown.append(shownNow())

        XCTAssertNil(hold.held)
        XCTAssertNil(hold.historyWait)
        XCTAssertEqual(Set(shown), [2], "The hero showed only the old balance")
        let arrivals = MoneyArrivalRules.arrivals(in: history, baseline: baseline)
        XCTAssertEqual(MoneyArrivalRules.total(of: arrivals), Decimal(string: "0.75"))

        // No baseline, or a moment plays: no hold.
        var none = MoneyArrivalHold()
        none.blockAdded(shown: 2, canHold: false)
        XCTAssertNil(none.held)
        XCTAssertNil(none.historyWait)
    }

    /// A block mines a payment that was in the pool. The balance lands
    /// about 100 ms before the history, which keeps the same ids and only
    /// confirms the payment. The trigger sees that history (its row states
    /// change), so the hold ends there and not at the 3 s fallback.
    func testHoldEndsAtAHistoryThatOnlyConfirmsAPoolPayment() {
        let baseline: UInt64 = 200
        let old = tx("old", amount: "2", confirmations: 30, height: 170)
        let pool = tx("p", amount: "0.5", confirmations: 0, height: nil, status: .pending)
        let mined = tx("p", amount: "0.5", confirmations: 1, height: 201)
        var hold = MoneyArrivalHold()

        // The height goes up: hold at the shown 2.
        hold.blockAdded(shown: 2, canHold: true)
        // The balance lands first.
        let balance = Decimal(string: "2.5")!
        XCTAssertEqual(hero(hold, balance: balance, history: [pool, old], baseline: baseline, balanceAtHistory: 2), 2)
        // Then the history: the same ids, so == sees no change; the arrival
        // states that the trigger watches do.
        XCTAssertEqual([pool, old], [mined, old])
        XCTAssertNotEqual([pool, old].map(\.arrivalState), [mined, old].map(\.arrivalState))
        hold.historyChanged()

        XCTAssertNil(hold.held)
        XCTAssertNil(hold.historyWait, "No 3 s fallback waits")
        XCTAssertEqual(hero(hold, balance: balance, history: [mined, old], baseline: baseline, balanceAtHistory: balance), 2)
        XCTAssertEqual(MoneyArrivalRules.arrivals(in: [mined, old], baseline: baseline).map(\.id), ["p"])
    }

    /// A reopen: the kit has no height yet, and its first history holds no
    /// mined payment (only a pool payment, so no chain top). The stored
    /// baseline stays, no new one is written before the sync is done, and
    /// the old payments do not play again as one moment.
    func testReopenKeepsTheBaselineWhenTheFirstHistoryHasNoMinedPayment() {
        let baseline: UInt64 = 200
        let old = [tx("a", amount: "1", confirmations: 60, height: 150), tx("b", amount: "2", confirmations: 20, height: 190)]
        let pool = tx("p", amount: "0.5", confirmations: 0, height: nil, status: .pending)

        // No height yet, and a history with no mined payment.
        XCTAssertTrue(MoneyArrivalRules.isBaselineValid(baseline, walletHeight: 0))
        XCTAssertTrue(MoneyArrivalRules.arrivals(in: [pool], baseline: baseline).isEmpty)
        // The trigger writes a baseline only when none is valid and the sync
        // is done. With no height, the sync is never done.
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: false, walletHeight: 0, daemonHeight: 0))
        XCTAssertFalse(MoneyArrivalRules.isSyncDone(isSynced: true, walletHeight: 0, daemonHeight: 210))
        // A written baseline is the chain top, not 0, also with no mined payment.
        XCTAssertEqual(MoneyArrivalRules.baseline(transactions: [pool], walletHeight: 211), 210)
        // The stored height comes back, then the whole history: no moment.
        XCTAssertTrue(MoneyArrivalRules.isBaselineValid(baseline, walletHeight: 201))
        XCTAssertTrue(MoneyArrivalRules.arrivals(in: old + [pool], baseline: baseline).isEmpty)
        // A block mines the pool payment: one moment, for it alone.
        let mined = tx("p", amount: "0.5", confirmations: 1, height: 205)
        XCTAssertEqual(MoneyArrivalRules.arrivals(in: old + [mined], baseline: baseline).map(\.id), ["p"])
    }

    /// A short catch-up (Connecting, then Synced) holds from Synced. A
    /// wallet with no baseline (its first sync) never holds. A moment, a
    /// new session or the 3 s timeout ends a hold.
    func testCatchUpHoldRules() {
        var hold = MoneyArrivalHold()
        hold.syncMoved(from: .waiting, to: .synced, shown: 2, canHold: true)
        XCTAssertEqual(hold.held, 2)
        XCTAssertTrue(hold.awaitsHistory)
        // Synced again at a new block: no new hold.
        hold.end()
        hold.syncMoved(from: .synced, to: .synced, shown: 5, canHold: true)
        XCTAssertNil(hold.held)
        // No baseline, or a moment plays.
        hold.syncMoved(from: .waiting, to: .syncing, shown: 2, canHold: false)
        XCTAssertNil(hold.held)
        // Connecting or a failure keeps a hold; a history before Synced too.
        hold.syncMoved(from: .waiting, to: .syncing, shown: 2, canHold: true)
        hold.syncMoved(from: .syncing, to: .waiting, shown: 9, canHold: true)
        hold.historyChanged()
        XCTAssertEqual(hold.held, 2)
        XCTAssertFalse(hold.awaitsHistory)
        // Nothing scans while the wallet connects: no hold yet.
        var connecting = MoneyArrivalHold()
        connecting.syncMoved(from: .waiting, to: .waiting, shown: 0, canHold: true)
        XCTAssertNil(connecting.held)
    }

    func testPoolPaymentIsAnIncomingPaymentWithNoBlock() {
        XCTAssertTrue(MoneyArrivalRules.hasPoolPayment(in: [tx("p", confirmations: 0, height: nil, status: .pending)]))
        XCTAssertFalse(MoneyArrivalRules.hasPoolPayment(in: [tx("p", confirmations: 0, height: nil, status: .pending)], excluding: ["p"]))
        XCTAssertFalse(MoneyArrivalRules.hasPoolPayment(in: [tx("s", .outgoing, confirmations: 0, height: nil, status: .pending)]))
        XCTAssertFalse(MoneyArrivalRules.hasPoolPayment(in: [tx("m", confirmations: 1, height: 10)]))
    }

    /// Per wallet and per network; a rescan forgets the baseline; the
    /// first-payment flag is set by Create Wallet and used once.
    func testStoreKeepsBaselinePerWalletAndNetwork() {
        let defaults = UserDefaults(suiteName: "MotionMomentsTests")!
        defaults.removePersistentDomain(forName: "MotionMomentsTests")
        let store = MoneyArrivalStore(defaults: defaults)
        let wallet = UUID()
        let other = UUID()

        XCTAssertNil(store.baseline(walletId: wallet, network: "mainnet"))
        store.setBaseline(3_000, walletId: wallet, network: "mainnet")
        XCTAssertEqual(store.baseline(walletId: wallet, network: "mainnet"), 3_000)
        XCTAssertNil(store.baseline(walletId: wallet, network: "testnet"))
        XCTAssertNil(store.baseline(walletId: other, network: "mainnet"))
        store.forgetBaseline(walletId: wallet, network: "mainnet")
        XCTAssertNil(store.baseline(walletId: wallet, network: "mainnet"))

        XCTAssertFalse(store.isFirstPaymentEligible(walletId: wallet))
        store.markFirstPaymentEligible(walletId: wallet)
        XCTAssertTrue(store.isFirstPaymentEligible(walletId: wallet))
        XCTAssertFalse(store.isFirstPaymentEligible(walletId: other))
        store.firstPaymentUsed(walletId: wallet)
        XCTAssertFalse(store.isFirstPaymentEligible(walletId: wallet))
        defaults.removePersistentDomain(forName: "MotionMomentsTests")
    }

    // MARK: - Confirmation ring

    func testRingFillsOneTenthPerConfirmation() {
        XCTAssertEqual(ConfirmationRing.state(confirmations: 0, isFailed: false, isPending: true), .filling(0))
        XCTAssertEqual(ConfirmationRing.state(confirmations: 1, isFailed: false, isPending: false), .filling(0.1))
        XCTAssertEqual(ConfirmationRing.state(confirmations: 9, isFailed: false, isPending: false), .filling(0.9))
        XCTAssertEqual(ConfirmationRing.state(confirmations: 10, isFailed: false, isPending: false), .confirmed)
        XCTAssertEqual(ConfirmationRing.state(confirmations: 250, isFailed: false, isPending: false), .confirmed)
    }

    func testRingHiddenWhenFailedOrLoading() {
        XCTAssertEqual(ConfirmationRing.state(confirmations: 3, isFailed: true, isPending: false), .hidden)
        XCTAssertEqual(ConfirmationRing.state(confirmations: nil, isFailed: false, isPending: false), .hidden)
        // A pool transaction with no count yet: an empty ring.
        XCTAssertEqual(ConfirmationRing.state(confirmations: nil, isFailed: false, isPending: true), .filling(0))
    }

    func testRingSpokenProgressForVoiceOver() {
        XCTAssertEqual(ConfirmationRing.spokenProgress(of: tx("a", confirmations: 3, height: 10)), "3 of 10 confirmations")
        XCTAssertNil(ConfirmationRing.spokenProgress(of: tx("b", confirmations: 10, height: 10)))
        XCTAssertNil(ConfirmationRing.spokenProgress(of: tx("c", confirmations: 3, height: 10, status: .failed)))
    }

    // MARK: - Sent check

    /// The check's corner falls where the mockup's does (17 pt short leg,
    /// 45 pt long leg).
    func testCheckCornerFraction() {
        let short = hypot(17.0, 17.0)
        let long = hypot(31.0, 33.0)
        XCTAssertEqual(Double(SendCheckShape.cornerFraction), short / (short + long), accuracy: 0.0001)
    }
}
