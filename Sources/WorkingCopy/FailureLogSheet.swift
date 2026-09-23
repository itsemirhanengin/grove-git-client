import AppKit
import SwiftUI

/// The whole of what git or a hook printed, behind an alert's short summary.
struct FailureLog: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var text: String
}

/// A fixed-size, scrolling view of a failure's full output.
///
/// It exists because an alert cannot scroll: a hook that prints three hundred
/// lines grew the alert past the bottom of the screen and took its OK button
/// with it. Opens scrolled to the end, where a failure is almost always
/// explained.
struct FailureLogSheet: View {
    let log: FailureLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(log.title)
                .font(.headline)

            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(log.text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(Self.end)
                    }
                    .padding(Space.md)
                }
                .background(.background.secondary)
                .clipShape(.rect(cornerRadius: Radius.sm))
                .onAppear { proxy.scrollTo(Self.end, anchor: .bottom) }
            }

            HStack {
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 680, height: 460)
    }

    private static let end = "end"
}
