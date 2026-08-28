import AppKit
import SwiftUI

/// the one palette. every gold in this app — the lamp, the menu bar badge,
/// the settings chrome — comes from here, as raw channels so both SwiftUI and
/// AppKit can be handed the same numbers instead of their own copy of them.
enum BrandUI {
    static let goldPaleRGB: [Double] = [249, 233, 168]
    static let goldRGB: [Double] = [229, 190, 98]
    static let goldDeepRGB: [Double] = [158, 117, 39]
    /// the brand black. the menu bar badge ringed itself in 0B0B0D while the
    /// site painted 0C0C0E; they were always meant to be the same black.
    static let blackRGB: [Double] = [12, 12, 14]
    /// window and card are surfaces, not blacks — a deliberate ramp above it.
    static let windowBgRGB: [Double] = [22, 22, 25]
    static let cardBgRGB: [Double] = [31, 31, 36]
    static let textPrimaryRGB: [Double] = [242, 237, 224]
    /// missing permission, failed anything. never gold: gold means working.
    static let attentionRGB: [Double] = [224, 85, 60]

    static func color(_ rgb: [Double], opacity: Double = 1) -> Color {
        Color(
            red: rgb[0] / 255,
            green: rgb[1] / 255,
            blue: rgb[2] / 255,
            opacity: opacity
        )
    }

    static func nsColor(_ rgb: [Double], alpha: Double = 1) -> NSColor {
        NSColor(
            srgbRed: rgb[0] / 255,
            green: rgb[1] / 255,
            blue: rgb[2] / 255,
            alpha: alpha
        )
    }

    static let black = color(blackRGB)
    static let windowBg = color(windowBgRGB)
    static let cardBg = color(cardBgRGB)
    static let textPrimary = color(textPrimaryRGB)
    static let textSecondary = textPrimary.opacity(0.55)
    static let goldPale = color(goldPaleRGB)
    static let gold = color(goldRGB)
    static let goldDeep = color(goldDeepRGB)
    static let attention = color(attentionRGB)

    static let hairline = gold.opacity(0.14)

    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let sectionLabelFont = Font.system(
        size: 11,
        weight: .semibold
    )
    static let bodyFont = Font.system(size: 13)

    // three roles, borrowed from jass.gg: paper (SF — prose, controls),
    // machine (Ioskeley Mono — anything factual: keys, versions, numbers),
    // hand (Excalifont — a signature, and nothing else; anywhere else a
    // hand font reads as a gimmick). fonts ship in Resources/Fonts (OFL).
    static let valueFont = machineFont(size: 12)

    static func machineFont(size: CGFloat, bold: Bool = false) -> Font {
        Font.custom(bold ? "Ioskeley-Mono-Bold" : "Ioskeley-Mono", size: size)
    }

    static func handFont(size: CGFloat) -> Font {
        Font.custom("Excalifont-Regular", size: size)
    }
}

struct BrandCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(BrandUI.cardBg)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(BrandUI.hairline, lineWidth: 1)
            }
    }
}

struct BrandSectionHeader: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        // not uppercased. everything this app says to you is lowercase —
        // the section labels were the one place it shouted.
        Text(title)
            .font(BrandUI.sectionLabelFont)
            .tracking(0.9)
            .foregroundStyle(BrandUI.gold.opacity(0.75))
    }
}

struct KeyChip: View {
    private let key: String
    private let isActive: Bool

    init(_ key: String, isActive: Bool = false) {
        self.key = key
        self.isActive = isActive
    }

    var body: some View {
        Text(key)
            .font(BrandUI.valueFont)
            .foregroundStyle(
                isActive ? BrandUI.windowBg : BrandUI.goldPale
            )
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isActive
                            ? BrandUI.gold
                            : BrandUI.windowBg.opacity(0.72)
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        isActive ? BrandUI.goldPale : BrandUI.hairline,
                        lineWidth: 1
                    )
            }
            .scaleEffect(isActive ? 1.08 : 1)
            .animation(.easeOut(duration: 0.14), value: isActive)
    }
}

extension View {
    func brandTinted() -> some View {
        tint(BrandUI.gold)
    }

    func brandToggleStyle() -> some View {
        toggleStyle(.switch)
            .tint(BrandUI.gold)
    }

    func brandMenuStyle() -> some View {
        pickerStyle(.menu)
            .tint(BrandUI.gold)
    }
}
