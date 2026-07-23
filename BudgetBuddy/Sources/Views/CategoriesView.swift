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
                    // This view only ever presents a single-item confirmation dialog
                    // (no EditButton/multi-select UI exists here), so swipe-to-delete
                    // should always yield exactly one index. Assert rather than
                    // silently dropping extra indices if multi-select is added later
                    // without updating this handler.
                    guard offsets.count == 1, let singleIndex = offsets.first else {
                        assertionFailure("Expected single-item deletion.")
                        return
                    }
                    pendingCategoryDeletion = store.categories[singleIndex]
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
