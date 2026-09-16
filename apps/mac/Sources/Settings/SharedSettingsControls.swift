import SwiftUI

/// the leading half of every settings row: a title with one line under it.
/// shared so a row with a control that isn't a toggle — the dictation key —
/// sits on the same baseline grid and in the same type as its neighbours.
struct SettingsRowLabel: View {
    let title: String
    let explanation: String

    init(_ title: String, explanation: String) {
        self.title = title
        self.explanation = explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(BrandUI.bodyFont.weight(.medium))
                .foregroundStyle(BrandUI.textPrimary)

            Text(explanation)
                .font(BrandUI.bodyFont)
                .foregroundStyle(BrandUI.textSecondary)
                // two lines: an option that costs something needs room
                // to say so, and a truncated price is no price at all.
                .lineLimit(2)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let explanation: String
    @Binding var isOn: Bool

    init(
        _ title: String,
        explanation: String,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.explanation = explanation
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SettingsRowLabel(title, explanation: explanation)

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .brandToggleStyle()
                // the label is drawn beside it, not attached to it, so
                // without this the switch announces as a bare toggle.
                .accessibilityLabel(title)
                .accessibilityHint(explanation)
        }
    }
}
