import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: BudgetStore

    // Presentation tracks store state directly rather than transient View state:
    // the sheet reappears on every launch until the user resolves it via Restore
    // or Discard in DataRecoveryView, which is what actually clears loadStatus.
    private var isShowingRecovery: Binding<Bool> {
        Binding(get: { store.hasLoadError }, set: { _ in })
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
        .sheet(isPresented: isShowingRecovery) {
            DataRecoveryView()
                .interactiveDismissDisabled()
        }
    }
}
