import AppKit
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    private enum Layout {
        static let verticalSpacing: CGFloat = 14
        static let pairedButtonSpacing: CGFloat = 8
        static let contentPadding: CGFloat = 14
        static let windowWidth: CGFloat = 330
    }

    private enum LoginItemAlert: Identifiable {
        case approvalRequired
        case failure(String)

        var id: String {
            switch self {
            case .approvalRequired: "approval-required"
            case .failure(let message): "failure-\(message)"
            }
        }
    }

    private struct SubtleDestructiveButtonStyle: ButtonStyle {
        private enum Appearance {
            static let verticalPadding: CGFloat = 6
            static let cornerRadius: CGFloat = 7
            static let lineWidth: CGFloat = 1
            static let normalFillOpacity = 0.10
            static let pressedFillOpacity = 0.17
            static let borderOpacity = 0.18
            static let foregroundOpacity = 0.88
        }

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .padding(.vertical, Appearance.verticalPadding)
                .foregroundStyle(.red.opacity(Appearance.foregroundOpacity))
                .background(
                    .red.opacity(
                        configuration.isPressed
                            ? Appearance.pressedFillOpacity
                            : Appearance.normalFillOpacity
                    ),
                    in: RoundedRectangle(
                        cornerRadius: Appearance.cornerRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: Appearance.cornerRadius,
                        style: .continuous
                    )
                    .stroke(
                        .red.opacity(Appearance.borderOpacity),
                        lineWidth: Appearance.lineWidth
                    )
                }
        }
    }

    @Environment(\.openSettings) private var openSettings
    @ObservedObject var engine: HoverEngine
    @State private var launchAtLoginEnabled = false
    @State private var loginItemAlert: LoginItemAlert?
    let showPermissions: () -> Void
    let showExtensions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.verticalSpacing) {
            toggleRow(
                String(localized: "Hover Recognition"),
                systemImage: "viewfinder.circle",
                isOn: Binding(
                    get: { engine.isRunning },
                    set: { enabled in
                        guard enabled != engine.isRunning else { return }
                        engine.toggle()
                    }
                )
            )

            toggleRow(
                String(localized: "Open at Login"),
                systemImage: "power",
                isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { enabled in
                        updateLaunchAtLogin(enabled)
                    }
                )
            )

            HStack(spacing: Layout.pairedButtonSpacing) {
                actionButton(String(localized: "Permissions…"), systemImage: "lock.shield", action: showPermissions)
                actionButton(
                    String(localized: "Extensions…"),
                    systemImage: "puzzlepiece.extension",
                    action: showExtensions
                )
            }

            Divider()

            HStack(spacing: Layout.pairedButtonSpacing) {
                actionButton(String(localized: "About Hovery"), systemImage: "info.circle") {
                    NSApp.activate(ignoringOtherApps: true)
                    showAboutPanel()
                }
                actionButton(String(localized: "Settings…"), systemImage: "gearshape") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            Button(role: .destructive) {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Hovery", systemImage: "power")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SubtleDestructiveButtonStyle())
            .keyboardShortcut("q")
        }
        .padding(Layout.contentPadding)
        .frame(width: Layout.windowWidth)
        .onAppear(perform: refreshLaunchAtLoginStatus)
        .alert(item: $loginItemAlert) { alert in
            switch alert {
            case .approvalRequired:
                Alert(
                    title: Text("Approval Required"),
                    message: Text("Allow Hovery in Login Items to open it automatically when you log in."),
                    primaryButton: .default(Text("Open System Settings")) {
                        SMAppService.openSystemSettingsLoginItems()
                    },
                    secondaryButton: .cancel()
                )
            case .failure(let message):
                Alert(
                    title: Text("Couldn’t Update Open at Login"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func toggleRow(
        _ title: String,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: true
        case .notRegistered, .notFound: false
        @unknown default: false
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
            if SMAppService.mainApp.status == .requiresApproval {
                loginItemAlert = .approvalRequired
            }
        } catch {
            refreshLaunchAtLoginStatus()
            if SMAppService.mainApp.status == .requiresApproval {
                loginItemAlert = .approvalRequired
            } else {
                loginItemAlert = .failure(error.localizedDescription)
            }
        }
    }

    private func showAboutPanel() {
        let marketingVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationVersion: marketingVersion,
            .version: ""
        ])
    }
}
