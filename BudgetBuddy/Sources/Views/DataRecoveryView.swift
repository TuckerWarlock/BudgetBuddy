import SwiftUI

/// Presented while `store.needsRecoveryAttention` is true. Lets the user
/// resolve each unresolved dataset by restoring its `.corrupt` backup or
/// discarding it (in full for a `.failed` dataset, or just the
/// still-unrecovered remainder for a `.partiallyRecovered` one); every one of
/// those actions clears the store's status for that dataset, which is what
/// actually dismisses this sheet once nothing is left unresolved.
///
/// MANUAL VERIFICATION REQUIRED: Restore and Discard must be tapped by hand in the
/// simulator (or on device) after any change here. Both buttons sit in a List row,
/// so a missing `.buttonStyle` lets the row's selection gesture silently swallow
/// real taps while the button stays fully valid (and tappable) in the accessibility
/// tree — XCUITest taps via that tree, so an automated UI test can pass while the
/// live app is stuck in this sheet with no way out. See DashboardView's month
/// chevrons for the same failure mode, previously diagnosed and fixed there. The
/// categories-discard confirmation dialog below needs the same by-hand check --
/// XCUITest can't tell a confirmationDialog driven by real state from one that
/// only looks right in the accessibility tree either.
struct DataRecoveryView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var restoreFailureMessages: [RecoverableDataset: String] = [:]
    @State private var pendingCategoriesDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.loadStatus.unresolvedDatasets, id: \.self) { dataset in
                    Section(dataset.displayName) {
                        Text(description(for: dataset))
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
                            requestDiscard(dataset)
                        } label: {
                            Text(discardTitle(for: dataset))
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
            .confirmationDialog(
                "Discard categories?",
                isPresented: $pendingCategoriesDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) {
                    restoreFailureMessages[.categories] = nil
                    store.discardCorruptData(for: .categories)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(categoriesDiscardMessage)
            }
        }
    }

    private func description(for dataset: RecoverableDataset) -> String {
        switch store.loadStatus.outcome(for: dataset) {
        case .partiallyRecovered(let recovered, let total):
            return "Recovered \(recovered) of \(total) \(dataset.displayName.lowercased())."
                + " The rest couldn't be read and are preserved -- you can try again or discard them."
        case .failed, .empty, .loaded:
            return "This data couldn't be read when the app launched. It has been preserved and can be restored or discarded."
        }
    }

    private func discardTitle(for dataset: RecoverableDataset) -> String {
        if case .partiallyRecovered = store.loadStatus.outcome(for: dataset) {
            return "Discard Remainder"
        }
        return "Discard"
    }

    /// A full categories reset (the `.failed` path in
    /// `BudgetStore.discardAndReset(_:)`) cascades every live transaction,
    /// since they'd all reference a category ID that's about to be gone. That
    /// blast radius isn't obvious from this screen's per-dataset copy, so it
    /// gets its own confirmation here -- mirroring CategoriesView's dialog for
    /// the same cascade. A `.partiallyRecovered` categories discard never
    /// touches the live array (see `requestDiscard`), so it never needs this.
    private var categoriesDiscardMessage: String {
        let count = store.transactions.count
        guard count > 0 else {
            return "This will reset your categories."
        }
        return "This will reset your categories and delete \(count) transaction\(count == 1 ? "" : "s") that reference them."
    }

    private func requestDiscard(_ dataset: RecoverableDataset) {
        guard dataset == .categories else {
            restoreFailureMessages[dataset] = nil
            store.discardCorruptData(for: dataset)
            return
        }

        // Only a full (.failed) categories discard wipes transactions -- see
        // BudgetStore.discardAndReset(_:). A partial-recovery remainder
        // discard never touches the live array, so it doesn't need this
        // confirmation.
        if case .partiallyRecovered = store.loadStatus.categories {
            restoreFailureMessages[dataset] = nil
            store.discardCorruptData(for: dataset)
            return
        }

        if store.transactions.isEmpty {
            restoreFailureMessages[dataset] = nil
            store.discardCorruptData(for: dataset)
        } else {
            pendingCategoriesDiscardConfirmation = true
        }
    }

    private func attemptRestore(_ dataset: RecoverableDataset) {
        switch store.recover(dataset) {
        case .success:
            restoreFailureMessages[dataset] = nil
        case .partial:
            // store.loadStatus now reflects the (possibly updated) partial
            // counts directly, and this Section's description re-renders
            // from that -- no separate transient notice needed, and the
            // Section keeps showing (unresolvedDatasets includes
            // .partiallyRecovered) rather than disappearing with the news.
            restoreFailureMessages[dataset] = nil
        case .decodeFailure:
            restoreFailureMessages[dataset] = "\(dataset.displayName) still couldn't be read."
        }
    }
}
