import AppKit
import SwiftUI

@MainActor
final class ExtensionsWindowModel: ObservableObject {
    /// The extension whose settings sheet is open.
    @Published var editingSettingsIdentifier: String?
}

struct ExtensionsView: View {
    private enum Layout {
        static let rowSpacing: CGFloat = 4
        static let controlSpacing: CGFloat = 10
        static let sectionSpacing: CGFloat = 18
        static let contentPadding: CGFloat = 24
        static let minimumListHeight: CGFloat = 220
        // Large enough to contain the extension settings sheet.
        static let windowWidth: CGFloat = 540
        static let windowHeight: CGFloat = 500
    }

    @ObservedObject var manager: WebExtensionCoordinator
    @ObservedObject var model: ExtensionsWindowModel
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

            ZStack {
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
            .frame(
                maxWidth: .infinity,
                minHeight: Layout.minimumListHeight,
                maxHeight: .infinity
            )
            .layoutPriority(1)

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
        .sheet(item: editingSettingsForm) { form in
            ExtensionSettingsView(
                form: form,
                save: { values in
                    try manager.saveSettings(values, for: form.identifier)
                },
                dismiss: { model.editingSettingsIdentifier = nil }
            )
        }
    }

    private var editingSettingsForm: Binding<WebExtensionCoordinator.SettingsForm?> {
        Binding(
            get: { model.editingSettingsIdentifier.flatMap(manager.settingsForm(for:)) },
            set: { form in
                if form == nil {
                    model.editingSettingsIdentifier = nil
                }
            }
        )
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
                    if !status.missingRequiredSettings.isEmpty {
                        Label(
                            "Needs Setup: \(status.missingRequiredSettings.joined(separator: ", "))",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
            if let identifier = status.identifier {
                HStack(spacing: Layout.controlSpacing) {
                    if !status.settings.isEmpty {
                        Button {
                            model.editingSettingsIdentifier = identifier
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .buttonStyle(.borderless)
                        .help("\(status.name) Settings")
                        .accessibilityLabel("\(status.name) Settings")
                    }
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
                }
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

    private let model: ExtensionsWindowModel

    init(manager: WebExtensionCoordinator) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let model = ExtensionsWindowModel()
        self.model = model
        super.init(window: window)

        window.title = WindowLayout.title
        window.isReleasedWhenClosed = false
        window.center()
        window.contentViewController = NSHostingController(rootView: ExtensionsView(
            manager: manager,
            model: model,
            dismiss: { [weak window] in window?.close() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the window, optionally opening the settings of the extension with `identifier`.
    func present(settingsFor identifier: String? = nil) {
        if let identifier {
            model.editingSettingsIdentifier = identifier
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}
