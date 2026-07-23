import SwiftUI

struct CategoriesView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var showingAddCategory = false
    @State private var pendingCategoryDeletion: BudgetCategory?

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.categories) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(category.name)
                            .font(.headline)
                        Text("Limit: \(category.monthlyLimit.asCurrency)")
                        Text("Spent: \(store.spent(for: category.id).asCurrency)")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    guard let firstIndex = offsets.first else {
                        return
                    }
                    pendingCategoryDeletion = store.categories[firstIndex]
                }
            }
            .navigationTitle("Categories")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Add Category", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddCategory) {
                AddCategoryView()
            }
            .confirmationDialog(
                "Delete category?",
                isPresented: Binding(
                    get: { pendingCategoryDeletion != nil },
                    set: { newValue in
                        if !newValue {
                            pendingCategoryDeletion = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let category = pendingCategoryDeletion else {
                        return
                    }
                    store.deleteCategory(category)
                    pendingCategoryDeletion = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCategoryDeletion = nil
                }
            } message: {
                Text("Deleting this category will also remove all transactions in it.")
            }
        }
    }
}
