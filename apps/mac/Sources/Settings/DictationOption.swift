import SwiftUI

/// options that appear on more than one surface are defined once, here.
/// onboarding and settings render the same definition, so the words on the
/// two screens cannot drift apart — there is only one set of words.
enum DictationOption: CaseIterable, Identifiable, Sendable {
    case preRoll
    case soundFeedback

    var id: Self { self }

    var title: String {
        switch self {
        case .preRoll:
            "pre-roll"
        case .soundFeedback:
            "sound feedback"
        }
    }

    var explanation: String {
        switch self {
        case .preRoll:
            "keeps a short microphone buffer warm to protect the first word."
        case .soundFeedback:
            "a mic-switch click when listening starts and stops."
        }
    }
}

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
