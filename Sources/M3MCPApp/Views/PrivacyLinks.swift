import SwiftUI

/// Kept available before setup and after permissions are declined.
struct PrivacyLinks: View {
    var body: some View {
        HStack {
            Link("Datenschutzerklärung", destination: URL(string: "https://www.mobilebox-consulting.de/datenschutzerkl%C3%A4rung-privacy-policy/")!)
            Link("Support kontaktieren", destination: URL(string: "mailto:mobile_box@icloud.com")!)
        }
        .font(.callout)
    }
}
