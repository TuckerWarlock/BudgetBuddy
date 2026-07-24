import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var showingAddTransaction = false
    
    private static let monthYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private var selectedMonthLabel: String {
        Self.monthYearFormatter.string(from: store.selectedMonth)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Button {
                                store.selectPreviousMonth()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("previousMonthButton")
                            Spacer()
                            Text(selectedMonthLabel)
                                .font(.headline)
                                .accessibilityIdentifier("selectedMonthLabel")
                            Spacer()
                            Button {
                                store.selectNextMonth()
                            } label: {
                                Image(systemName: "chevron.right")
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("nextMonthButton")
                            .opacity(store.isSelectedMonthCurrentMonth ? 0.35 : 1)
                        }
                        Text("Budget: \(store.totalLimit.asCurrency)")
                        Text("Spent: \(store.totalSpent.asCurrency)")
                        Text("Remaining: \(store.remaining.asCurrency)")
                            .fontWeight(.semibold)
                            .foregroundStyle(store.remaining >= .zero ? .green : .red)
                    }
                    .padding(.vertical, 6)
                }

                Section("Recent Transactions") {
                    if store.categories.isEmpty {
                        Text("Add a category from the Categories tab to start tracking transactions.")
                            .foregroundStyle(.secondary)
                    } else if store.monthlyTransactions.isEmpty {
                        Text("No transactions yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        let recentTransactions = Array(store.monthlyTransactions.prefix(10))
                        ForEach(recentTransactions) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title)
                                    Text(store.categoryName(for: item.categoryID))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(item.amount.asCurrency)
                                    .fontWeight(.medium)
                            }
                        }
                        .onDelete { offsets in
                            offsets
                                .map { recentTransactions[$0] }
                                .forEach(store.deleteTransaction)
                        }
                    }
                }
            }
            .navigationTitle("BudgetBuddy")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddTransaction = true
                    } label: {
                        Label("Add Transaction", systemImage: "plus")
                    }
                    .disabled(store.categories.isEmpty)
                }
            }
            .sheet(isPresented: $showingAddTransaction) {
                AddTransactionView()
            }
        }
    }
}
