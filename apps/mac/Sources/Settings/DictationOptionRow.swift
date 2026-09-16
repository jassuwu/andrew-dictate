import SwiftUI

/// one row for one option: the definition draws itself, so a new surface
/// cannot render the words any other way.
struct DictationOptionRow: View {
    let option: DictationOption
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsToggleRow(
            option.title,
            explanation: option.explanation,
            isOn: binding
        )
    }

    private var binding: Binding<Bool> {
        switch option {
        case .preRoll:
            $settings.preRollEnabled
        case .soundFeedback:
            $settings.soundFeedbackEnabled
        }
    }
}
