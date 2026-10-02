import AppKit

/// How the update line's click is carried out. `UpdateOffer` says what the
/// click is for; this does it. The one-click brew upgrade replaces
/// `ManualHandOff` here and leaves the line and its action alone.
@MainActor
protocol UpdateHandOff {
    func perform(_ action: UpdateOffer.Action)
}

/// today's hand-off: you run the last step yourself. a brew install gets
/// the upgrade command on the clipboard and a pill saying so — the menu
/// has already closed, so the menu cannot say it. a dmg install gets the
/// releases page in the browser, which is its own confirmation.
@MainActor
struct ManualHandOff: UpdateHandOff {
    static let copied = "copied — paste it in terminal"

    var pasteboard: NSPasteboard = .general
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var confirm: (String) -> Void

    func perform(_ action: UpdateOffer.Action) {
        switch action {
        case let .brewUpgrade(command):
            pasteboard.clearContents()
            pasteboard.setString(command, forType: .string)
            confirm(Self.copied)
        case let .openReleasePage(page):
            open(page)
        }
    }
}
