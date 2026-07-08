import SwiftUI

/// First-launch disclaimer. A non-dismissible sheet: it has no close button and
/// blocks Escape / click-outside via `.interactiveDismissDisabled(true)`, so the
/// only way to close it is the "I Understand" button, which flips the
/// `didAcknowledgeDisclaimer` flag stored by the caller.
///
/// The wording comes from `AppLegalText.disclaimer` — the single source — and is
/// wrapped in a `ScrollView` so the full text stays reachable in a small window.
struct DisclaimerSheet: View {
    /// Invoked when the user taps "I Understand". The caller persists acknowledgement.
    let onAcknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Before you use CCSync")
                .font(.headline)

            ScrollView {
                Text(AppLegalText.disclaimer)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("I Understand", action: onAcknowledge)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 360)
        .interactiveDismissDisabled(true)
    }
}
