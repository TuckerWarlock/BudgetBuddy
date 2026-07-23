import SwiftUI

struct AddTransactionView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var amount = ""
    @State private var selectedCategoryID: UUID?
    @State private var date = Date()

    private var parsedAmount: Decimal {
        let trimmedInput = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: trimmedInput, locale: .current) ?? .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Amount", text: $amount)
                    .keyboardType(.decimalPad)
                Picker("Category", selection: $selectedCategoryID) {
                    ForEach(store.categories) { category in
                        Text(category.name).tag(Optional(category.id))
                    }
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
            .navigationTitle("New Transaction")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let categoryID = selectedCategoryID else {
                            assertionFailure("Category must be selected before saving a transaction.")
                            return
                        }
                        store.addTransaction(
                            title: title,
                            amount: parsedAmount,
                            categoryID: categoryID,
                            date: date
                        )
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedAmount <= .zero || selectedCategoryID == nil)
                }
            }
            .onAppear {
                if selectedCategoryID == nil {
                    selectedCategoryID = store.categories.first?.id
                }
            }
        }
    }
}
