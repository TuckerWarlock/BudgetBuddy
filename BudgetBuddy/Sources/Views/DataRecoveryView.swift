import SwiftUI

/// Presented while `store.hasLoadError` is true. Lets the user resolve each failed
/// dataset by restoring its `.corrupt` backup or discarding it; both actions clear
/// the store's load status, which is what actually dismisses this sheet.
///
/// MANUAL VERIFICATION REQUIRED: Restore and Discard must be tapped by hand in the
/// simulator (or on device) after any change here. Both buttons sit in a List row,
/// so a missing `.buttonStyle` lets the row's selection gesture silently swallow
/// real taps while the button stays fully valid (and tappable) in the accessibility
/// tree — XCUITest taps via that tree, so an automated UI test can pass while the
/// live app is stuck in this sheet with no way out. See DashboardView's month
/// chevrons for the same failure mode, previously diagnosed and fixed there.
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

                        Button {
                            attemptRestore(dataset)
                        } label: {
                            Text("Restore")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        // .buttonStyle(.plain) is required: without it, this List row's
                        // own selection gesture captures the tap before the Button sees
                        // it (same trap fixed on DashboardView's month chevrons).
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            restoreFailureMessages[dataset] = nil
                            store.discardCorruptData(for: dataset)
                        } label: {
                            Text("Discard")
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        // .buttonStyle(.plain) is required: same List-row gesture-capture
                        // trap as the Restore button above (and DashboardView's chevrons).
                        .buttonStyle(.plain)
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
