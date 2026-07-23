import SwiftUI

struct AddCategoryView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var monthlyLimit = ""
    
    private var parsedMonthlyLimit: Decimal {
        let trimmedInput = monthlyLimit.trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: trimmedInput, locale: .current) ?? .zero
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Category Name", text: $name)
                TextField("Monthly Limit", text: $monthlyLimit)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("New Category")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.addCategory(name: name, monthlyLimit: parsedMonthlyLimit)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || parsedMonthlyLimit <= .zero)
                }
            }
        }
    }
}
