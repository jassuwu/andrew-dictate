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
