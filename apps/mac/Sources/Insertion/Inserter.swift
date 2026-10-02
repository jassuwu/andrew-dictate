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
    /// the anchor as of now, ours included: key-down's standby, and a
    /// retry's. awaited, never blocked on: the AX half is IPC to whatever
    /// app is in front, and a press must not wait on another app.
    func readAnchor() async -> (any InsertionAnchor)?
    /// key-up's anchor, or nil when one of our own windows is frontmost
    /// (`FocusAnchor.captureUnlessOurs`).
    func captureAnchorUnlessOurs() -> (any InsertionAnchor)?
    /// key-up's target: its anchor — `standby` when one of our own windows
    /// is in front — and the text before its caret. read while the engine
    /// works, so by the time the words exist only the paste is left.
    func readTarget(
        standby: (any InsertionAnchor)?
    ) async -> InsertionTarget
    /// the paste is coming: read what the clipboard holds now, while the
    /// engine works. the paste puts it back afterwards, and only has to
    /// check nothing was copied over it in between.
    func readPasteboardAhead()
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

/// where key-up's words are going: the anchor the paste is judged against,
/// and the few characters before its caret that decide the capital and the
/// space. nil text is an app that wouldn't say.
@MainActor
struct InsertionTarget {
    let anchor: (any InsertionAnchor)?
    let textBeforeCursor: String?
}

extension Inserter {
    /// in turn, on the main actor: what a target with no faster way does.
    func readTarget(
        standby: (any InsertionAnchor)?
    ) async -> InsertionTarget {
        let anchor = captureAnchorUnlessOurs() ?? standby
        return InsertionTarget(
            anchor: anchor,
            textBeforeCursor: anchor?.textBeforeCursor()
        )
    }

    /// nothing to read ahead: the paste reads the clipboard itself.
    func readPasteboardAhead() {}
}

/// the real one: `FocusAnchor` for where the words are going, `Paster` for
/// getting them there.
@MainActor
final class PasteInserter: Inserter {
    private let paster = Paster()

    /// which app is in front is AppKit's, and free to ask here. the AX
    /// half runs off the main thread and gets a fifth of a second of that
    /// app's time (`FocusAnchor.capture(in:answeringWithin:)`): a standby
    /// that has not come back by key-up stands in for nothing.
    func readAnchor() async -> (any InsertionAnchor)? {
        guard let application = FocusAnchor.frontmost() else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            FocusAnchor.capture(
                in: application,
                answeringWithin: FocusAnchor.standbyPatience
            )
        }.value
    }

    func captureAnchorUnlessOurs() -> (any InsertionAnchor)? {
        FocusAnchor.captureUnlessOurs()
    }

    /// which app is in front is AppKit's, and free to ask here. the rest
    /// is AX — IPC to that app, a few milliseconds or, from a slow one, up
    /// to its timeout — so it runs off the main thread, beside the engine,
    /// while the chime and the lamp go on.
    func readTarget(
        standby: (any InsertionAnchor)?
    ) async -> InsertionTarget {
        let application = FocusAnchor.frontmostUnlessOurs()
        let fallback = standby as? FocusAnchor
        guard application != nil || standby == nil || fallback != nil else {
            // a standby only the main actor can read: read it there.
            return InsertionTarget(
                anchor: standby,
                textBeforeCursor: standby?.textBeforeCursor()
            )
        }
        let (anchor, text) = await Task.detached(priority: .userInitiated) {
            let anchor = application.map(FocusAnchor.capture(in:)) ?? fallback
            return (anchor, anchor?.textBeforeCursor(8))
        }.value
        return InsertionTarget(anchor: anchor, textBeforeCursor: text)
    }

    func readPasteboardAhead() {
        paster.readAhead()
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

    /// a copy you asked for from the menu, in turn with the dictations'
    /// pastes: never between one's snapshot of your clipboard and its
    /// restore.
    func copy(_ text: String) async {
        await paster.copy(text)
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
