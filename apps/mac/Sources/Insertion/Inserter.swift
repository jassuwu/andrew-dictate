/// where one dictation is headed, captured once and judged later. the
/// utterance machine reads the first two members for the cleaner; the last
/// two are the inserter's, and only the inserter calls them.
@MainActor
protocol InsertionAnchor {
    /// where the text is headed, as of capture.
    var targetBundleIdentifier: String? { get }
    /// a few characters before the caret — looked at and dropped.
    func textBeforeCursor() -> String?
    /// hands the frontmost spot back if one of our windows took it, and
    /// says whether it got there.
    func yieldFocusBackToAnchor() async -> Bool
    /// whether focus is still where the dictation was aimed.
    func revalidationDecision() -> FocusRevalidationDecision
}

/// puts a transcript into the frontmost app — paste-based, transactional,
/// clipboard-restoring. the sole consumer of a transcript. the utterance
/// machine decides what to say about the outcome; this decides the outcome,
/// and every AX call and pasteboard write stays on this side of the seam.
@MainActor
protocol Inserter: AnyObject {
    /// the anchor as of now: key-down's standby, and a retry's.
    func captureAnchor() -> (any InsertionAnchor)?
    /// key-up's anchor, or nil when one of our own windows is frontmost
    /// (`FocusAnchor.captureUnlessOurs`).
    func captureAnchorUnlessOurs() -> (any InsertionAnchor)?
    /// gives focus back, revalidates against the anchor, then pastes — or
    /// leaves the words on the pasteboard and says why.
    func insert(
        _ text: String,
        at anchor: (any InsertionAnchor)?
    ) async -> PasteOutcome
    /// leaves the words on the pasteboard for you to paste, and never
    /// pastes: the place they were going is gone. a normal write, not the
    /// paste's transient relay, so it is still there when you come back.
    func copy(
        _ text: String,
        because reason: LeftOnPasteboardReason
    ) async -> PasteOutcome
}

/// the real one: `FocusAnchor` for where the words are going, `Paster` for
/// getting them there.
@MainActor
final class PasteInserter: Inserter {
    private let paster = Paster()

    func captureAnchor() -> (any InsertionAnchor)? {
        FocusAnchor.capture()
    }

    func captureAnchorUnlessOurs() -> (any InsertionAnchor)? {
        FocusAnchor.captureUnlessOurs()
    }

    func insert(
        _ text: String,
        at anchor: (any InsertionAnchor)?
    ) async -> PasteOutcome {
        // hands-free means our own settings window may be in front of the
        // app you dictated into. give the frontmost spot back before the
        // ⌘V goes out, or the paste lands here and reads as focus theft.
        _ = await anchor?.yieldFocusBackToAnchor()
        return await paster.paste(
            text,
            reasonForLeavingOnPasteboard: {
                switch anchor?.revalidationDecision()
                    ?? .copyFocusChanged {
                case .paste:
                    nil
                case .copySecure:
                    .secureField
                case .copyFocusChanged:
                    .focusChanged
                }
            }
        )
    }

    func copy(
        _ text: String,
        because reason: LeftOnPasteboardReason
    ) async -> PasteOutcome {
        // the paste's own path with a reason to stop short: written, the
        // reason handed back, no ⌘V and no restore.
        await paster.paste(text, reasonForLeavingOnPasteboard: { reason })
    }
}

/// the defaults on `FocusAnchor`'s own methods are injection points for
/// whoever holds one directly; through the protocol it is always the shared
/// workspace and the default eight characters.
extension FocusAnchor: InsertionAnchor {
    func textBeforeCursor() -> String? {
        textBeforeCursor(8)
    }

    func yieldFocusBackToAnchor() async -> Bool {
        await yieldFocusBackToAnchor(workspace: .shared)
    }

    func revalidationDecision() -> FocusRevalidationDecision {
        revalidationDecision(workspace: .shared)
    }
}
