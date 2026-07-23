import SwiftUI

/// Presented while `store.hasLoadError` is true. Lets the user resolve each failed
/// dataset by restoring its `.corrupt` backup or discarding it; both actions clear
/// the store's load status, which is what actually dismisses this sheet.
struct DataRecoveryView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var restoreFailureMessages: [RecoverableDataset: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.loadStatus.failedDatasets, id: \.self) { dataset in
                    Section(dataset.displayName) {
                        Text("This data couldn't be read when the app launched. It has been preserved and can be restored or discarded.")
                            .foregroundStyle(.secondary)

                        if let message = restoreFailureMessages[dataset] {
                            Text(message)
                                .foregroundStyle(.red)
                        }

                        Button("Restore") {
                            attemptRestore(dataset)
                        }

                        Button("Discard", role: .destructive) {
                            restoreFailureMessages[dataset] = nil
                            store.discardCorruptData(for: dataset)
                        }
                    }
                }
            }
            .navigationTitle("Data Recovery")
        }
    }

    private func attemptRestore(_ dataset: RecoverableDataset) {
        switch store.recover(dataset) {
        case .success:
            restoreFailureMessages[dataset] = nil
        case .decodeFailure:
            restoreFailureMessages[dataset] = "\(dataset.displayName) still couldn't be read."
        }
    }
}
