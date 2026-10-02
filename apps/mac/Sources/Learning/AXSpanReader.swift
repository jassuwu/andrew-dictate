import AppKit
@preconcurrency import ApplicationServices

/// the field a dictation was just pasted into, as AX sees it — asked for a
/// range at a time and never for its whole value.
///
/// every element it asks is given `timeout` first: AX's default is six
/// seconds, and an app that has stopped answering must cost a tenth of one.
/// focus is asked of the app's own element, never the system-wide one: a
/// timeout set on that is the whole process's, the inserter's reads
/// included.
///
/// not tied to the main actor: the two questions about focus are a round
/// trip to another app each, and are asked off the main thread. everything
/// it holds is set once and never changed.
final class AXSpanReader: @unchecked Sendable {
    /// the span is read on the main thread, a few times a second at most.
    static let timeout: Float = 0.1

    let element: AXUIElement
    let processIdentifier: pid_t

    private init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
    }

    /// the focused text element of the app in front, right after a paste
    /// the inserter checked went where we left it. nil for a password
    /// field — never watched — for one of our own windows, and for anything
    /// AX won't name. blocks for the round trips: ask it off the main
    /// thread.
    static func focused(in processIdentifier: pid_t) -> AXSpanReader? {
        guard processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let element = focusedElement(of: processIdentifier),
              !isSecure(element) else {
            return nil
        }
        return AXSpanReader(
            element: element,
            processIdentifier: processIdentifier
        )
    }

    /// still the element focus is in, inside its app. whether that app is
    /// still in front is AppKit's to say, and the watcher asks it first.
    /// blocks for the round trip: ask it off the main thread.
    func isStillFocused() -> Bool {
        guard let focused = Self.focusedElement(of: processIdentifier) else {
            return false
        }
        return CFEqual(element, focused)
    }

    func caretLocation() -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range.location
    }

    func characterCount() -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        return (value as? NSNumber)?.intValue
    }

    func text(in range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success else {
            return nil
        }
        return value as? String
    }

    /// the app's element, with the short timeout. the watcher listens on
    /// it for focus moving inside the app.
    static func application(_ processIdentifier: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(processIdentifier)
        _ = AXUIElementSetMessagingTimeout(application, timeout)
        return application
    }

    /// the app's focused element, with the short timeout set before
    /// anything else is asked of it.
    private static func focusedElement(of processIdentifier: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application(processIdentifier),
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = value as! AXUIElement
        _ = AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success else {
            return false
        }
        return (value as? String) == (kAXSecureTextFieldSubrole as String)
    }
}

/// apart from the class, so the main actor the protocol is tied to isn't
/// inferred for the reader as a whole: the follower reads the span on the
/// main thread, the focus questions are asked off it.
extension AXSpanReader: SpanReader {}
