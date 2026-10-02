import AppKit
@preconcurrency import ApplicationServices

struct FocusApplicationIdentity: Equatable, Sendable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
}

struct AnchoredFocusState: Equatable, Sendable {
    let application: FocusApplicationIdentity
    let hasFocusedElement: Bool
    let isSecureTextField: Bool
}

struct CurrentFocusState: Equatable, Sendable {
    let application: FocusApplicationIdentity?
    let focusedElementMatchesAnchor: Bool
    let isSecureTextField: Bool
}

enum FocusRevalidationDecision: Equatable, Sendable {
    case paste
    case copySecure
    case copyFocusChanged
}

func focusRevalidationDecision(
    anchor: AnchoredFocusState,
    current: CurrentFocusState
) -> FocusRevalidationDecision {
    if anchor.isSecureTextField || current.isSecureTextField {
        return .copySecure
    }

    guard current.application == anchor.application else {
        return .copyFocusChanged
    }

    if anchor.hasFocusedElement,
       !current.focusedElementMatchesAnchor {
        return .copyFocusChanged
    }

    return .paste
}

enum FocusYieldDecision: Equatable, Sendable {
    case activateAnchor(processIdentifier: Int32)
    case leaveFrontmostAlone
}

/// Whether the frontmost spot has to be handed back before pasting.
///
/// A locked recording exists so your hands are free, and one of the things
/// hands do is open our own settings, about or fix-a-word window. That makes
/// us frontmost, which the revalidation above cannot tell from the user
/// walking away — so a paste has to put the anchored app back in front
/// first. Anything else is left exactly as it is: a genuine switch to a
/// third app still lands on the clipboard, and an anchor that was our own
/// window is already where it wants to be.
func focusYieldDecision(
    anchor: FocusApplicationIdentity,
    frontmost: FocusApplicationIdentity?,
    ownBundleIdentifier: String
) -> FocusYieldDecision {
    guard frontmost?.bundleIdentifier == ownBundleIdentifier,
          anchor.bundleIdentifier != ownBundleIdentifier else {
        return .leaveFrontmostAlone
    }

    return .activateAnchor(processIdentifier: anchor.processIdentifier)
}

/// Whether the dictation is aimed at one of our own windows — today only the
/// word fixer's "what you meant" field. A correction is a word, not a
/// sentence, so that one destination skips full cleanup and runs the
/// dictionary alone. `nil == nil` must not count: a dev run and the test
/// bundle can both have no bundle id, and that is not our window.
func pastesIntoOurOwnUI(target: String?, own: String?) -> Bool {
    guard let target, let own else {
        return false
    }
    return target == own
}

/// characters a following word attaches to without a space of its own: an
/// opening delimiter, a hyphen, a slash — or whitespace, where the gap is
/// already there. anything else means the words are landing against
/// something and need one.
private let openingOrWhitespace: Set<Character> = [
    "(", "[", "{", "<", "\"", "'", "\u{201C}", "\u{2018}",
    "/", "-", "\u{2014}",
]

/// the caret is standing inside a sentence that is still running: a word
/// character, or a comma or semicolon it carries on after. a full stop, a
/// bracket, a blank field or an app that refused the read all mean "this is
/// the start of something", and the first word gets its capital as before.
func continuesSentence(after preceding: String?) -> Bool {
    guard let preceding else {
        return false
    }
    // a space you left at the end of "the build failed because " is still
    // the middle of that sentence. a newline is not — that is a new line,
    // and a new line starts a new sentence.
    var line = Substring(preceding)
    while let last = line.last, last == " " || last == "\t" {
        line = line.dropLast()
    }
    guard let previous = line.last else {
        return false
    }
    return previous.isLetter
        || previous.isNumber
        || previous == ","
        || previous == ";"
}

func needsJoinSpace(after previous: Character?) -> Bool {
    // nothing to read — an empty field, a caret at offset zero, or an app
    // that refused the question — is never a reason to add a space.
    guard let previous, !previous.isWhitespace else {
        return false
    }
    return !openingOrWhitespace.contains(previous)
}

/// which app is in front is AppKit's, read on the main actor; the focused
/// element and the text at its caret are AX calls — IPC to that app, safe
/// from any thread — so key-up can read them beside the engine instead of
/// on the main thread. the element is a CF reference that is never
/// mutated, which is what makes the anchor safe to hand across.
struct FocusAnchor: @unchecked Sendable {
    private let application: FocusApplicationIdentity
    private let focusedElement: AXUIElement?
    private let focusedElementWasSecure: Bool

    /// where the text is headed, as of key-down.
    var targetBundleIdentifier: String? {
        application.bundleIdentifier
    }

    @MainActor
    static func capture(
        workspace: NSWorkspace = .shared
    ) -> FocusAnchor? {
        guard let application = applicationIdentity(workspace: workspace) else {
            return nil
        }

        return capture(in: application)
    }

    /// the anchor in an app already read: only its AX half, from any thread.
    static func capture(in application: FocusApplicationIdentity) -> FocusAnchor {
        let focusedElement = focusedElement()
        return FocusAnchor(
            application: application,
            focusedElement: focusedElement,
            focusedElementWasSecure: isSecureTextField(focusedElement)
        )
    }

    /// the frontmost app, unless it is one of ours: `captureUnlessOurs`
    /// without the AX half.
    @MainActor
    static func frontmostUnlessOurs(
        workspace: NSWorkspace = .shared
    ) -> FocusApplicationIdentity? {
        guard let application = applicationIdentity(workspace: workspace),
              application.bundleIdentifier != AppIdentity.bundleID else {
            return nil
        }
        return application
    }

    /// The anchor a dictation is judged against, taken at key-up.
    ///
    /// Our own window being frontmost is not an answer: a locked recording
    /// that ended while settings, about or fix-a-word was open still means
    /// the app you were talking into, so that case declines and the key-down
    /// anchor stands.
    @MainActor
    static func captureUnlessOurs(
        workspace: NSWorkspace = .shared
    ) -> FocusAnchor? {
        guard let anchor = capture(workspace: workspace),
              anchor.application.bundleIdentifier != AppIdentity.bundleID else {
            return nil
        }

        return anchor
    }

    /// Gives the frontmost spot back to the anchored app if we are the ones
    /// standing in front of it, and waits for the swap to actually happen.
    ///
    /// It has to finish before the synthetic ⌘V is posted, because the
    /// keystroke goes to whatever app is frontmost at that instant.
    /// Activation is asynchronous and can be refused, so the wait is short
    /// and a refusal returns false rather than hanging: revalidation then
    /// reports a changed focus and the transcript stays on the clipboard,
    /// which is today's behaviour.
    @MainActor
    func yieldFocusBackToAnchor(
        workspace: NSWorkspace = .shared,
        activate: (Int32) -> Bool = { processIdentifier in
            NSRunningApplication(processIdentifier: processIdentifier)?
                .activate(options: []) ?? false
        }
    ) async -> Bool {
        let decision = focusYieldDecision(
            anchor: application,
            frontmost: Self.applicationIdentity(workspace: workspace),
            ownBundleIdentifier: AppIdentity.bundleID
        )
        guard case let .activateAnchor(processIdentifier) = decision else {
            return true
        }
        guard activate(processIdentifier) else {
            return false
        }

        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(20))
            if workspace.frontmostApplication?.processIdentifier
                == processIdentifier {
                return true
            }
        }

        return false
    }

    @MainActor
    func revalidationDecision(
        workspace: NSWorkspace = .shared
    ) -> FocusRevalidationDecision {
        let currentElement = Self.focusedElement()
        let elementMatches: Bool

        if let focusedElement {
            elementMatches = currentElement.map {
                CFEqual(focusedElement, $0)
            } ?? false
        } else {
            elementMatches = true
        }

        return focusRevalidationDecision(
            anchor: AnchoredFocusState(
                application: application,
                hasFocusedElement: focusedElement != nil,
                isSecureTextField: focusedElementWasSecure
            ),
            current: CurrentFocusState(
                application: Self.applicationIdentity(workspace: workspace),
                focusedElementMatchesAnchor: elementMatches,
                isSecureTextField: Self.isSecureTextField(currentElement)
            )
        )
    }

    /// the last few characters before the caret, read off the element this
    /// dictation was anchored to. a handful rather than one, because "the
    /// build failed because " ends in a space you typed and the sentence is
    /// still yours. it is looked at and dropped — never stored, never
    /// archived, never sent anywhere.
    func textBeforeCursor(_ length: Int = 8) -> String? {
        guard let focusedElement else {
            return nil
        }
        // this read sits on the key-up → paste path, so an app that has
        // stopped answering costs 50 ms and no more.
        _ = AXUIElementSetMessagingTimeout(focusedElement, 0.05)

        guard let caret = Self.selectedTextRange(of: focusedElement),
              caret.location > 0 else {
            return nil
        }
        let wanted = min(length, caret.location)
        var precedingRange = CFRange(
            location: caret.location - wanted,
            length: wanted
        )
        guard let parameter = AXValueCreate(
            .cfRange,
            &precedingRange
        ) else {
            return nil
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            focusedElement,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        )

        guard error == .success,
              let text = value as? String else {
            return nil
        }
        return text
    }

    private static func selectedTextRange(
        of element: AXUIElement
    ) -> CFRange? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        )

        guard error == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(
            (value as! AXValue),
            .cfRange,
            &range
        ) else {
            return nil
        }
        return range
    }

    @MainActor
    private static func applicationIdentity(
        workspace: NSWorkspace
    ) -> FocusApplicationIdentity? {
        guard let application = workspace.frontmostApplication else {
            return nil
        }

        return FocusApplicationIdentity(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard error == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func isSecureTextField(
        _ element: AXUIElement?
    ) -> Bool {
        guard let element else {
            return false
        }

        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        )

        guard error == .success,
              let subrole = value as? String else {
            return false
        }

        return subrole == (kAXSecureTextFieldSubrole as String)
    }
}
