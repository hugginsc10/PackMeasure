import CoreTransferable
import Darwin
import MessageUI
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Freezes the session's report when tapped so a retry cannot change the attachment.
struct DiagnosticButton: View {
    let title: String
    let kind: DiagnosticReport.Kind
    let report: String
    var identifier = "scan-diagnostics"
    @Environment(DiagnosticPresentation.self) private var presentation

    var body: some View {
        Button {
            presentation.report = DiagnosticReport(kind: kind, payload: report,
                                                    deviceModel: DiagnosticDeviceMetadata.model,
                                                    systemVersion: UIDevice.current.systemVersion)
        } label: {
            Label(title, systemImage: "envelope")
        }
        .accessibilityIdentifier(identifier)
    }
}

@MainActor @Observable final class DiagnosticPresentation {
    var report: DiagnosticReport?
}

/// Attach to a stable screen root, above live/review/error branches. A coaching
/// card disappearing must not dismiss a report while someone writes their note.
private struct DiagnosticPresentationHost: ViewModifier {
    @State private var presentation = DiagnosticPresentation()

    func body(content: Content) -> some View {
        @Bindable var presentation = presentation
        content.environment(presentation)
            .sheet(item: $presentation.report) { DiagnosticSupportView(report: $0) }
    }
}

extension View {
    func diagnosticSupport() -> some View { modifier(DiagnosticPresentationHost()) }
}

enum DiagnosticDeviceMetadata {
    /// Model family plus hardware type; no device name, serial, or persistent identifier.
    @MainActor static var model: String {
        var system = utsname()
        guard uname(&system) == 0 else { return UIDevice.current.model }
        let hardware = withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(UIDevice.current.model) (\(hardware))"
    }
}

struct DiagnosticAttachment: Transferable {
    let report: DiagnosticReport
    let note: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { $0.report.attachmentData(note: $0.note) }
            .suggestedFileName { $0.report.filename }
    }
}

struct DiagnosticSupportView: View {
    let report: DiagnosticReport
    var mailAvailable = MFMailComposeViewController.canSendMail()
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var composing = false
    @State private var notice: String?
    @FocusState private var noteFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("To", value: SupportContact.email)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("diagnostic-recipient")
                    Text("Report ID: \(report.id.uuidString)")
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("diagnostic-report-id")
                } header: { Text("Send to PackMeasure") }

                Section {
                    TextEditor(text: $note)
                        .focused($noteFocused)
                        .frame(minHeight: 110)
                        .accessibilityLabel("What went wrong?")
                        .accessibilityIdentifier("diagnostic-note")
                } header: { Text("What went wrong? (optional)") }
                  footer: { Text("Describe what you expected, what happened, and any tape-measure comparison. You can add a screenshot in the email composer.") }

                Section {
                    Text(report.kind == .app
                         ? "App version, build, iPhone model, and iOS version. No scan report is attached."
                         : "App and device details plus this scan's diagnostic report, which can include measured dimensions and captured geometry.")
                    Text("Camera photographs and your saved room or inventory library aren't attached. Nothing is uploaded automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if report.kind == .app {
                        Text("For a scan issue, open Diagnostics on the scan or review screen to include its troubleshooting details before retrying or closing it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("What's included") }

                Section {
                    Button("Email report", systemImage: "envelope") { noteFocused = false; composing = true }
                        .disabled(!mailAvailable)
                        .accessibilityIdentifier("diagnostic-email")
                    ShareLink(item: DiagnosticAttachment(report: report, note: note),
                              subject: Text(report.emailSubject), message: Text(report.emailBody(note: note)),
                              preview: SharePreview(report.filename)) {
                        Label("Share report", systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("diagnostic-share")
                    Button("Copy email address", systemImage: "doc.on.doc") {
                        noteFocused = false
                        UIPasteboard.general.string = SupportContact.email
                        notice = "Email address copied. Send the shared report to \(SupportContact.email)."
                    }.accessibilityIdentifier("diagnostic-copy-email")
                    if !mailAvailable {
                        Text("Mail isn't configured on this iPhone. Use Share report to send the attachment with Gmail or another app, or save it to Files. Copy the email address if the recipient isn't filled in.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("diagnostic-mail-unavailable")
                    }
                    if let notice { Text(notice).font(.footnote).accessibilityIdentifier("diagnostic-notice") }
                } footer: { Text("Review the recipient and attachment, then tap Send in your email app. Opening or sharing a report does not confirm delivery.") }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Send diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                if noteFocused {
                    HStack {
                        Spacer()
                        Button("Done") { noteFocused = false }
                            .font(.subheadline.weight(.semibold))
                            .accessibilityIdentifier("diagnostic-note-done")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .sheet(isPresented: $composing) {
                DiagnosticMailComposer(report: report, note: note) { outcome in
                    composing = false
                    notice = outcome.message
                }
            }
        }
    }
}

enum DiagnosticMailOutcome: Equatable, Sendable {
    case sent, saved, cancelled, failed

    var message: String {
        switch self {
        case .sent: "Mail accepted the message. Check your Sent folder and the recipient's inbox to confirm delivery."
        case .saved: "Draft saved in Mail. Open the draft and tap Send when you're ready."
        case .cancelled: "Email cancelled. Your note and report are still here."
        case .failed: "Mail couldn't send the report. Try again or use Share report with another email app."
        }
    }
}

private struct DiagnosticMailComposer: UIViewControllerRepresentable {
    let report: DiagnosticReport
    let note: String
    let onFinish: (DiagnosticMailOutcome) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let composer = MFMailComposeViewController()
        composer.mailComposeDelegate = context.coordinator
        composer.setToRecipients([SupportContact.email])
        composer.setSubject(report.emailSubject)
        composer.setMessageBody(report.emailBody(note: note), isHTML: false)
        composer.addAttachmentData(report.attachmentData(note: note), mimeType: "text/plain", fileName: report.filename)
        return composer
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    @MainActor final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (DiagnosticMailOutcome) -> Void
        init(onFinish: @escaping (DiagnosticMailOutcome) -> Void) { self.onFinish = onFinish }

        nonisolated func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            let outcome: DiagnosticMailOutcome
            if error != nil { outcome = .failed }
            else {
                switch result {
                case .sent: outcome = .sent
                case .saved: outcome = .saved
                case .cancelled: outcome = .cancelled
                case .failed: outcome = .failed
                @unknown default: outcome = .failed
                }
            }
            Task { @MainActor in self.onFinish(outcome) }
        }
    }
}
