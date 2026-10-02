import AppKit
@preconcurrency import ApplicationServices

/// the field a dictation was just pasted into, as AX sees it — asked for a
/// range at a time and never for its whole value.
@MainActor
final class AXSpanReader: SpanReader {
    let element: AXUIElement
    let processIdentifier: pid_t

    private init(element: AXUIElement, processIdentifier: pid_t) {
        self.element = element
        self.processIdentifier = processIdentifier
        // every read is on the main thread: an app that has stopped
        // answering costs a tenth of a second, not a beachball.
        _ = AXUIElementSetMessagingTimeout(element, 0.1)
    }

    /// the focused text element, right after a paste the inserter checked
    /// went where we left it. nil for a password field — never watched —
    /// for one of our own windows, and for anything AX won't name.
    static func focused() -> AXSpanReader? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = value as! AXUIElement

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !isSecure(element) else {
            return nil
        }
        return AXSpanReader(
            element: element,
            processIdentifier: processIdentifier
        )
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

    /// still the element focus is in. the watch ends the moment it isn't.
    func isStillFocused() -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return false
        }
        return CFEqual(element, value)
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
