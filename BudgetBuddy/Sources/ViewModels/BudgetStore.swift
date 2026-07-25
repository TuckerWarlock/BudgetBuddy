import Foundation

/// Outcome of reading a single persisted key: distinguishes "nothing saved yet"
/// from "saved data exists but couldn't be decoded" so callers don't treat a
/// corrupt blob the same as a fresh install.
enum LoadOutcome: Equatable {
    case empty
    case loaded
    case failed
    /// A `.corrupt` backup was decoded element-by-element and only some
    /// entries were readable; `recovered` of `total` made it into the live
    /// array (already persisted to the primary key), and the backup holding
    /// the rest is deliberately retained -- not deleted -- until the user
    /// resolves it via `recover(_:)` (try again) or `discardCorruptData(for:)`
    /// (give up on the remainder). Reconstructed at `load()` time from a
    /// persisted marker so a relaunch doesn't let the stale-backup sweep
    /// delete a backup that's still pending a decision.
    case partiallyRecovered(recovered: Int, total: Int)

    /// True for `.failed` and `.partiallyRecovered`: either way, a `.corrupt`
    /// backup exists and is waiting on the user, as opposed to `.empty`/`.loaded`
    /// where there is nothing left to resolve.
    var isMidRecovery: Bool {
        switch self {
        case .failed, .partiallyRecovered: return true
        case .empty, .loaded: return false
        }
    }
}

/// A persisted dataset that can fail to decode and be recovered from its `.corrupt` backup.
enum RecoverableDataset: CaseIterable, Hashable {
    case categories
    case transactions

    var displayName: String {
        switch self {
        case .categories: return "Categories"
        case .transactions: return "Transactions"
        }
    }
}

/// Result of attempting to recover a dataset from its `.corrupt` backup.
enum RecoveryResult: Equatable {
    case success
    /// The backup decoded only partially: `recovered` of `total` entries were
    /// individually readable, the rest were dropped. Reached via the
    /// element-by-element fallback in `recover(_:)`, which only runs after a
    /// strict whole-array decode has already failed, so `recovered` is always
    /// less than `total` in practice.
    case partial(recovered: Int, total: Int)
    case decodeFailure
}

/// Per-key load outcome, so the UI can tell which dataset(s) need attention
/// rather than collapsing every key into a single boolean.
struct LoadStatus: Equatable {
    var categories: LoadOutcome
    var transactions: LoadOutcome

    /// Strictly `.failed` datasets -- nothing usable has been loaded for them.
    var failedDatasets: [RecoverableDataset] {
        RecoverableDataset.allCases.filter { outcome(for: $0) == .failed }
    }

    var hasFailure: Bool {
        !failedDatasets.isEmpty
    }

    /// `.failed` and `.partiallyRecovered` datasets -- anything with a
    /// `.corrupt` backup still waiting on the user, whether or not something
    /// usable has already been loaded. This is deliberately broader than
    /// `failedDatasets`/`hasFailure`: a partial recovery is not a load error
    /// (something real did load), but it must not be treated as fully
    /// resolved until the user acknowledges the entries that were dropped.
    var unresolvedDatasets: [RecoverableDataset] {
        RecoverableDataset.allCases.filter { outcome(for: $0).isMidRecovery }
    }

    var needsAttention: Bool {
        !unresolvedDatasets.isEmpty
    }

    func outcome(for dataset: RecoverableDataset) -> LoadOutcome {
        switch dataset {
        case .categories: return categories
        case .transactions: return transactions
        }
    }
}

/// Decodes a single array element that might individually fail, without ever
/// leaving JSONDecoder. This is what makes the element-by-element recovery
/// fallback in `recover(_:)` safe for money fields: routing a failed element
/// through JSONSerialization to isolate it would parse every JSON number
/// (including the ones that were perfectly fine) into a Double-backed
/// NSNumber before Decimal ever saw them, silently corrupting exact values
/// (e.g. 1800.10 -> 1800.0999999999999). Decoding stays entirely inside
/// JSONDecoder here, so Decimal parsing stays exact for every entry that
/// does decode.
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

// Not @MainActor: tried, but it cascades into churn -- every synchronous test
// in BudgetStoreTests.swift calls BudgetStore APIs from a nonisolated context
// and would need to become async (or the whole test class @MainActor, forcing
// XCTest's async test machinery throughout). Deferred until either happens
// deliberately; harmless under SWIFT_VERSION: 5.0, but flagged here as the
// first thing to break if this project ever moves to Swift 6 strict
// concurrency checking.
final class BudgetStore: ObservableObject {
    @Published private(set) var categories: [BudgetCategory]
    @Published private(set) var transactions: [BudgetTransaction]
    @Published private(set) var selectedMonth: Date
    /// Per-key outcome of the last load/recovery action. Resolve a `.failed` or
    /// `.partiallyRecovered` entry with `recover(_:)` or `discardCorruptData(for:)`;
    /// until one of those runs, the status (and any UI driven by it) persists
    /// across launches.
    @Published private(set) var loadStatus = LoadStatus(categories: .empty, transactions: .empty)

    /// True only for outright decode failures. Does NOT cover a partial
    /// recovery (something real did load) -- use `needsRecoveryAttention` to
    /// decide whether the recovery sheet should still be up.
    var hasLoadError: Bool { loadStatus.hasFailure }

    /// True while any dataset is `.failed` or `.partiallyRecovered`. This is
    /// the source of truth ContentView's recovery sheet is driven off of --
    /// `hasLoadError` alone would let the sheet dismiss the instant a partial
    /// recovery's dropped entries stop being a "failure," before the user has
    /// ever been told about them.
    var needsRecoveryAttention: Bool { loadStatus.needsAttention }

    private let defaults: UserDefaults
    private let seedIfEmpty: Bool
    private let categoriesKey = "budget.categories"
    private let transactionsKey = "budget.transactions"
    private let categoriesCorruptKey = "budget.categories.corrupt"
    private let transactionsCorruptKey = "budget.transactions.corrupt"
    private let categoriesPartialKey = "budget.categories.partial"
    private let transactionsPartialKey = "budget.transactions.partial"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let calendar = Calendar.current

    private static var defaultCategories: [BudgetCategory] {
        [
            BudgetCategory(name: "Housing", monthlyLimit: 1800),
            BudgetCategory(name: "Food", monthlyLimit: 600),
            BudgetCategory(name: "Transport", monthlyLimit: 400),
            BudgetCategory(name: "Fun", monthlyLimit: 300)
        ]
    }

    init(defaults: UserDefaults = .standard, seedIfEmpty: Bool = true) {
        self.defaults = defaults
        self.seedIfEmpty = seedIfEmpty
        self.categories = []
        self.transactions = []
        self.selectedMonth = BudgetStore.normalizedMonth(for: Date(), calendar: Calendar.current)

        let categoriesOutcome = load()

        // Only seed defaults when there was genuinely nothing saved. A .failed
        // outcome must never reseed: reseeding would call saveCategories() and
        // permanently overwrite the undecodable (but potentially recoverable) blob.
        if seedIfEmpty && categoriesOutcome == .empty {
            categories = Self.defaultCategories
            saveCategories()
        }
    }

    var monthlyTransactions: [BudgetTransaction] {
        transactions
            .filter { calendar.isDate($0.date, equalTo: selectedMonth, toGranularity: .month) }
            .sorted(by: { $0.date > $1.date })
    }

    var totalLimit: Decimal {
        // Monthly limits are currently static category settings, not per-month snapshots.
        categories.reduce(.zero) { $0 + $1.monthlyLimit }
    }

    var totalSpent: Decimal {
        monthlyTransactions.reduce(.zero) { $0 + $1.amount }
    }

    var remaining: Decimal {
        totalLimit - totalSpent
    }

    var isSelectedMonthCurrentMonth: Bool {
        calendar.isDate(selectedMonth, equalTo: Date(), toGranularity: .month)
    }

    func spent(for categoryID: UUID) -> Decimal {
        monthlyTransactions
            .filter { $0.categoryID == categoryID }
            .reduce(.zero) { $0 + $1.amount }
    }

    func categoryName(for categoryID: UUID) -> String {
        categories.first(where: { $0.id == categoryID })?.name ?? "Unknown"
    }

    func addCategory(name: String, monthlyLimit: Decimal) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, monthlyLimit > .zero else {
            assertionFailure("Invalid category input.")
            return
        }

        categories.append(BudgetCategory(name: trimmedName, monthlyLimit: monthlyLimit))
        categories.sort(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        saveCategories()
    }

    func addTransaction(title: String, amount: Decimal, categoryID: UUID, date: Date) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, amount > .zero else {
            assertionFailure("Invalid transaction input.")
            return
        }

        transactions.append(
            BudgetTransaction(
                title: trimmedTitle,
                amount: amount,
                categoryID: categoryID,
                date: date
            )
        )
        saveTransactions()
    }

    func selectPreviousMonth() {
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: selectedMonth) else {
            assertionFailure("Could not compute previous month.")
            return
        }
        selectedMonth = Self.normalizedMonth(for: previousMonth, calendar: calendar)
    }

    func selectNextMonth() {
        guard !isSelectedMonthCurrentMonth else {
            return
        }
        guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: selectedMonth) else {
            assertionFailure("Could not compute next month.")
            return
        }
        selectedMonth = Self.normalizedMonth(for: nextMonth, calendar: calendar)
    }

    func deleteTransaction(_ transaction: BudgetTransaction) {
        let beforeCount = transactions.count
        transactions.removeAll { $0.id == transaction.id }

        guard transactions.count < beforeCount else {
            assertionFailure("Transaction not found for deletion.")
            return
        }

        saveTransactions()
    }

    func deleteCategory(_ category: BudgetCategory) {
        guard categories.contains(where: { $0.id == category.id }) else {
            assertionFailure("Category not found for deletion.")
            return
        }

        categories.removeAll { $0.id == category.id }
        saveCategories()

        transactions.removeAll { $0.categoryID == category.id }
        saveTransactions()
    }

    // MARK: - Corrupt data recovery

    func hasRecoverableData(for dataset: RecoverableDataset) -> Bool {
        defaults.data(forKey: corruptKey(for: dataset)) != nil
    }

    /// Attempts to recover the `.corrupt` backup for `dataset`, in two stages,
    /// never leaving JSONDecoder at any point (see `Failable`):
    ///
    /// 1. A strict whole-array decode with the current model -- this can still
    ///    succeed if the failure was transient (e.g. a later app version can
    ///    read an older payload that an earlier one could not).
    /// 2. If that fails, a lenient element-by-element decode via `Failable`.
    ///    JSONDecoder fails a whole-array decode the moment any single element
    ///    is unreadable, so one malformed entry can poison an otherwise-good
    ///    backup; decoding element-by-element recovers everything else,
    ///    mirroring the Decimal-then-Double leniency already in
    ///    BudgetCategory/BudgetTransaction's `init(from:)`.
    ///
    /// On full success (either stage), in-memory state is replaced with what
    /// was read, persisted via the normal save path, the backup is deleted,
    /// and the status is cleared to `.loaded`. On a partial success, the
    /// recovered subset is applied and persisted the same way, but the backup
    /// is deliberately *retained* -- it's the only copy of the entries that
    /// were dropped -- and the status becomes `.partiallyRecovered`, which
    /// `load()` reconstructs on every subsequent launch until the user
    /// resolves it. On total failure, the backup and status are left
    /// untouched so the caller can try again or discard it.
    @discardableResult
    func recover(_ dataset: RecoverableDataset) -> RecoveryResult {
        guard let data = defaults.data(forKey: corruptKey(for: dataset)) else {
            assertionFailure("No recoverable backup present for \(dataset).")
            return .decodeFailure
        }

        switch dataset {
        case .categories:
            return recoverCategories(from: data)
        case .transactions:
            return recoverTransactions(from: data)
        }
    }

    private func recoverCategories(from data: Data) -> RecoveryResult {
        if let recovered = try? decoder.decode([BudgetCategory].self, from: data) {
            categories = recovered
            saveCategories()
            finishRecovery(for: .categories)
            return .success
        }

        guard let wrapped = try? decoder.decode([Failable<BudgetCategory>].self, from: data), !wrapped.isEmpty else {
            return .decodeFailure
        }

        let recovered = wrapped.compactMap(\.value)
        guard !recovered.isEmpty else {
            return .decodeFailure
        }

        categories = recovered
        saveCategories()

        guard recovered.count != wrapped.count else {
            finishRecovery(for: .categories)
            return .success
        }

        setPartialMarker(recovered: recovered.count, total: wrapped.count, for: .categories)
        setOutcome(.partiallyRecovered(recovered: recovered.count, total: wrapped.count), for: .categories)
        return .partial(recovered: recovered.count, total: wrapped.count)
    }

    private func recoverTransactions(from data: Data) -> RecoveryResult {
        if let recovered = try? decoder.decode([BudgetTransaction].self, from: data) {
            transactions = recovered
            saveTransactions()
            finishRecovery(for: .transactions)
            return .success
        }

        guard let wrapped = try? decoder.decode([Failable<BudgetTransaction>].self, from: data), !wrapped.isEmpty else {
            return .decodeFailure
        }

        let recovered = wrapped.compactMap(\.value)
        guard !recovered.isEmpty else {
            return .decodeFailure
        }

        transactions = recovered
        saveTransactions()

        guard recovered.count != wrapped.count else {
            finishRecovery(for: .transactions)
            return .success
        }

        setPartialMarker(recovered: recovered.count, total: wrapped.count, for: .transactions)
        setOutcome(.partiallyRecovered(recovered: recovered.count, total: wrapped.count), for: .transactions)
        return .partial(recovered: recovered.count, total: wrapped.count)
    }

    private func finishRecovery(for dataset: RecoverableDataset) {
        defaults.removeObject(forKey: corruptKey(for: dataset))
        clearPartialMarker(for: dataset)
        setOutcome(.loaded, for: dataset)
    }

    /// Resolves `dataset`, however it currently needs resolving:
    ///
    /// - `.partiallyRecovered`: the user is giving up on just the still-unread
    ///   remainder. The already-recovered entries are the correct, final
    ///   state and must not be touched -- only the backup and its marker are
    ///   cleared. See `discardPartialRecoveryRemainder(for:)`.
    /// - anything else (in practice, `.failed`): nothing usable exists yet,
    ///   so this resets the dataset to what a fresh install would look like.
    ///   See `discardAndReset(_:)`.
    func discardCorruptData(for dataset: RecoverableDataset) {
        if case .partiallyRecovered = loadStatus.outcome(for: dataset) {
            discardPartialRecoveryRemainder(for: dataset)
        } else {
            discardAndReset(dataset)
        }
    }

    /// Gives up on the still-unrecovered remainder of a partial recovery.
    /// Unlike `discardAndReset(_:)`, this must not touch the live array or
    /// primary key -- they already hold the correct, final state (the
    /// entries that did recover) -- only the backup and partial marker (the
    /// record of "something was dropped") are cleared.
    private func discardPartialRecoveryRemainder(for dataset: RecoverableDataset) {
        defaults.removeObject(forKey: corruptKey(for: dataset))
        clearPartialMarker(for: dataset)
        setOutcome(.loaded, for: dataset)
    }

    /// Gives up on recovering `dataset` entirely: deletes the `.corrupt`
    /// backup and the (still-undecodable) primary key, and clears the failed
    /// status so the alert doesn't re-fire on the next launch.
    ///
    /// For categories specifically, leaving the in-memory array empty for the
    /// rest of the session would contradict what a relaunch produces: a fresh
    /// `init` over an empty primary key reseeds the defaults whenever
    /// `seedIfEmpty` is set, so this does the same inline rather than making
    /// the user relaunch to get back to a usable state. Every remaining
    /// transaction also now references a category ID that's gone (discarded
    /// outright, or replaced by a freshly reseeded category with a new UUID),
    /// so they're cascaded away too, the same way `deleteCategory` cascades --
    /// unless transactions are themselves mid-recovery (`.failed` or
    /// `.partiallyRecovered`), in which case that dataset's backup is an
    /// independent, unresolved concern this call must not touch. A
    /// `.partiallyRecovered` transactions dataset still has its
    /// already-recovered *live* entries cascaded (they're just as orphaned as
    /// any other live transaction), but its retained backup, partial marker,
    /// and status are left alone -- only the live array and primary key change.
    private func discardAndReset(_ dataset: RecoverableDataset) {
        defaults.removeObject(forKey: corruptKey(for: dataset))
        defaults.removeObject(forKey: primaryKey(for: dataset))
        clearPartialMarker(for: dataset)

        switch dataset {
        case .categories:
            if seedIfEmpty {
                categories = Self.defaultCategories
                saveCategories()
                setOutcome(.loaded, for: .categories)
            } else {
                categories = []
                setOutcome(.empty, for: .categories)
            }

            switch loadStatus.transactions {
            case .failed:
                // Independently pending its own recovery decision, and a
                // failed decode never populates the live array -- nothing to
                // cascade, nothing to touch.
                break

            case .partiallyRecovered:
                // Independently pending its own recovery decision -- leave
                // that status, its backup, and its partial marker alone. But
                // the live entries that did recover are just as orphaned by
                // this categories reset as any other live transaction.
                if !transactions.isEmpty {
                    transactions = []
                    saveTransactions()
                }

            case .empty, .loaded:
                // Only cascade (and only report .loaded) when there was
                // actually something to cascade -- otherwise this would
                // fabricate a .loaded status and write an empty array to a
                // key that genuinely never had one.
                if !transactions.isEmpty {
                    transactions = []
                    saveTransactions()
                    setOutcome(.loaded, for: .transactions)
                }
            }

        case .transactions:
            transactions = []
            setOutcome(.empty, for: .transactions)
        }
    }

    private func corruptKey(for dataset: RecoverableDataset) -> String {
        switch dataset {
        case .categories: return categoriesCorruptKey
        case .transactions: return transactionsCorruptKey
        }
    }

    private func primaryKey(for dataset: RecoverableDataset) -> String {
        switch dataset {
        case .categories: return categoriesKey
        case .transactions: return transactionsKey
        }
    }

    private func partialKey(for dataset: RecoverableDataset) -> String {
        switch dataset {
        case .categories: return categoriesPartialKey
        case .transactions: return transactionsPartialKey
        }
    }

    private func setOutcome(_ outcome: LoadOutcome, for dataset: RecoverableDataset) {
        switch dataset {
        case .categories: loadStatus.categories = outcome
        case .transactions: loadStatus.transactions = outcome
        }
    }

    /// Persists the "some entries were dropped" fact for `dataset` as a plain
    /// property-list dictionary (no JSON/Codable needed for two integers).
    /// This is what lets `load()` tell a *retained* backup (pending the
    /// user's decision) apart from a *stale* one (safe to sweep) purely from
    /// what's in UserDefaults, since both look identical otherwise: a
    /// decodable primary key plus a `.corrupt` key sitting next to it.
    private func setPartialMarker(recovered: Int, total: Int, for dataset: RecoverableDataset) {
        defaults.set(["recovered": recovered, "total": total], forKey: partialKey(for: dataset))
    }

    private func clearPartialMarker(for dataset: RecoverableDataset) {
        defaults.removeObject(forKey: partialKey(for: dataset))
    }

    private func partialMarker(for dataset: RecoverableDataset) -> (recovered: Int, total: Int)? {
        guard let marker = defaults.dictionary(forKey: partialKey(for: dataset)),
              let recovered = marker["recovered"] as? Int,
              let total = marker["total"] as? Int else {
            return nil
        }
        return (recovered, total)
    }

    // MARK: - Persistence

    /// Loads both persisted collections and returns the categories outcome (the
    /// only one init needs, to decide whether to reseed). Also updates `loadStatus`
    /// with the per-key outcome of this load.
    @discardableResult
    private func load() -> LoadOutcome {
        let categoriesOutcome = loadCategories()
        let transactionsOutcome = loadTransactions()
        loadStatus = LoadStatus(categories: categoriesOutcome, transactions: transactionsOutcome)
        return categoriesOutcome
    }

    private func loadCategories() -> LoadOutcome {
        guard let data = defaults.data(forKey: categoriesKey), !data.isEmpty else {
            clearStaleBackup(for: .categories)
            return .empty
        }

        do {
            categories = try decoder.decode([BudgetCategory].self, from: data)
            if let marker = partialMarker(for: .categories) {
                // A prior partial recovery is still pending the user's
                // decision; the backup holding the dropped entries must
                // survive until they explicitly resolve it, not be swept
                // just because the already-recovered subset decodes fine.
                return .partiallyRecovered(recovered: marker.recovered, total: marker.total)
            }
            clearStaleBackup(for: .categories)
            return .loaded
        } catch {
            NSLog("Failed to decode categories: \(error.localizedDescription)")
            backUpCorruptData(data, forKey: categoriesCorruptKey)
            return .failed
        }
    }

    private func loadTransactions() -> LoadOutcome {
        guard let data = defaults.data(forKey: transactionsKey), !data.isEmpty else {
            clearStaleBackup(for: .transactions)
            return .empty
        }

        do {
            transactions = try decoder.decode([BudgetTransaction].self, from: data)
            if let marker = partialMarker(for: .transactions) {
                return .partiallyRecovered(recovered: marker.recovered, total: marker.total)
            }
            clearStaleBackup(for: .transactions)
            return .loaded
        } catch {
            NSLog("Failed to decode transactions: \(error.localizedDescription)")
            backUpCorruptData(data, forKey: transactionsCorruptKey)
            return .failed
        }
    }

    /// Copies undecodable bytes aside so they survive a later saveCategories()/
    /// saveTransactions() call, which would otherwise overwrite the original key
    /// with fresh (empty or reseeded) state.
    private func backUpCorruptData(_ data: Data, forKey key: String) {
        defaults.set(data, forKey: key)
    }

    /// Deletes a `.corrupt` backup that's no longer needed because the primary
    /// key just loaded successfully (or is genuinely empty) *and* there is no
    /// pending partial-recovery marker for it. recover(_:) and
    /// discardCorruptData(for:) are the only other things that ever delete a
    /// backup, and both only run while the recovery sheet is presented for
    /// that dataset (`.failed` or `.partiallyRecovered`) -- so a backup left
    /// behind by an app version that couldn't decode a payload a later
    /// version now reads fine, and isn't pending anything else, would
    /// otherwise leak in UserDefaults forever.
    private func clearStaleBackup(for dataset: RecoverableDataset) {
        let key = corruptKey(for: dataset)
        guard defaults.data(forKey: key) != nil else {
            return
        }
        defaults.removeObject(forKey: key)
    }

    private func saveCategories() {
        do {
            let data = try encoder.encode(categories)
            defaults.set(data, forKey: categoriesKey)
        } catch {
            NSLog("Failed to encode categories: \(error.localizedDescription)")
        }
    }

    private func saveTransactions() {
        do {
            let data = try encoder.encode(transactions)
            defaults.set(data, forKey: transactionsKey)
        } catch {
            NSLog("Failed to encode transactions: \(error.localizedDescription)")
        }
    }

    private static func normalizedMonth(for date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }
}
