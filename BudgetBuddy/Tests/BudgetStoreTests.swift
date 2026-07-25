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

    /// Combines already-encoded JSON element blobs into a JSON array by raw
    /// byte concatenation, deliberately never routing them through
    /// JSONSerialization. Doing so would parse any JSON number into a
    /// Double-backed NSNumber and corrupt Decimal precision before the array
    /// even reaches a `.corrupt` key -- exactly the bug in recover(_:) this
    /// suite exists to catch -- which would invalidate exact-Decimal
    /// assertions in tests that build a payload this way even after that bug
    /// is fixed in the production code.
    private func combineJSONElements(_ elements: [Data]) -> Data {
        let joined = elements
            .map { String(data: $0, encoding: .utf8) ?? "" }
            .joined(separator: ",")
        return Data("[\(joined)]".utf8)
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

        // Drive the real flow: undecodable bytes in the primary key are what
        // actually produces .failed (and a backup) in production. Seeding the
        // .corrupt key directly with the primary key absent would leave
        // loadStatus.categories at .empty, a state the recovery sheet never
        // presents for, so this must start from a genuine failed load.
        let corruptData = Data("not valid json".utf8)
        defaults.set(corruptData, forKey: "budget.categories")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertTrue(store.hasRecoverableData(for: .categories))

        // Simulate the one scenario recover(_:) exists for: the backup itself
        // is (or has become) readable, e.g. a later app version can decode a
        // payload an earlier one could not.
        let recoverableCategories = [BudgetCategory(name: "Food", monthlyLimit: 500)]
        guard let recoverableData = try? JSONEncoder().encode(recoverableCategories) else {
            XCTFail("Could not encode recoverable categories.")
            return
        }
        defaults.set(recoverableData, forKey: "budget.categories.corrupt")

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

    func testRecoverTransactionsReturnsPartialAndPreservesExactDecimalValues() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.transactions")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.transactions, .failed)

        // 0.07 is one of the exact values a JSONSerialization round-trip is
        // documented to corrupt (-> 0.070000000000000007) if recovery ever
        // routes a decoded number through Double/NSNumber instead of staying
        // in JSONDecoder end to end. An integer amount would round-trip
        // exactly and hide precisely this bug -- which is how it slipped
        // through before. readableData below is used as-is (never passed
        // through JSONSerialization) so this test can't corrupt its own
        // expected value; only the broken entry (which fails to decode
        // regardless of numeric precision) is built via JSONSerialization.
        let readableTransaction = BudgetTransaction(title: "Bus", amount: decimal("0.07"), categoryID: UUID(), date: Date())
        let encoder = JSONEncoder()
        guard let readableData = try? encoder.encode(readableTransaction),
              let brokenSource = try? encoder.encode(readableTransaction),
              var brokenObject = try? JSONSerialization.jsonObject(with: brokenSource) as? [String: Any] else {
            XCTFail("Could not build test payload.")
            return
        }
        brokenObject.removeValue(forKey: "title")
        guard let brokenData = try? JSONSerialization.data(withJSONObject: brokenObject) else {
            XCTFail("Could not build test payload.")
            return
        }

        defaults.set(combineJSONElements([brokenData, readableData]), forKey: "budget.transactions.corrupt")

        let result = store.recover(.transactions)

        XCTAssertEqual(result, .partial(recovered: 1, total: 2))
        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(store.transactions.first?.title, "Bus")
        XCTAssertEqual(
            store.transactions.first?.amount,
            decimal("0.07"),
            "Decimal amount must survive recovery exactly, not round-trip through Double."
        )

        // The dropped entry exists nowhere else, so the backup must be
        // retained (not deleted) until the user explicitly resolves it.
        XCTAssertEqual(store.loadStatus.transactions, .partiallyRecovered(recovered: 1, total: 2))
        XCTAssertTrue(store.hasRecoverableData(for: .transactions))
        XCTAssertTrue(store.needsRecoveryAttention)
        XCTAssertFalse(store.hasLoadError, "A partial recovery loaded something real; it isn't a load error.")

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testRecoverCategoriesReturnsPartialAndPreservesExactDecimalValues() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)

        // 1800.10 is a representative non-integer money value and one of the exact
        // values a JSONSerialization round-trip is documented to corrupt
        // (-> 1800.0999999999999). Same construction discipline as the
        // transactions version above: readableData is never passed through
        // JSONSerialization.
        let readableCategory = BudgetCategory(name: "Housing", monthlyLimit: decimal("1800.10"))
        let encoder = JSONEncoder()
        guard let readableData = try? encoder.encode(readableCategory),
              let brokenSource = try? encoder.encode(readableCategory),
              var brokenObject = try? JSONSerialization.jsonObject(with: brokenSource) as? [String: Any] else {
            XCTFail("Could not build test payload.")
            return
        }
        brokenObject.removeValue(forKey: "name")
        guard let brokenData = try? JSONSerialization.data(withJSONObject: brokenObject) else {
            XCTFail("Could not build test payload.")
            return
        }

        defaults.set(combineJSONElements([brokenData, readableData]), forKey: "budget.categories.corrupt")

        let result = store.recover(.categories)

        XCTAssertEqual(result, .partial(recovered: 1, total: 2))
        XCTAssertEqual(store.categories.count, 1)
        XCTAssertEqual(store.categories.first?.name, "Housing")
        XCTAssertEqual(
            store.categories.first?.monthlyLimit,
            decimal("1800.10"),
            "Decimal monthlyLimit must survive recovery exactly, not round-trip through Double."
        )
        XCTAssertEqual(store.loadStatus.categories, .partiallyRecovered(recovered: 1, total: 2))
        XCTAssertTrue(store.hasRecoverableData(for: .categories))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testPartialRecoveryBackupSurvivesRelaunch() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)

        let readableCategory = BudgetCategory(name: "Housing", monthlyLimit: decimal("1800.10"))
        let encoder = JSONEncoder()
        guard let readableData = try? encoder.encode(readableCategory),
              let brokenSource = try? encoder.encode(readableCategory),
              var brokenObject = try? JSONSerialization.jsonObject(with: brokenSource) as? [String: Any] else {
            XCTFail("Could not build test payload.")
            return
        }
        brokenObject.removeValue(forKey: "name")
        guard let brokenData = try? JSONSerialization.data(withJSONObject: brokenObject) else {
            XCTFail("Could not build test payload.")
            return
        }
        defaults.set(combineJSONElements([brokenData, readableData]), forKey: "budget.categories.corrupt")

        XCTAssertEqual(store.recover(.categories), .partial(recovered: 1, total: 2))
        XCTAssertTrue(store.hasRecoverableData(for: .categories))

        // The critical case: relaunching must NOT let the stale-backup sweep
        // (clearStaleBackup, run whenever the primary key decodes fine) delete
        // this backup just because the already-recovered subset now loads
        // successfully -- the dropped entry still exists nowhere else.
        let relaunchedStore = BudgetStore(defaults: defaults, seedIfEmpty: false)

        XCTAssertEqual(relaunchedStore.loadStatus.categories, .partiallyRecovered(recovered: 1, total: 2))
        XCTAssertTrue(relaunchedStore.hasRecoverableData(for: .categories))
        XCTAssertTrue(relaunchedStore.needsRecoveryAttention)
        XCTAssertEqual(relaunchedStore.categories.map(\.name), ["Housing"])

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardingPartialRecoveryRemainderKeepsRecoveredCategoriesAndClearsBackup() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)

        let readableCategory = BudgetCategory(name: "Housing", monthlyLimit: decimal("1800.10"))
        let encoder = JSONEncoder()
        guard let readableData = try? encoder.encode(readableCategory),
              let brokenSource = try? encoder.encode(readableCategory),
              var brokenObject = try? JSONSerialization.jsonObject(with: brokenSource) as? [String: Any] else {
            XCTFail("Could not build test payload.")
            return
        }
        brokenObject.removeValue(forKey: "name")
        guard let brokenData = try? JSONSerialization.data(withJSONObject: brokenObject) else {
            XCTFail("Could not build test payload.")
            return
        }
        defaults.set(combineJSONElements([brokenData, readableData]), forKey: "budget.categories.corrupt")

        XCTAssertEqual(store.recover(.categories), .partial(recovered: 1, total: 2))

        // Discarding the remainder of a partial recovery must not reset the
        // dataset the way a .failed discard does -- the already-recovered
        // category is the final, correct state, not a fallback to reseed from.
        store.discardCorruptData(for: .categories)

        XCTAssertEqual(store.categories.map(\.name), ["Housing"])
        XCTAssertEqual(store.categories.first?.monthlyLimit, decimal("1800.10"))
        XCTAssertEqual(store.loadStatus.categories, .loaded)
        XCTAssertFalse(store.hasRecoverableData(for: .categories))
        XCTAssertFalse(store.needsRecoveryAttention)

        let relaunchedStore = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(relaunchedStore.categories.map(\.name), ["Housing"])
        XCTAssertEqual(relaunchedStore.loadStatus.categories, .loaded)
        XCTAssertFalse(relaunchedStore.needsRecoveryAttention)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testNeedsRecoveryAttentionStaysTrueForUnacknowledgedPartialRecovery() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertTrue(store.needsRecoveryAttention)

        let readableCategory = BudgetCategory(name: "Housing", monthlyLimit: decimal("1800.10"))
        let encoder = JSONEncoder()
        guard let readableData = try? encoder.encode(readableCategory),
              let brokenSource = try? encoder.encode(readableCategory),
              var brokenObject = try? JSONSerialization.jsonObject(with: brokenSource) as? [String: Any] else {
            XCTFail("Could not build test payload.")
            return
        }
        brokenObject.removeValue(forKey: "name")
        guard let brokenData = try? JSONSerialization.data(withJSONObject: brokenObject) else {
            XCTFail("Could not build test payload.")
            return
        }
        defaults.set(combineJSONElements([brokenData, readableData]), forKey: "budget.categories.corrupt")

        XCTAssertEqual(store.recover(.categories), .partial(recovered: 1, total: 2))

        // This is the crux of item 3: a partial recovery is not a load error
        // (hasLoadError correctly goes false, since something usable was
        // loaded), but the recovery sheet must not dismiss until the user
        // acknowledges the dropped entries, so a distinct signal has to stay
        // true even though hasLoadError does not.
        XCTAssertFalse(store.hasLoadError)
        XCTAssertTrue(store.needsRecoveryAttention)

        store.discardCorruptData(for: .categories)
        XCTAssertFalse(store.needsRecoveryAttention)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardingFailedCategoriesDoesNotFabricateTransactionsStatus() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.transactions, .empty)

        store.discardCorruptData(for: .categories)

        // No transactions existed to cascade, so this must not fabricate a
        // .loaded status or write an empty array to a key that genuinely had
        // nothing -- .empty and .loaded both mean "usable," but they aren't
        // the same fact, and nothing here actually changed for transactions.
        XCTAssertEqual(store.loadStatus.transactions, .empty)
        XCTAssertNil(defaults.data(forKey: "budget.transactions"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStaleCorruptBackupIsClearedWhenPrimaryKeyDecodesSuccessfully() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        // Primary key holds a valid, decodable payload...
        let categories = [BudgetCategory(name: "Food", monthlyLimit: 500)]
        guard let validData = try? JSONEncoder().encode(categories) else {
            XCTFail("Could not encode categories.")
            return
        }
        defaults.set(validData, forKey: "budget.categories")

        // ...but a stale .corrupt backup is still sitting from an earlier
        // failure that nothing ever cleaned up, e.g. left behind by an older
        // app version that could not yet decode this payload.
        defaults.set(Data("stale corrupt bytes".utf8), forKey: "budget.categories.corrupt")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)

        XCTAssertEqual(store.loadStatus.categories, .loaded)
        XCTAssertFalse(store.hasRecoverableData(for: .categories))
        XCTAssertNil(defaults.data(forKey: "budget.categories.corrupt"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStaleCorruptBackupIsClearedWhenPrimaryKeyIsEmpty() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        // No primary data at all, plus a stale backup nothing ever cleaned up.
        defaults.set(Data("stale corrupt bytes".utf8), forKey: "budget.categories.corrupt")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)

        XCTAssertEqual(store.loadStatus.categories, .empty)
        XCTAssertFalse(store.hasRecoverableData(for: .categories))
        XCTAssertNil(defaults.data(forKey: "budget.categories.corrupt"))

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardCorruptCategoriesReseedsWhenSeedIfEmptyIsEnabledAndCascadesTransactions() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")

        let orphanTransaction = BudgetTransaction(title: "Orphan", amount: 10, categoryID: UUID(), date: Date())
        guard let transactionsData = try? JSONEncoder().encode([orphanTransaction]) else {
            XCTFail("Could not encode transactions.")
            return
        }
        defaults.set(transactionsData, forKey: "budget.transactions")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: true)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertEqual(store.transactions.count, 1)

        store.discardCorruptData(for: .categories)

        // Matches what init produces for a fresh install: the four defaults,
        // and no transactions left pointing at a category that no longer exists.
        XCTAssertEqual(store.categories.map(\.name).sorted(), ["Food", "Fun", "Housing", "Transport"])
        XCTAssertTrue(store.transactions.isEmpty)
        XCTAssertFalse(store.hasLoadError)

        // State immediately after discard must equal state after a fresh init
        // over the same (now-updated) defaults -- no relaunch required to
        // reach a usable state.
        let relaunchedStore = BudgetStore(defaults: defaults, seedIfEmpty: true)
        XCTAssertEqual(relaunchedStore.categories.map(\.name).sorted(), store.categories.map(\.name).sorted())
        XCTAssertEqual(relaunchedStore.transactions.count, store.transactions.count)
        XCTAssertEqual(relaunchedStore.loadStatus, store.loadStatus)
        XCTAssertFalse(relaunchedStore.hasLoadError)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardCorruptCategoriesMatchesFreshInitWhenSeedIfEmptyIsDisabled() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        store.discardCorruptData(for: .categories)

        XCTAssertTrue(store.categories.isEmpty)
        XCTAssertEqual(store.loadStatus.categories, .empty)

        let relaunchedStore = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertTrue(relaunchedStore.categories.isEmpty)
        XCTAssertEqual(relaunchedStore.loadStatus, store.loadStatus)

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDiscardingCategoriesDoesNotClobberIndependentlyFailedTransactionsBackup() {
        guard let isolatedDefaults = makeIsolatedDefaults() else {
            XCTFail("Could not create test UserDefaults suite.")
            return
        }
        let defaults = isolatedDefaults.defaults
        let suiteName = isolatedDefaults.suiteName

        defaults.set(Data("not valid json".utf8), forKey: "budget.categories")
        let corruptTransactionsData = Data("also not valid json".utf8)
        defaults.set(corruptTransactionsData, forKey: "budget.transactions")

        let store = BudgetStore(defaults: defaults, seedIfEmpty: false)
        XCTAssertEqual(store.loadStatus.categories, .failed)
        XCTAssertEqual(store.loadStatus.transactions, .failed)

        store.discardCorruptData(for: .categories)

        // Discarding categories must not touch the independently failed
        // transactions dataset -- its backup and primary bytes are untouched,
        // left for its own recover(_:)/discardCorruptData(for:) call.
        XCTAssertEqual(store.loadStatus.transactions, .failed)
        XCTAssertEqual(defaults.data(forKey: "budget.transactions"), corruptTransactionsData)
        XCTAssertEqual(defaults.data(forKey: "budget.transactions.corrupt"), corruptTransactionsData)

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
