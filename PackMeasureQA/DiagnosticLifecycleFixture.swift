import SwiftUI

/// A capture callback can remove a live control while its diagnostic report is open.
/// This fixture exercises that transition without a camera or an actual email.
struct DiagnosticLifecycleFixture: View {
    @Environment(DiagnosticPresentation.self) private var presentation
    @State private var live = true

    var body: some View {
        VStack {
            if live {
                DiagnosticButton(title: "Fixture diagnostics", kind: .room,
                                 report: "Synthetic capture before the view changed.")
            } else {
                Text("Scan finished while report open").accessibilityIdentifier("diagnostic-live-control-removed")
            }
        }
        .onChange(of: presentation.report?.id) { _, id in
            if id != nil { live = false }
        }
    }
}
