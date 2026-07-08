import SwiftUI

/// About panel: the app name, the version from `CFBundleShortVersionString`, the
/// copyright line and the full MIT license text. Both the copyright line and the
/// license text come from `AppLegalText` (derived from the bundled root LICENSE) —
/// nothing legal is hardcoded here. The license sits in a `ScrollView` so the full
/// text stays reachable regardless of window size.
struct AboutView: View {
    /// Marketing version (`CFBundleShortVersionString`), e.g. "1.0". Falls back to an
    /// empty string if the key is missing so the label simply reads "Version".
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CCSync")
                .font(.title2.bold())

            Text("Version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let copyright = AppLegalText.copyright
            if !copyright.isEmpty {
                Text(copyright)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView {
                Text(AppLegalText.licenseText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }
}
