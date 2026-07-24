import SwiftUI

enum BrandUI {
    static let windowBg = Color(
        red: 0x16 / 255,
        green: 0x16 / 255,
        blue: 0x19 / 255
    )
    static let cardBg = Color(
        red: 0x1F / 255,
        green: 0x1F / 255,
        blue: 0x24 / 255
    )
    static let textPrimary = Color(
        red: 0xF2 / 255,
        green: 0xED / 255,
        blue: 0xE0 / 255
    )
    static let textSecondary = textPrimary.opacity(0.55)
    static let goldPale = Color(
        red: 0xF9 / 255,
        green: 0xE9 / 255,
        blue: 0xA8 / 255
    )
    static let gold = Color(
        red: 0xE5 / 255,
        green: 0xBE / 255,
        blue: 0x62 / 255
    )
    static let goldDeep = Color(
        red: 0x9E / 255,
        green: 0x75 / 255,
        blue: 0x27 / 255
    )
    static let hairline = gold.opacity(0.14)

    static let titleFont = Font.system(size: 22, weight: .semibold)
    static let sectionLabelFont = Font.system(
        size: 11,
        weight: .semibold
    )
    static let bodyFont = Font.system(size: 13)
    static let valueFont = Font.system(size: 12, design: .monospaced)
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
        Text(title.uppercased())
            .font(BrandUI.sectionLabelFont)
            .tracking(0.8)
            .foregroundStyle(BrandUI.gold.opacity(0.75))
    }
}

struct KeyChip: View {
    private let key: String

    init(_ key: String) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(BrandUI.valueFont)
            .foregroundStyle(BrandUI.goldPale)
            .padding(4)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(BrandUI.windowBg.opacity(0.72))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(BrandUI.hairline, lineWidth: 1)
            }
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
