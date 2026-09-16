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

@MainActor
struct FocusAnchor {
    private let application: FocusApplicationIdentity
    private let focusedElement: AXUIElement?
    private let focusedElementWasSecure: Bool

    static func capture(
        workspace: NSWorkspace = .shared
    ) -> FocusAnchor? {
        guard let application = applicationIdentity(workspace: workspace) else {
            return nil
        }

        let focusedElement = focusedElement()
        return FocusAnchor(
            application: application,
            focusedElement: focusedElement,
            focusedElementWasSecure: isSecureTextField(focusedElement)
        )
    }

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
