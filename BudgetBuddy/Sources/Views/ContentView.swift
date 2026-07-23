import SwiftUI

struct ContentView: View {
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
    }
}
