import SwiftUI

// MARK: - Restore default profiles
//
// Settings, in both hosts (the panel's Settings section and the settings window).
// The four built-in profiles absorb the response edits made while they are
// selected — that is what makes this button meaningful — so putting them back is
// a destructive-enough action to confirm: it rewrites Silent, Balanced,
// Performance and Full throttle to their factory curve / sensor / response
// values and leaves every profile the user created untouched.

struct RestoreDefaultProfilesButton: View {
    @ObservedObject var viewModel: FanViewModel
    @State private var confirming = false

    var body: some View {
        HStack(spacing: DS.s2) {
            Button("Restore default profiles…") { confirming = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L10n.text("Reset the built-in profiles to their original values"))
            Spacer(minLength: 0)
        }
        .alert("Restore default profiles?", isPresented: $confirming) {
            Button("Restore", role: .destructive) {
                viewModel.restoreDefaultProfiles()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Silent, Balanced, Performance and Full throttle go back to their original curve and response settings. Profiles you created are kept.")
        }
    }
}
