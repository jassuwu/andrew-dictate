import AppKit
import Foundation

enum HUDContent: Equatable, Sendable {
    case wave
    case prewarming
    case text(String)
}

enum HUDStyle: Equatable, Sendable {
    /// no chrome: a transparent window holding only the lamp line and its glow
    case bare
    /// the glass capsule — reserved for exceptional text (errors, copied-instead)
    case glass
}

struct HUDLayout: Equatable, Sendable {
    let size: CGSize
    let lineCount: Int
    let style: HUDStyle
}

enum HUDLayoutEngine {
    static let minimumSize = CGSize(width: 180, height: 44)
    /// the lamp line plus room for its glow bleed on every side
    static let waveSize = CGSize(width: 166, height: 64)
    static let horizontalPadding: CGFloat = 14
    static let measurementSafety: CGFloat = 2
    static let maximumScreenWidthFraction: CGFloat = 0.55
    static let wrappedLineSpacing: CGFloat = 4

    static var primaryFont: NSFont {
        .systemFont(ofSize: 12, weight: .medium)
    }

    static var primaryLineHeight: CGFloat {
        ceil(
            primaryFont.ascender
                - primaryFont.descender
                + primaryFont.leading
        )
    }

    static func layout(
        for content: HUDContent,
        screenWidth: CGFloat
    ) -> HUDLayout {
        switch content {
        case .wave, .prewarming:
            return HUDLayout(
                size: waveSize,
                lineCount: 1,
                style: .bare
            )
        case let .text(text):
            let maximumWidth = max(
                minimumSize.width,
                screenWidth * maximumScreenWidthFraction
            )
            let primaryWidth = measuredWidth(
                of: text,
                font: primaryFont
            )
            let fixedHorizontalSpace =
                horizontalPadding * 2 + measurementSafety
            let width = min(
                max(primaryWidth + fixedHorizontalSpace, minimumSize.width),
                maximumWidth
            )
            let availablePrimaryWidth = max(
                0,
                maximumWidth - fixedHorizontalSpace
            )
            let lineCount = primaryWidth > availablePrimaryWidth ? 2 : 1
            let height = minimumSize.height
                + (lineCount == 2
                    ? primaryLineHeight + wrappedLineSpacing
                    : 0)

            return HUDLayout(
                size: CGSize(width: width, height: height),
                lineCount: lineCount,
                style: .glass
            )
        }
    }

    private static func measuredWidth(
        of text: String,
        font: NSFont
    ) -> CGFloat {
        let attributedString = NSAttributedString(
            string: text,
            attributes: [.font: font]
        )
        let bounds = attributedString.boundingRect(
            with: CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bounds.width)
    }
}
