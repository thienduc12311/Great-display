import SwiftUI
import AppKit
import GDCore

/// The "A new version is available" window. Shown when the launch (or daily)
/// check finds a release, and from Check for Updates.
@MainActor
final class UpdateWindowController {
    static let shared = UpdateWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: UpdatePromptView(onClose: { [weak self] in self?.close() }))
            hosting.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: hosting)
            window.title = "Software Update"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }
}

struct UpdatePromptView: View {
    @ObservedObject private var updates = UpdateController.shared
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let release = updates.availableRelease, !release.notes.isEmpty {
                ScrollView {
                    Text(UpdatePromptView.notes(release.notes))
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(height: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            }

            status

            HStack {
                if let release = updates.availableRelease, case .available = updates.state {
                    Button("Skip This Version") {
                        updates.skippedVersion = release.version
                        onClose()
                    }
                }
                Spacer()
                buttons
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var title: String {
        switch updates.state {
        case .checking: return "Checking for updates…"
        case .upToDate: return "Great Display is up to date"
        default:
            if let release = updates.availableRelease { return "Great Display \(release.version) is available" }
            return "Software Update"
        }
    }

    private var subtitle: String {
        switch updates.state {
        case .upToDate:
            return "You have version \(updates.currentVersion), the newest release."
        case .failed(let message):
            return message
        default:
            if updates.availableRelease != nil {
                return "You have version \(updates.currentVersion). The update is downloaded from GitHub, verified, installed, and Great Display restarts."
            }
            return "Looking for a newer release on GitHub."
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.state {
        case .downloading(_, let progress):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress)
                Text("Downloading… \(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing and restarting…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .checking:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var buttons: some View {
        switch updates.state {
        case .available:
            if let release = updates.availableRelease {
                Button("Release Page") { NSWorkspace.shared.open(release.pageURL) }
            }
            Button("Later") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Install Update") { updates.downloadAndInstall() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .downloading:
            Button("Cancel") { updates.cancelDownload() }
        case .installing, .checking:
            EmptyView()
        case .failed:
            if let release = updates.availableRelease {
                Button("Release Page") { NSWorkspace.shared.open(release.pageURL) }
                Button("Close") { onClose() }
                Button("Try Again") { updates.downloadAndInstall() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Close") { onClose() }
                Button("Try Again") { updates.check() }
                    .buttonStyle(.borderedProminent)
            }
        case .upToDate, .idle:
            Button("OK") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Release notes are Markdown; render the inline parts and keep the lines.
    static func notes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let cleaned = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = String(line)
                while text.hasPrefix("#") { text.removeFirst() }
                return text.hasPrefix("- ") ? "• " + text.dropFirst(2) : text
            }
            .joined(separator: "\n")
        return (try? AttributedString(markdown: cleaned, options: options)) ?? AttributedString(markdown)
    }
}
