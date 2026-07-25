import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BudgetStore

    // A single derived rule: store.needsRecoveryAttention (failed or
    // unacknowledged-partial datasets) is the sole source of truth for
    // whether this sheet is up -- not hasLoadError alone, which would let the
    // sheet dismiss the instant a partial recovery's dropped entries stop
    // counting as a "failure," before the user has ever been told about them.
    // The setter is intentionally a no-op: .interactiveDismissDisabled()
    // blocks the common dismissal path (swipe), and DataRecoveryView's
    // explicit Restore/Discard actions are the only things that change
    // store.needsRecoveryAttention, at which point this binding's `get`
    // naturally flips and SwiftUI dismisses the sheet on its own.
    //
    // (An earlier version mirrored this into @State with a pair of onChange
    // handlers, one to sync from store state and one to fight a hypothetical
    // system-initiated dismissal. That gave the same store-is-truth guarantee
    // through two more moving parts for a case that's never been observed --
    // consolidated back to this single rule instead.)
    private var isPresentingRecovery: Binding<Bool> {
        Binding(get: { store.needsRecoveryAttention }, set: { _ in })
    }

    var body: some View {
        TabView {
            DashboardView()
                .tabItem {
                    Label("Dashboard", systemImage: "chart.pie.fill")
                }

            CategoriesView()
                .tabItem {
                    Label("Categories", systemImage: "list.bullet.clipboard")
                }
        }
        .sheet(isPresented: isPresentingRecovery) {
            DataRecoveryView()
                .interactiveDismissDisabled()
        }
    }
}
