import AppKit
import Foundation

enum HUDContent: Equatable, Sendable {
    case wave
    case prewarming
    case text(primary: String, secondary: String?)
}

struct HUDLayout: Equatable, Sendable {
    let size: CGSize
    let lineCount: Int
}

enum HUDLayoutEngine {
    static let minimumSize = CGSize(width: 180, height: 44)
    static let horizontalPadding: CGFloat = 14
    static let measurementSafety: CGFloat = 2
    static let maximumScreenWidthFraction: CGFloat = 0.55
    static let wrappedLineSpacing: CGFloat = 4

    static var primaryFont: NSFont {
        .systemFont(ofSize: 12, weight: .medium)
    }

    static var secondaryFont: NSFont {
        .systemFont(ofSize: 9.5, weight: .regular)
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
            return HUDLayout(size: minimumSize, lineCount: 1)
        case let .text(primary, secondary):
            let maximumWidth = max(
                minimumSize.width,
                screenWidth * maximumScreenWidthFraction
            )
            let primaryWidth = measuredWidth(
                of: primary,
                font: primaryFont
            )
            let secondaryWidth = secondary.map {
                measuredWidth(of: $0, font: secondaryFont)
            } ?? 0
            let textWidth = max(primaryWidth, secondaryWidth)
            let fixedHorizontalSpace =
                horizontalPadding * 2 + measurementSafety
            let width = min(
                max(textWidth + fixedHorizontalSpace, minimumSize.width),
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
                lineCount: lineCount
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
