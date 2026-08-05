import SwiftUI

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
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(BrandUI.bodyFont.weight(.medium))
                    .foregroundStyle(BrandUI.textPrimary)

                Text(explanation)
                    .font(BrandUI.bodyFont)
                    .foregroundStyle(BrandUI.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .brandToggleStyle()
        }
    }
}
