import SwiftUI

/// an option that could appear on more than one surface is defined once,
/// here. settings is the only screen rendering these today — onboarding
/// omits them and lets the defaults stand — so this is a rule kept ahead of
/// the second screen, not a description of one.
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
            "turn this on if your first word gets clipped — it keeps the mic open the whole time the app runs."
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
