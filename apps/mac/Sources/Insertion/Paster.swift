import AppKit
@preconcurrency import ApplicationServices

enum PasteResult: Equatable, Sendable {
    case pasted
    case leftOnPasteboard(LeftOnPasteboardReason)
}

enum LeftOnPasteboardReason: Equatable, Sendable {
    case secureField
    case focusChanged
    case accessibilityUnavailable
    case shortcutUnavailable
    case cancelled
    case pasteboardUnavailable
}

@MainActor
final class Paster {
    private struct Snapshot: Sendable {
        struct Item: Sendable {
            struct Representation: Sendable {
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
    private let keyCodeResolver = PasteKeyCodeResolver()

    func paste(
        _ text: String,
        reasonForLeavingOnPasteboard: (() -> LeftOnPasteboardReason?)? = nil
    ) async -> PasteResult {
        await acquirePasteTransaction()
        defer { releasePasteTransaction() }

        let pasteboard = NSPasteboard.general
        var snapshot = Self.snapshot(of: pasteboard)

        if let capturedSnapshot = snapshot,
           pasteboard.changeCount != capturedSnapshot.changeCount {
            snapshot = nil
        }

        guard let ourChangeCount = Self.writeTranscript(text, to: pasteboard) else {
            return .leftOnPasteboard(.pasteboardUnavailable)
        }
        if let reason = reasonForLeavingOnPasteboard?() {
            return .leftOnPasteboard(reason)
        }
        guard CGPreflightPostEventAccess() else {
            return .leftOnPasteboard(.accessibilityUnavailable)
        }
        guard !Task.isCancelled else {
            return .leftOnPasteboard(.cancelled)
        }

        let keyCode = keyCodeResolver.keyCodeForV()
        if let reason = reasonForLeavingOnPasteboard?() {
            return .leftOnPasteboard(reason)
        }
        guard Self.postPasteKey(keyCode, keyDown: true) else {
            return .leftOnPasteboard(.shortcutUnavailable)
        }

        let restoreTask = Task.detached {
            try? await Task.sleep(for: .milliseconds(10))
            await MainActor.run {
                _ = Self.postPasteKey(keyCode, keyDown: false)
            }
            try? await Task.sleep(for: .milliseconds(290))
            await MainActor.run {
                Self.restore(
                    snapshot,
                    expectedChangeCount: ourChangeCount,
                    transcript: text
                )
            }
        }
        await restoreTask.value
        return .pasted
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

        if !pasteboard.setString(text, forType: .string) {
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                return nil
            }
        }

        return pasteboard.changeCount
    }

    private static func postPasteKey(
        _ keyCode: CGKeyCode,
        keyDown: Bool
    ) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: keyCode,
                  keyDown: keyDown
              ) else {
            return false
        }

        event.flags = .maskCommand
        event.post(tap: .cghidEventTap)
        return true
    }

    private static func restore(
        _ snapshot: Snapshot?,
        expectedChangeCount: Int,
        transcript: String
    ) {
        let pasteboard = NSPasteboard.general
        guard let snapshot,
              let restoredItems = makePasteboardItems(from: snapshot),
              pasteboard.changeCount == expectedChangeCount else {
            return
        }

        pasteboard.clearContents()

        guard !snapshot.items.isEmpty else {
            return
        }

        guard pasteboard.writeObjects(restoredItems) else {
            _ = writeTranscript(transcript, to: pasteboard)
            return
        }
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
