import SwiftUI

// Placeholder.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button("Done") { UserDefaults.standard.set(true, forKey: PrefKey.didOnboard); dismiss() }.padding(40) }
}
