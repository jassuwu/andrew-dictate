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

/// What the paste did, and the instant it reached the target app.
///
/// `insertedAt` is stamped the moment the ⌘V key-down is posted, because that
/// is when the words appear. Restoring the clipboard afterwards is
/// housekeeping, and nobody waits for housekeeping.
struct PasteOutcome: Sendable {
    let result: PasteResult
    let insertedAt: ContinuousClock.Instant

    init(
        result: PasteResult,
        insertedAt: ContinuousClock.Instant = ContinuousClock.now
    ) {
        self.result = result
        self.insertedAt = insertedAt
    }
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

    static let concealedType = NSPasteboard.PasteboardType(
        "org.nspasteboard.ConcealedType"
    )

    private var isPasting = false
    private var pasteWaiters: [CheckedContinuation<Void, Never>] = []
    private let keyCodeResolver = PasteKeyCodeResolver()

    func paste(
        _ text: String,
        reasonForLeavingOnPasteboard: (() -> LeftOnPasteboardReason?)? = nil
    ) async -> PasteOutcome {
        await acquirePasteTransaction()

        let pasteboard = NSPasteboard.general
        var snapshot = Self.snapshot(of: pasteboard)

        if let capturedSnapshot = snapshot,
           pasteboard.changeCount != capturedSnapshot.changeCount {
            snapshot = nil
        }

        // asked once here, before anything is written: a password has to go
        // onto the clipboard concealed, and that cannot be decided after the
        // write. the later re-checks still catch a focus that moves since.
        let leaveBehindReason = reasonForLeavingOnPasteboard?()

        // the transaction is released by hand on every path out of here, so
        // a second dictation queues behind the real restore rather than
        // behind the caller. miss one and the next paste waits forever.
        guard let ourChangeCount = Self.writeTranscript(
            text,
            to: pasteboard,
            concealed: leaveBehindReason == .secureField
        ) else {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(.pasteboardUnavailable))
        }
        if let leaveBehindReason {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(leaveBehindReason))
        }
        guard CGPreflightPostEventAccess() else {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(.accessibilityUnavailable))
        }
        guard !Task.isCancelled else {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(.cancelled))
        }

        let keyCode = keyCodeResolver.keyCodeForV()
        if let reason = reasonForLeavingOnPasteboard?() {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(reason))
        }
        guard Self.postPasteKey(keyCode, keyDown: true) else {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(.shortcutUnavailable))
        }
        // the keystroke is posted: this is the instant the text lands.
        let insertedAt = ContinuousClock.now

        Task.detached { [weak self] in
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
                self?.releasePasteTransaction()
            }
        }
        return PasteOutcome(result: .pasted, insertedAt: insertedAt)
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

    /// `concealed` adds `org.nspasteboard.ConcealedType`, the convention
    /// maccy, alfred and pastebot read as "do not record this one". the
    /// transcript still pastes with ⌘V; it just stops being collected.
    private static func writeTranscript(
        _ text: String,
        to pasteboard: NSPasteboard,
        concealed: Bool = false
    ) -> Int? {
        prepare(pasteboard, concealed: concealed)

        if !pasteboard.setString(text, forType: .string) {
            prepare(pasteboard, concealed: concealed)
            guard pasteboard.setString(text, forType: .string) else {
                return nil
            }
        }

        if concealed {
            _ = pasteboard.setString("", forType: concealedType)
        }

        return pasteboard.changeCount
    }

    private static func prepare(
        _ pasteboard: NSPasteboard,
        concealed: Bool
    ) {
        if concealed {
            _ = pasteboard.declareTypes([.string, concealedType], owner: nil)
        } else {
            pasteboard.clearContents()
        }
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
