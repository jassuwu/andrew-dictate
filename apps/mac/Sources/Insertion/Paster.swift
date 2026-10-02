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
    /// the mac locked or slept under the take: the field it was going to
    /// is behind the lock screen, so it is copied and never pasted.
    case locked
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
    struct Snapshot: Sendable {
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
    static let transientType = NSPasteboard.PasteboardType(
        "org.nspasteboard.TransientType"
    )

    private var isPasting = false
    private var pasteWaiters: [CheckedContinuation<Void, Never>] = []
    private let keyCodeResolver = PasteKeyCodeResolver()
    /// the clipboard as key-up found it, read off the main thread while
    /// the engine works: a clipboard holding an image can take tens of
    /// milliseconds to read, and none of them need be after the words.
    private var readingAhead: (id: UInt64, read: Task<Snapshot?, Never>)?
    private var readAheadSequence: UInt64 = 0
    /// it holds whatever you had copied, a password included, so it does
    /// not outlive the take it was read for. a take that runs past this
    /// reads the clipboard at the paste, as every take used to.
    private static let readAheadLifetime = Duration.seconds(30)

    /// reads the clipboard now, for the paste to come. not while a paste
    /// or its restore is still out: that one writes the clipboard on the
    /// main thread, and the read would race it. the paste reads it itself
    /// then, as it always has.
    func readAhead() {
        guard !isPasting else {
            readingAhead = nil
            return
        }
        readAheadSequence &+= 1
        let id = readAheadSequence
        readingAhead = (
            id,
            Task.detached(priority: .userInitiated) {
                Self.snapshot(of: .general)
            }
        )
        Task { [weak self] in
            try? await Task.sleep(for: Self.readAheadLifetime)
            if self?.readingAhead?.id == id {
                self?.readingAhead = nil
            }
        }
    }

    /// the clipboard to put back after the paste: the one read while the
    /// engine worked if nothing was copied since, or read again now if
    /// something was. a ⌘C during the wait is what you have, so it is what
    /// comes back.
    nonisolated static func snapshotToRestore(
        early: Snapshot?,
        on pasteboard: NSPasteboard
    ) -> Snapshot? {
        if let early, early.changeCount == pasteboard.changeCount {
            return early
        }
        return snapshot(of: pasteboard)
    }

    func paste(
        _ text: String,
        reasonForLeavingOnPasteboard: (() -> LeftOnPasteboardReason?)? = nil
    ) async -> PasteOutcome {
        await acquirePasteTransaction()
        // released by hand on every path out of here rather than by a defer:
        // the success path hands it to the restore task, so a second
        // dictation queues behind the real restore instead of behind the
        // caller. miss one of the early returns and the next paste hangs.

        let early = await takeReadAhead()
        let pasteboard = NSPasteboard.general
        var snapshot = Self.snapshotToRestore(early: early, on: pasteboard)

        if let capturedSnapshot = snapshot,
           pasteboard.changeCount != capturedSnapshot.changeCount {
            snapshot = nil
        }

        // nobody will read the result of a cancelled paste, so writing the
        // transcript would replace whatever the user had copied with a
        // sentence they threw away, silently.
        guard !Task.isCancelled else {
            releasePasteTransaction()
            return PasteOutcome(result: .leftOnPasteboard(.cancelled))
        }

        // asked once here, before anything is written: a password has to go
        // onto the clipboard concealed, and that cannot be decided after the
        // write. the later re-checks still catch a focus that moves since.
        let leaveBehindReason = reasonForLeavingOnPasteboard?()

        guard let writtenChangeCount = Self.writeTranscript(
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
            // cancelled after the write — the reason check makes
            // accessibility round-trips, so that window is real. hand the
            // clipboard back, since the caller swallows this result.
            Self.restore(
                snapshot,
                expectedChangeCount: writtenChangeCount,
                transcript: text
            )
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

        // the transcript is a relay, not a second archive: mark it transient
        // so clipboard managers let it pass. only here, once the keystroke is
        // actually out — every copy left behind for you to fetch by hand has
        // returned above, and those do need to be collectable.
        let ourChangeCount = Self.markTransient(pasteboard)
            ?? writtenChangeCount

        Task.detached { [weak self] in
            try? await Task.sleep(for: .milliseconds(10))
            await MainActor.run {
                _ = Self.postPasteKey(keyCode, keyDown: false)
            }
            try? await Task.sleep(for: .milliseconds(290))
            await MainActor.run { [weak self] in
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

    /// a copy you asked for: the menu's timings and diagnostics. it takes
    /// its turn behind any paste and the restore after it, so it never
    /// lands between a dictation's snapshot of your clipboard and the put
    /// back; and a read-ahead still out finishes first, so that off-main
    /// read never meets this write half done. a plain write, as a ⌘C would
    /// be: no relay marker, and the next paste reads it fresh by its change
    /// count.
    func copy(
        _ text: String,
        to pasteboard: NSPasteboard = .general
    ) async {
        await acquirePasteTransaction()
        if let readingAhead {
            _ = await readingAhead.read.value
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        releasePasteTransaction()
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

    /// done with by the paste that takes it, whatever the paste does next.
    private func takeReadAhead() async -> Snapshot? {
        guard let readingAhead else {
            return nil
        }
        self.readingAhead = nil
        return await readingAhead.read.value
    }

    nonisolated static func snapshot(of pasteboard: NSPasteboard) -> Snapshot? {
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
    static func writeTranscript(
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

    /// The org.nspasteboard convention — maccy, alfred, pastebot and clipmenu
    /// read this type as "passing through" and decline to keep the item.
    ///
    /// An additive write to the item we just wrote, so the change count it
    /// returns is still ours: the restore only fires while what is on the
    /// clipboard is what we put there. nil means AppKit declined the type,
    /// which costs nothing but the marker.
    static func markTransient(_ pasteboard: NSPasteboard) -> Int? {
        guard pasteboard.setString("", forType: transientType) else {
            return nil
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
            // the one path that strands the transcript on purpose. it is
            // still a relay, so it still says so.
            _ = writeTranscript(transcript, to: pasteboard)
            _ = markTransient(pasteboard)
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
