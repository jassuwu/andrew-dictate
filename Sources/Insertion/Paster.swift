import AppKit
@preconcurrency import ApplicationServices

@MainActor
final class Paster {
    private struct Snapshot {
        struct Item {
            struct Representation {
                let type: String
                let data: Data
            }

            let representations: [Representation]
        }

        let changeCount: Int
        let items: [Item]
    }

    private var isPasting = false
    private var pasteWaiters: [CheckedContinuation<Void, Never>] = []

    func paste(_ text: String) async {
        await acquirePasteTransaction()
        defer { releasePasteTransaction() }

        let pasteboard = NSPasteboard.general
        var snapshot = Self.snapshot(of: pasteboard)

        if let capturedSnapshot = snapshot,
           pasteboard.changeCount != capturedSnapshot.changeCount {
            snapshot = nil
        }

        guard let ourChangeCount = Self.writeTranscript(text, to: pasteboard) else {
            return
        }
        guard CGPreflightPostEventAccess() else {
            return
        }
        guard await Self.postPasteShortcut() else {
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }

        guard let snapshot,
              let restoredItems = Self.makePasteboardItems(from: snapshot),
              pasteboard.changeCount == ourChangeCount else {
            return
        }

        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        guard pasteboard.writeObjects(restoredItems) else {
            _ = Self.writeTranscript(text, to: pasteboard)
            return
        }
    }

    private func acquirePasteTransaction() async {
        guard isPasting else {
            isPasting = true
            return
        }

        await withCheckedContinuation { continuation in
            pasteWaiters.append(continuation)
        }
    }

    private func releasePasteTransaction() {
        guard !pasteWaiters.isEmpty else {
            isPasting = false
            return
        }

        pasteWaiters.removeFirst().resume()
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> Snapshot? {
        let changeCount = pasteboard.changeCount

        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return nil
        }

        var items: [Snapshot.Item] = []
        items.reserveCapacity(pasteboardItems.count)

        for pasteboardItem in pasteboardItems {
            var representations: [Snapshot.Item.Representation] = []
            representations.reserveCapacity(pasteboardItem.types.count)

            for type in pasteboardItem.types {
                guard let data = pasteboardItem.data(forType: type) else {
                    return nil
                }

                representations.append(
                    Snapshot.Item.Representation(
                        type: type.rawValue,
                        data: data
                    )
                )
            }

            items.append(Snapshot.Item(representations: representations))
        }

        guard pasteboard.changeCount == changeCount else {
            return nil
        }

        return Snapshot(changeCount: changeCount, items: items)
    }

    private static func writeTranscript(
        _ text: String,
        to pasteboard: NSPasteboard
    ) -> Int? {
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            _ = pasteboard.setString(text, forType: .string)
            return nil
        }

        return pasteboard.changeCount
    }

    private static func postPasteShortcut() async -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 9,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 9,
                  keyDown: false
              ) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        guard !Task.isCancelled else {
            return false
        }

        keyDown.post(tap: .cghidEventTap)

        do {
            try await Task.sleep(for: .milliseconds(10))
        } catch {
            keyUp.post(tap: .cghidEventTap)
            return false
        }

        keyUp.post(tap: .cghidEventTap)
        return !Task.isCancelled
    }

    private static func makePasteboardItems(
        from snapshot: Snapshot
    ) -> [NSPasteboardItem]? {
        var pasteboardItems: [NSPasteboardItem] = []
        pasteboardItems.reserveCapacity(snapshot.items.count)

        for item in snapshot.items {
            let pasteboardItem = NSPasteboardItem()

            for representation in item.representations {
                let type = NSPasteboard.PasteboardType(
                    rawValue: representation.type
                )

                guard pasteboardItem.setData(
                    representation.data,
                    forType: type
                ) else {
                    return nil
                }
            }

            pasteboardItems.append(pasteboardItem)
        }

        return pasteboardItems
    }
}
