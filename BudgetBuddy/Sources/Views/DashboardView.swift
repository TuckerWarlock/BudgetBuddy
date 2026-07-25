import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var showingAddTransaction = false
    
    private var selectedMonthLabel: String {
        // Locale-aware, matching the deliberately locale-aware currency
        // formatting in CurrencyFormat.swift -- a fixed "LLLL yyyy" pattern
        // would always read as English month names regardless of the user's
        // locale/calendar preferences.
        store.selectedMonth.formatted(.dateTime.month(.wide).year())
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
                            // Deliberately opacity, not .disabled(): a runtime .disabled()
                            // toggle in a List row is its own failure mode (see the
                            // .buttonStyle(.plain) comment above). VoiceOver would still
                            // announce this as an active button without this, so hide it
                            // from the accessibility tree instead while it's a no-op.
                            // Note: confirmed via MonthNavigationUITests that XCUIElement
                            // .exists does NOT reflect this (XCUITest's element tree isn't
                            // the same tree VoiceOver reads) -- verify this one by hand
                            // with VoiceOver, not with an automated tap test.
                            .accessibilityHidden(store.isSelectedMonthCurrentMonth)
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
