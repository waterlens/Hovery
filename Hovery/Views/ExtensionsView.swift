import AppKit
import SwiftUI

struct ExtensionsView: View {
    private enum Layout {
        static let rowSpacing: CGFloat = 4
        static let sectionSpacing: CGFloat = 18
        static let contentPadding: CGFloat = 24
        static let minimumListHeight: CGFloat = 220
        static let windowWidth: CGFloat = 520
        static let windowHeight: CGFloat = 430
    }

    @ObservedObject var manager: WebExtensionCoordinator
    let dismiss: () -> Void
    @State private var pendingNativeExtension: WebExtensionCoordinator.ExtensionStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.sectionSpacing) {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                Text("Extensions")
                    .font(.title2.bold())
                Text("Choose which extensions can show results when you hover over text.")
                    .foregroundStyle(.secondary)
            }

            Group {
                if manager.extensions.isEmpty {
                    ContentUnavailableView(
                        "No Extensions",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Add a .hoveryextension package to the Extensions folder.")
                    )
                } else {
                    List(manager.extensions) { extensionStatus in
                        extensionRow(extensionStatus)
                    }
                }
            }
            .frame(minHeight: Layout.minimumListHeight)

            HStack {
                Button("Open Extensions Folder") {
                    manager.openExtensionsDirectory()
                }
                Button("Reload") {
                    manager.reloadExtensions()
                }
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Layout.contentPadding)
        .frame(width: Layout.windowWidth, height: Layout.windowHeight)
        .alert(
            "Allow Native Extension?",
            isPresented: Binding(
                get: { pendingNativeExtension != nil },
                set: { if !$0 { pendingNativeExtension = nil } }
            ),
            presenting: pendingNativeExtension
        ) { extensionStatus in
            Button("Cancel", role: .cancel) {}
            Button("Allow and Enable") {
                if let identifier = extensionStatus.identifier {
                    manager.trustAndEnableNativeExtension(identifier: identifier)
                }
            }
        } message: { extensionStatus in
            Text("\(extensionStatus.name) contains native code that runs with your account’s access. Only allow it if you trust its source.")
        }
    }

    @ViewBuilder
    private func extensionRow(_ status: WebExtensionCoordinator.ExtensionStatus) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Layout.rowSpacing) {
                Text(status.name)
                    .font(.headline)
                if let error = status.errorDescription {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let input = status.input {
                    Text("Uses the \(input.rawValue) under the pointer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if status.hasNativeCode {
                        Label("Contains Native Code", systemImage: "cpu")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if let identifier = status.identifier {
                Toggle("Enabled", isOn: Binding(
                    get: { status.isEnabled },
                    set: { enabled in
                        if enabled, status.hasNativeCode, !status.isNativeCodeTrusted {
                            pendingNativeExtension = status
                        } else {
                            manager.setEnabled(enabled, identifier: identifier)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Extension error")
            }
        }
        .padding(.vertical, Layout.rowSpacing)
    }
}

@MainActor
final class ExtensionsWindowController: NSWindowController {
    private enum WindowLayout {
        static let title = "Extensions"
    }

    init(manager: WebExtensionCoordinator) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = WindowLayout.title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: ExtensionsView(
            manager: manager,
            dismiss: { [weak window] in window?.close() }
        ))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
