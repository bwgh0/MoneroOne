import Foundation
import SwiftUI

@MainActor
class WalletManager: ObservableObject {
    @Published var hasWallet: Bool = false
    @Published var isUnlocked: Bool = false
    @Published var balance: Decimal = 0
    @Published var unlockedBalance: Decimal = 0
    @Published var address: String = ""
    @Published var syncProgress: Double = 0
    @Published var syncState: SyncState = .idle

    private let keychain = KeychainStorage()

    enum SyncState: Equatable {
        case idle
        case syncing(progress: Double)
        case synced
        case error(String)
    }

    init() {
        checkForExistingWallet()
    }

    private func checkForExistingWallet() {
        hasWallet = keychain.hasSeed()
    }

    // MARK: - Wallet Creation

    func generateNewWallet() -> [String] {
        let mnemonic = generateMnemonic()
        return mnemonic
    }

    func saveWallet(mnemonic: [String], pin: String) throws {
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)
        hasWallet = true
    }

    func restoreWallet(mnemonic: [String], pin: String) throws {
        guard validateMnemonic(mnemonic) else {
            throw WalletError.invalidMnemonic
        }
        let seedPhrase = mnemonic.joined(separator: " ")
        try keychain.saveSeed(seedPhrase, pin: pin)
        hasWallet = true
    }

    // MARK: - Wallet Unlock

    func unlock(pin: String) throws {
        guard let _ = try keychain.getSeed(pin: pin) else {
            throw WalletError.invalidPin
        }
        isUnlocked = true
    }

    func lock() {
        isUnlocked = false
    }

    // MARK: - Mnemonic Generation (BIP39)

    private func generateMnemonic() -> [String] {
        // Standard BIP39 word list (first 100 words for demo - full list has 2048)
        // In production, use a proper BIP39 library
        let wordList = bip39WordList

        var mnemonic: [String] = []
        for _ in 0..<25 {  // Monero uses 25-word seeds
            let randomIndex = Int.random(in: 0..<wordList.count)
            mnemonic.append(wordList[randomIndex])
        }
        return mnemonic
    }

    private func validateMnemonic(_ mnemonic: [String]) -> Bool {
        // Monero uses 25-word seeds
        return mnemonic.count == 25 && mnemonic.allSatisfy { bip39WordList.contains($0.lowercased()) }
    }

    // MARK: - Delete Wallet

    func deleteWallet() {
        keychain.deleteSeed()
        hasWallet = false
        isUnlocked = false
        balance = 0
        unlockedBalance = 0
        address = ""
    }
}

// MARK: - Errors

enum WalletError: LocalizedError {
    case invalidMnemonic
    case invalidPin
    case saveFailed
    case notUnlocked

    var errorDescription: String? {
        switch self {
        case .invalidMnemonic: return "Invalid seed phrase"
        case .invalidPin: return "Invalid PIN"
        case .saveFailed: return "Failed to save wallet"
        case .notUnlocked: return "Wallet is locked"
        }
    }
}

// MARK: - BIP39 Word List (partial - full list has 2048 words)

private let bip39WordList: [String] = [
    "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract", "absurd", "abuse",
    "access", "accident", "account", "accuse", "achieve", "acid", "acoustic", "acquire", "across", "act",
    "action", "actor", "actress", "actual", "adapt", "add", "addict", "address", "adjust", "admit",
    "adult", "advance", "advice", "aerobic", "affair", "afford", "afraid", "again", "age", "agent",
    "agree", "ahead", "aim", "air", "airport", "aisle", "alarm", "album", "alcohol", "alert",
    "alien", "all", "alley", "allow", "almost", "alone", "alpha", "already", "also", "alter",
    "always", "amateur", "amazing", "among", "amount", "amused", "analyst", "anchor", "ancient", "anger",
    "angle", "angry", "animal", "ankle", "announce", "annual", "another", "answer", "antenna", "antique",
    "anxiety", "any", "apart", "apology", "appear", "apple", "approve", "april", "arch", "arctic",
    "area", "arena", "argue", "arm", "armed", "armor", "army", "around", "arrange", "arrest",
    "arrive", "arrow", "art", "artefact", "artist", "artwork", "ask", "aspect", "assault", "asset",
    "assist", "assume", "asthma", "athlete", "atom", "attack", "attend", "attitude", "attract", "auction",
    "audit", "august", "aunt", "author", "auto", "autumn", "average", "avocado", "avoid", "awake",
    "aware", "away", "awesome", "awful", "awkward", "axis", "baby", "bachelor", "bacon", "badge",
    "bag", "balance", "balcony", "ball", "bamboo", "banana", "banner", "bar", "barely", "bargain",
    "barrel", "base", "basic", "basket", "battle", "beach", "bean", "beauty", "because", "become",
    "beef", "before", "begin", "behave", "behind", "believe", "below", "belt", "bench", "benefit",
    "best", "betray", "better", "between", "beyond", "bicycle", "bid", "bike", "bind", "biology",
    "bird", "birth", "bitter", "black", "blade", "blame", "blanket", "blast", "bleak", "bless",
    "blind", "blood", "blossom", "blouse", "blue", "blur", "blush", "board", "boat", "body",
    "boil", "bomb", "bone", "bonus", "book", "boost", "border", "boring", "borrow", "boss",
    "bottom", "bounce", "box", "boy", "bracket", "brain", "brand", "brass", "brave", "bread",
    "breeze", "brick", "bridge", "brief", "bright", "bring", "brisk", "broccoli", "broken", "bronze",
    "broom", "brother", "brown", "brush", "bubble", "buddy", "budget", "buffalo", "build", "bulb",
    "bulk", "bullet", "bundle", "bunker", "burden", "burger", "burst", "bus", "business", "busy",
    "butter", "buyer", "buzz", "cabbage", "cabin", "cable", "cactus", "cage", "cake", "call",
    "calm", "camera", "camp", "can", "canal", "cancel", "candy", "cannon", "canoe", "canvas",
    "canyon", "capable", "capital", "captain", "car", "carbon", "card", "cargo", "carpet", "carry",
    "cart", "case", "cash", "casino", "castle", "casual", "cat", "catalog", "catch", "category",
    "cattle", "caught", "cause", "caution", "cave", "ceiling", "celery", "cement", "census", "century",
    "cereal", "certain", "chair", "chalk", "champion", "change", "chaos", "chapter", "charge", "chase",
    "chat", "cheap", "check", "cheese", "chef", "cherry", "chest", "chicken", "chief", "child",
    "chimney", "choice", "choose", "chronic", "chuckle", "chunk", "churn", "cigar", "cinnamon", "circle",
    "citizen", "city", "civil", "claim", "clap", "clarify", "claw", "clay", "clean", "clerk",
    "clever", "click", "client", "cliff", "climb", "clinic", "clip", "clock", "clog", "close",
    "cloth", "cloud", "clown", "club", "clump", "cluster", "clutch", "coach", "coast", "coconut",
    "code", "coffee", "coil", "coin", "collect", "color", "column", "combine", "come", "comfort",
    "comic", "common", "company", "concert", "conduct", "confirm", "congress", "connect", "consider", "control",
    "convince", "cook", "cool", "copper", "copy", "coral", "core", "corn", "correct", "cost",
    "cotton", "couch", "country", "couple", "course", "cousin", "cover", "coyote", "crack", "cradle",
    "craft", "cram", "crane", "crash", "crater", "crawl", "crazy", "cream", "credit", "creek",
    "crew", "cricket", "crime", "crisp", "critic", "crop", "cross", "crouch", "crowd", "crucial",
    "cruel", "cruise", "crumble", "crunch", "crush", "cry", "crystal", "cube", "culture", "cup",
    "cupboard", "curious", "current", "curtain", "curve", "cushion", "custom", "cute", "cycle", "dad",
    "damage", "damp", "dance", "danger", "daring", "dash", "daughter", "dawn", "day", "deal",
    "debate", "debris", "decade", "december", "decide", "decline", "decorate", "decrease", "deer", "defense",
    "define", "defy", "degree", "delay", "deliver", "demand", "demise", "denial", "dentist", "deny"
]
