import Foundation

final class BudgetStore: ObservableObject {
    @Published private(set) var categories: [BudgetCategory]
    @Published private(set) var transactions: [BudgetTransaction]
    @Published private(set) var selectedMonth: Date

    private let defaults: UserDefaults
    private let categoriesKey = "budget.categories"
    private let transactionsKey = "budget.transactions"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard, seedIfEmpty: Bool = true) {
        self.defaults = defaults
        self.categories = []
        self.transactions = []
        self.selectedMonth = BudgetStore.normalizedMonth(for: Date(), calendar: Calendar.current)
        load()

        if seedIfEmpty && categories.isEmpty {
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

    private func load() {
        if let categoriesData = defaults.data(forKey: categoriesKey),
           !categoriesData.isEmpty {
            do {
                categories = try decoder.decode([BudgetCategory].self, from: categoriesData)
            } catch {
                NSLog("Failed to decode categories: \(error.localizedDescription)")
            }
        }

        if let transactionsData = defaults.data(forKey: transactionsKey),
           !transactionsData.isEmpty {
            do {
                transactions = try decoder.decode([BudgetTransaction].self, from: transactionsData)
            } catch {
                NSLog("Failed to decode transactions: \(error.localizedDescription)")
            }
        }
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
