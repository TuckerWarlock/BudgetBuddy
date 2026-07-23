import Foundation

/// Outcome of reading a single persisted key: distinguishes "nothing saved yet"
/// from "saved data exists but couldn't be decoded" so callers don't treat a
/// corrupt blob the same as a fresh install.
enum LoadOutcome: Equatable {
    case empty
    case loaded
    case failed
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
    case decodeFailure
}

/// Per-key load outcome, so the UI can tell which dataset(s) failed to decode
/// rather than collapsing every key into a single boolean.
struct LoadStatus: Equatable {
    var categories: LoadOutcome
    var transactions: LoadOutcome

    var failedDatasets: [RecoverableDataset] {
        RecoverableDataset.allCases.filter { outcome(for: $0) == .failed }
    }

    var hasFailure: Bool {
        !failedDatasets.isEmpty
    }

    func outcome(for dataset: RecoverableDataset) -> LoadOutcome {
        switch dataset {
        case .categories: return categories
        case .transactions: return transactions
        }
    }
}

final class BudgetStore: ObservableObject {
    @Published private(set) var categories: [BudgetCategory]
    @Published private(set) var transactions: [BudgetTransaction]
    @Published private(set) var selectedMonth: Date
    /// Per-key outcome of the last load. A `.failed` entry means the primary key held
    /// undecodable bytes that were preserved under a `.corrupt` backup key rather than
    /// being overwritten. Resolve it with `recover(_:)` or `discardCorruptData(for:)`;
    /// until one of those runs, the status (and any UI driven by it) persists across launches.
    @Published private(set) var loadStatus = LoadStatus(categories: .empty, transactions: .empty)

    var hasLoadError: Bool { loadStatus.hasFailure }

    private let defaults: UserDefaults
    private let categoriesKey = "budget.categories"
    private let transactionsKey = "budget.transactions"
    private let categoriesCorruptKey = "budget.categories.corrupt"
    private let transactionsCorruptKey = "budget.transactions.corrupt"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard, seedIfEmpty: Bool = true) {
        self.defaults = defaults
        self.categories = []
        self.transactions = []
        self.selectedMonth = BudgetStore.normalizedMonth(for: Date(), calendar: Calendar.current)

        let categoriesOutcome = load()

        // Only seed defaults when there was genuinely nothing saved. A .failed
        // outcome must never reseed: reseeding would call saveCategories() and
        // permanently overwrite the undecodable (but potentially recoverable) blob.
        if seedIfEmpty && categoriesOutcome == .empty {
            categories = [
                BudgetCategory(name: "Housing", monthlyLimit: 1800),
                BudgetCategory(name: "Food", monthlyLimit: 600),
                BudgetCategory(name: "Transport", monthlyLimit: 400),
                BudgetCategory(name: "Fun", monthlyLimit: 300)
            ]
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

    /// Attempts to decode the `.corrupt` backup for `dataset` with the current model.
    /// On success, replaces in-memory state, persists it via the normal save path,
    /// deletes the backup, and clears the failed status. On failure, leaves the
    /// backup and status untouched so the caller can try again or discard it.
    @discardableResult
    func recover(_ dataset: RecoverableDataset) -> RecoveryResult {
        guard let data = defaults.data(forKey: corruptKey(for: dataset)) else {
            assertionFailure("No recoverable backup present for \(dataset).")
            return .decodeFailure
        }

        do {
            switch dataset {
            case .categories:
                categories = try decoder.decode([BudgetCategory].self, from: data)
                saveCategories()
            case .transactions:
                transactions = try decoder.decode([BudgetTransaction].self, from: data)
                saveTransactions()
            }
        } catch {
            NSLog("Recovery failed for \(dataset.displayName): \(error.localizedDescription)")
            return .decodeFailure
        }

        defaults.removeObject(forKey: corruptKey(for: dataset))
        setOutcome(.loaded, for: dataset)
        return .success
    }

    /// Gives up on recovering `dataset`: deletes the `.corrupt` backup and the
    /// (still-undecodable) primary key, resets in-memory state to empty, and
    /// clears the failed status so the alert doesn't re-fire on the next launch.
    func discardCorruptData(for dataset: RecoverableDataset) {
        defaults.removeObject(forKey: corruptKey(for: dataset))
        defaults.removeObject(forKey: primaryKey(for: dataset))

        switch dataset {
        case .categories:
            categories = []
        case .transactions:
            transactions = []
        }

        setOutcome(.empty, for: dataset)
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

    private func setOutcome(_ outcome: LoadOutcome, for dataset: RecoverableDataset) {
        switch dataset {
        case .categories: loadStatus.categories = outcome
        case .transactions: loadStatus.transactions = outcome
        }
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
            return .empty
        }

        do {
            categories = try decoder.decode([BudgetCategory].self, from: data)
            return .loaded
        } catch {
            NSLog("Failed to decode categories: \(error.localizedDescription)")
            backUpCorruptData(data, forKey: categoriesCorruptKey)
            return .failed
        }
    }

    private func loadTransactions() -> LoadOutcome {
        guard let data = defaults.data(forKey: transactionsKey), !data.isEmpty else {
            return .empty
        }

        do {
            transactions = try decoder.decode([BudgetTransaction].self, from: data)
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
