import AppKit
import Foundation

enum HUDContent: Equatable, Sendable {
    case wave
    case prewarming
    case text(String)
}

/// the size of the thing on the stage — the ribbon's canvas or the text
/// pill. the window itself is the stage (`HUDLayoutEngine.stageSize`), an
/// invisible rectangle wide enough for the widest pill, so the glass can
/// morph from one shape to the next without the window moving.
struct HUDLayout: Equatable, Sendable {
    let size: CGSize
    let lineCount: Int
}

enum HUDLayoutEngine {
    static let minimumSize = CGSize(width: 180, height: 44)
    /// the lamp line plus room for its glow bleed on every side
    static let waveSize = CGSize(width: 166, height: 64)
    static let horizontalPadding: CGFloat = 14
    static let measurementSafety: CGFloat = 2
    static let maximumScreenWidthFraction: CGFloat = 0.55
    static let wrappedLineSpacing: CGFloat = 4
    /// room around the widest content for the ribbon's halo and the pill's
    /// glass edge — nothing on the stage may touch the window's edge, which
    /// clips regardless of layer masks
    static let stageMargin: CGFloat = 24

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

    /// the window: fixed per screen, never morphs
    static func stageSize(screenWidth: CGFloat) -> CGSize {
        let widestPill = max(
            minimumSize.width,
            screenWidth * maximumScreenWidthFraction
        )
        let tallest = max(
            waveSize.height,
            primaryLineHeight * 2 + wrappedLineSpacing
                + (minimumSize.height - primaryLineHeight)
        )
        return CGSize(
            width: ceil(widestPill + stageMargin * 2),
            height: ceil(tallest + stageMargin * 2)
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
                lineCount: 1
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
