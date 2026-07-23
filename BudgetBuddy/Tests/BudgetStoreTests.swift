import XCTest
@testable import BudgetBuddy

final class BudgetStoreTests: XCTestCase {
    private struct LegacyBudgetCategory: Codable {
        let id: UUID
        let name: String
        let monthlyLimit: Double
    }

    private struct LegacyBudgetTransaction: Codable {
        let id: UUID
        let title: String
        let amount: Double
        let categoryID: UUID
        let date: Date
    }

    private func makeIsolatedDefaults() -> (suiteName: String, defaults: UserDefaults)? {
        let suiteName = "BudgetBuddyTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return nil
        }
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults)
    }

    private func decimal(_ value: String) -> Decimal {
        guard let decimalValue = Decimal(string: value, locale: .current) else {
            XCTFail("Could not parse Decimal for \(value).")
            return .zero
        }
        return decimalValue
    }

    func testMonthlyTotalsReflectSavedTransactions() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)

        guard let category = store.categories.first else {
            XCTFail("Expected one category.")
            return
        }

        store.addTransaction(title: "Groceries", amount: 75.25, categoryID: category.id, date: Date())

        XCTAssertEqual(store.totalLimit, decimal("500"))
        XCTAssertEqual(store.totalSpent, decimal("75.25"))
        XCTAssertEqual(store.remaining, decimal("424.75"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLegacyDoublePayloadDecodesWithDecimalModel() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let categoryID = UUID()
        let categories = [
            LegacyBudgetCategory(id: categoryID, name: "Food", monthlyLimit: 600.5)
        ]
        let transactions = [
            LegacyBudgetTransaction(
                id: UUID(),
                title: "Groceries",
                amount: 90.75,
                categoryID: categoryID,
                date: Date()
            )
        ]
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(categories), forKey: "budget.categories")
        defaults.set(try? encoder.encode(transactions), forKey: "budget.transactions")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.categories.count, 1)
        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(store.categories.first?.monthlyLimit, decimal("600.5"))
        XCTAssertEqual(store.transactions.first?.amount, decimal("90.75"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPersistenceRoundTripUsingSameSuite() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let firstStore = BudgetStore(defaults: defaults, seedIfEmpty: false)
        firstStore.addCategory(name: "Food", monthlyLimit: 600)
        firstStore.addCategory(name: "Transport", monthlyLimit: 300)

        guard let foodCategory = firstStore.categories.first(where: { $0.name == "Food" }) else {
            XCTFail("Expected Food category.")
            return
        }

        firstStore.addTransaction(title: "Groceries", amount: 90, categoryID: foodCategory.id, date: Date())

        let secondStore = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(secondStore.categories.count, 2)
        XCTAssertEqual(secondStore.transactions.count, 1)
        XCTAssertEqual(secondStore.totalLimit, decimal("900"))
        XCTAssertEqual(secondStore.totalSpent, decimal("90"))
        XCTAssertEqual(secondStore.categories.map(\.name).sorted(), ["Food", "Transport"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDeleteCategoryCascadesTransactions() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)
        store.addCategory(name: "Transport", monthlyLimit: 300)

        guard let foodCategory = store.categories.first(where: { $0.name == "Food" }),
              let transportCategory = store.categories.first(where: { $0.name == "Transport" }) else {
            XCTFail("Expected both categories.")
            return
        }

        store.addTransaction(title: "Groceries", amount: 50, categoryID: foodCategory.id, date: Date())
        store.addTransaction(title: "Bus Pass", amount: 40, categoryID: transportCategory.id, date: Date())

        store.deleteCategory(foodCategory)

        XCTAssertFalse(store.categories.contains(where: { $0.id == foodCategory.id }))
        XCTAssertTrue(store.categories.contains(where: { $0.id == transportCategory.id }))
        XCTAssertFalse(store.transactions.contains(where: { $0.categoryID == foodCategory.id }))
        XCTAssertTrue(store.transactions.contains(where: { $0.categoryID == transportCategory.id }))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSpentForCategoryReturnsPerCategoryTotal() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)
        store.addCategory(name: "Fun", monthlyLimit: 200)

        guard let foodCategory = store.categories.first(where: { $0.name == "Food" }),
              let funCategory = store.categories.first(where: { $0.name == "Fun" }) else {
            XCTFail("Expected categories.")
            return
        }

        store.addTransaction(title: "Groceries", amount: 75, categoryID: foodCategory.id, date: Date())
        store.addTransaction(title: "Coffee", amount: 25, categoryID: foodCategory.id, date: Date())
        store.addTransaction(title: "Movie", amount: 30, categoryID: funCategory.id, date: Date())

        XCTAssertEqual(store.spent(for: foodCategory.id), decimal("100"))
        XCTAssertEqual(store.spent(for: funCategory.id), decimal("30"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testMonthlyTransactionsExcludePreviousMonth() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)

        guard let foodCategory = store.categories.first(where: { $0.name == "Food" }) else {
            XCTFail("Expected Food category.")
            return
        }

        let currentMonthDate = Date()
        guard let previousMonthDate = Calendar.current.date(byAdding: .month, value: -1, to: currentMonthDate) else {
            XCTFail("Could not create previous-month date.")
            return
        }

        store.addTransaction(title: "Current Groceries", amount: 60, categoryID: foodCategory.id, date: currentMonthDate)
        store.addTransaction(title: "Old Groceries", amount: 80, categoryID: foodCategory.id, date: previousMonthDate)

        XCTAssertEqual(store.monthlyTransactions.count, 1)
        XCTAssertEqual(store.monthlyTransactions.first?.title, "Current Groceries")
        XCTAssertEqual(store.totalSpent, decimal("60"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSwitchingMonthsUpdatesScopedTotalsAndTransactions() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)

        guard let foodCategory = store.categories.first(where: { $0.name == "Food" }) else {
            XCTFail("Expected Food category.")
            return
        }

        let currentMonthDate = Date()
        guard let previousMonthDate = Calendar.current.date(byAdding: .month, value: -1, to: currentMonthDate) else {
            XCTFail("Could not create previous-month date.")
            return
        }

        store.addTransaction(title: "Current Month Item", amount: 60, categoryID: foodCategory.id, date: currentMonthDate)
        store.addTransaction(title: "Previous Month Item", amount: 25, categoryID: foodCategory.id, date: previousMonthDate)

        XCTAssertEqual(store.totalSpent, decimal("60"))
        XCTAssertEqual(store.monthlyTransactions.map(\.title), ["Current Month Item"])

        store.selectPreviousMonth()
        XCTAssertEqual(store.totalSpent, decimal("25"))
        XCTAssertEqual(store.monthlyTransactions.map(\.title), ["Previous Month Item"])

        store.selectNextMonth()
        XCTAssertEqual(store.totalSpent, decimal("60"))
        XCTAssertEqual(store.monthlyTransactions.map(\.title), ["Current Month Item"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testTransactionInMonthANotVisibleInDifferentSelectedMonth() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.addCategory(name: "Food", monthlyLimit: 500)

        guard let foodCategory = store.categories.first(where: { $0.name == "Food" }) else {
            XCTFail("Expected Food category.")
            return
        }

        let monthADate = Date()
        guard let monthBDate = Calendar.current.date(byAdding: .month, value: -2, to: monthADate) else {
            XCTFail("Could not create month-B date.")
            return
        }

        store.addTransaction(title: "Month A Item", amount: 40, categoryID: foodCategory.id, date: monthADate)
        store.addTransaction(title: "Month B Item", amount: 15, categoryID: foodCategory.id, date: monthBDate)

        XCTAssertEqual(store.monthlyTransactions.map(\.title), ["Month A Item"])

        store.selectPreviousMonth()
        XCTAssertTrue(store.monthlyTransactions.isEmpty)

        store.selectPreviousMonth()
        XCTAssertEqual(store.monthlyTransactions.map(\.title), ["Month B Item"])
        XCTAssertNotEqual(store.monthlyTransactions.map(\.title), ["Month A Item"])

        defaults.removePersistentDomain(forName: suiteName)
    }
}
