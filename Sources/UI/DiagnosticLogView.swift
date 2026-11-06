import SwiftUI

/// Help › Copy Diagnostic Log: the log is shown first, so you see what you'd paste into a bug report, and only Copy
/// puts it on the clipboard.
struct DiagnosticLogView: View {
    @State private var log = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent events from this session, to paste into a bug report. Addresses are cut to their site and files to their type. Nothing is sent anywhere.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView([.vertical, .horizontal]) {
                Text(log)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 380)
        .tint(Settings.shared.accent)
        // A snapshot taken when the window opens: what you read is exactly what Copy copies.
        .onAppear { log = Diagnostics.report() }
    }
}
