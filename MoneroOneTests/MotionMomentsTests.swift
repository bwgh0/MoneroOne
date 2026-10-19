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
