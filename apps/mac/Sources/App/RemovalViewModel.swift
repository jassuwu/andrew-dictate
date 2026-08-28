import Combine
import Foundation

/// Drives the removal sheet: what is on disk, what is ticked, and what happened.
///
/// Everything that exists starts ticked, because the user asked to leave and
/// making them opt in to each piece is how "no traces" quietly becomes "some
/// traces". The caveats are what make that default honest rather than reckless.
@MainActor
final class RemovalViewModel: ObservableObject {
    @Published private(set) var entries: [RemovalPlan.Entry] = []
    @Published var selection: Set<RemovalPlan.Item> = []
    /// Off by default. Deleting the application is a different act from
    /// deleting its data, and someone may only want a reset.
    @Published var alsoTrashTheApp = false
    @Published private(set) var outcome: String?
    @Published private(set) var didRemoveAnything = false

    private let remover: Remover

    init(remover: Remover = Remover()) {
        self.remover = remover
        reload()
    }

    func reload() {
        let plan = remover.plan()
        entries = plan.entries
        selection = Set(plan.entries.filter(\.exists).map(\.item))
        outcome = nil
    }

    var hasAnythingToRemove: Bool {
        entries.contains { $0.exists }
    }

    var selectedBytes: Int64 {
        entries
            .filter { $0.exists && selection.contains($0.item) }
            .reduce(0) { $0 + $1.bytes }
    }

    var selectedSizeText: String {
        Self.formatted(selectedBytes)
    }

    func sizeText(for entry: RemovalPlan.Entry) -> String {
        entry.exists ? Self.formatted(entry.bytes) : "nothing kept"
    }

    func toggle(_ item: RemovalPlan.Item) {
        if selection.contains(item) {
            selection.remove(item)
        } else {
            selection.insert(item)
        }
    }

    /// Returns the items that could not be removed, and leaves a sentence in
    /// `outcome` either way. SPEC §4: a removal that did not happen must not
    /// look like one that did.
    @discardableResult
    func removeSelected() -> [RemovalPlan.Item] {
        let failed = remover.remove(selection)
        didRemoveAnything = true
        reloadKeepingOutcome()

        if failed.isEmpty {
            outcome = "removed. quitting."
        } else {
            outcome = "couldn’t remove: "
                + failed.map(\.title).joined(separator: ", ")
                + ". they’re still on disk."
        }
        return failed
    }

    private func reloadKeepingOutcome() {
        entries = remover.plan().entries
        selection = selection.filter { item in
            entries.contains { $0.item == item && $0.exists }
        }
    }

    static func formatted(_ bytes: Int64) -> String {
        guard bytes > 0 else {
            return "—"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
