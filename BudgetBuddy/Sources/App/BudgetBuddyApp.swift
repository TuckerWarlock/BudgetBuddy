import SwiftUI

@main
struct BudgetBuddyApp: App {
    @StateObject private var store = BudgetStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
