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

    func testFailedCategoriesDecodeDoesNotReseedOrOverwriteBlob() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let corruptData = Data("not valid json".utf8)
        defaults.set(corruptData, forKey: "budget.categories")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: true)

        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertTrue(store.hasLoadError)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertEqual(store.loadStatus.transactions, .empty)
        XCTAssertEqual(defaults.data(forKey: "budget.categories"), corruptData)
        XCTAssertEqual(defaults.data(forKey: "budget.categories.corrupt"), corruptData)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testLoadErrorFlagReflectsDecodeOutcome() {
        guard let failingIsolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let failingDefaults = failingIsolatedDefaults.defaults
        let failingSuiteName = failingIsolatedDefaults.suiteName

        failingDefaults.set(Data("not valid json".utf8), forKey: "budget.transactions")
        let failingStore = BudgetStore(defaults: failingDefaults, seedIfEmpty: false)
        XCTAssertTrue(failingStore.hasLoadError)
        XCTAssertEqual(failingStore.loadStatus.transactions, .failed)
        XCTAssertEqual(failingStore.loadStatus.categories, .empty)
        XCTAssertEqual(failingStore.loadStatus.failedDatasets, [.transactions])
        failingDefaults.removePersistentDomain(forName: failingSuiteName)

        guard let cleanIsolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let cleanDefaults = cleanIsolatedDefaults.defaults
        let cleanSuiteName = cleanIsolatedDefaults.suiteName

        let cleanStore = BudgetStore(defaults: cleanDefaults, seedIfEmpty: false)
        XCTAssertFalse(cleanStore.hasLoadError)
        XCTAssertTrue(cleanStore.loadStatus.failedDatasets.isEmpty)
        cleanDefaults.removePersistentDomain(forName: cleanSuiteName)
    }

    func testRecoverCategoriesSucceedsWhenBackupDecodes() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let recoverableCategories = [BudgetCategory(name: "Food", monthlyLimit: 500)]
        guard let corruptBackup = try? JSONEncoder().encode(recoverableCategories) else {
            XCTFail("Could not encode recoverable categories.")
            return
        }
        defaults.set(corruptBackup, forKey: "budget.categories.corrupt")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertTrue(store.hasRecoverableData(for: .categories))

        let result = store.recover(.categories)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(store.categories, recoverableCategories)
        XCTAssertEqual(store.loadStatus.categories, .loaded)
        XCTAssertFalse(store.hasLoadError)
        XCTAssertFalse(store.hasRecoverableData(for: .categories))
        XCTAssertNil(defaults.data(forKey: "budget.categories.corrupt"))

        guard let primaryData = defaults.data(forKey: "budget.categories"),
              let decodedPrimary = try? JSONDecoder().decode([BudgetCategory].self, from: primaryData) else {
            XCTFail("Expected recovered categories to be persisted to the primary key.")
            return
        }
        XCTAssertEqual(decodedPrimary, recoverableCategories)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRecoverCategoriesFailsWhenBackupStillUndecodable() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        let corruptData = Data("not valid json".utf8)
        defaults.set(corruptData, forKey: "budget.categories")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)

        let result = store.recover(.categories)

        XCTAssertEqual(result, .decodeFailure)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertTrue(store.hasLoadError)
        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "budget.categories.corrupt"), corruptData)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardCorruptCategoriesRemovesBackupAndClearsStatusWithoutRestoring() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)

        store.discardCorruptData(for: .categories)

        XCTAssertEqual(store.loadStatus.categories, .empty)
        XCTAssertFalse(store.hasLoadError)
        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertNil(defaults.data(forKey: "budget.categories.corrupt"))
        XCTAssertNil(defaults.data(forKey: "budget.categories"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRecoveringCategoriesDoesNotAffectTransactionsStatus() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")

        let transaction = BudgetTransaction(title: "Coffee", amount: 5, categoryID: UUID(), date: Date())
        guard let transactionsData = try? JSONEncoder().encode([transaction]) else {
            XCTFail("Could not encode transactions.")
            return
        }
        defaults.set(transactionsData, forKey: "budget.transactions")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertEqual(store.loadStatus.transactions, .loaded)
        XCTAssertEqual(store.transactions.count, 1)

        let recoverableCategories = [BudgetCategory(name: "Food", monthlyLimit: 300)]
        guard let recoverableData = try? JSONEncoder().encode(recoverableCategories) else {
            XCTFail("Could not encode recoverable categories.")
            return
        }
        defaults.set(recoverableData, forKey: "budget.categories.corrupt")

        let result = store.recover(.categories)

        XCTAssertEqual(result, .success)
        XCTAssertEqual(store.loadStatus.categories, .loaded)
        XCTAssertEqual(store.loadStatus.transactions, .loaded)
        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(store.transactions.first?.title, "Coffee")

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testResolvedLoadStatusDoesNotReappearOnNextInit() {
        guard let discardIsolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let discardDefaults = discardIsolatedDefaults.defaults
        let discardSuiteName = discardIsolatedDefaults.suiteName

        discardDefaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let discardFirstStore = BudgetStore(defaults: discardDefaults, seedIfEmpty: false)
        XCTAssertTrue(discardFirstStore.hasLoadError)
        discardFirstStore.discardCorruptData(for: .categories)
        XCTAssertFalse(discardFirstStore.hasLoadError)

        let discardSecondStore = BudgetStore(defaults: discardDefaults, seedIfEmpty: false)
        XCTAssertFalse(discardSecondStore.hasLoadError)
        XCTAssertEqual(discardSecondStore.loadStatus.categories, .empty)
        discardDefaults.removePersistentDomain(forName: discardSuiteName)

        guard let restoreIsolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let restoreDefaults = restoreIsolatedDefaults.defaults
        let restoreSuiteName = restoreIsolatedDefaults.suiteName

        restoreDefaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let restoreFirstStore = BudgetStore(defaults: restoreDefaults, seedIfEmpty: false)
        XCTAssertTrue(restoreFirstStore.hasLoadError)

        guard let recoverableData = try? JSONEncoder().encode([BudgetCategory(name: "Food", monthlyLimit: 400)]) else {
            XCTFail("Could not encode recoverable categories.")
            return
        }
        restoreDefaults.set(recoverableData, forKey: "budget.categories.corrupt")
        XCTAssertEqual(restoreFirstStore.recover(.categories), .success)
        XCTAssertFalse(restoreFirstStore.hasLoadError)

        let restoreSecondStore = BudgetStore(defaults: restoreDefaults, seedIfEmpty: false)
        XCTAssertFalse(restoreSecondStore.hasLoadError)
        XCTAssertEqual(restoreSecondStore.categories.map(\.name), ["Food"])
        restoreDefaults.removePersistentDomain(forName: restoreSuiteName)
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
