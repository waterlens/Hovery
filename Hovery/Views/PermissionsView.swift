import AppKit
import SwiftUI

private enum PermissionsWindowLayout {
    static let contentWidth: CGFloat = 560
    static let contentHeight: CGFloat = 400
    static let contentSpacing: CGFloat = 18
    static let permissionSpacing: CGFloat = 10
    static let contentPadding: CGFloat = 24
    static let permissionPadding: CGFloat = 14
    static let cornerRadius: CGFloat = 10
    static let iconWidth: CGFloat = 28
    static let descriptionLineLimit = 2
}

struct PermissionsView: View {
    @ObservedObject var engine: HoverEngine
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PermissionsWindowLayout.contentSpacing) {
            VStack(alignment: .leading, spacing: PermissionsWindowLayout.permissionSpacing) {
                Text("Permissions")
                    .font(.title2.bold())
                Text(summary)
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: "Screen & System Audio Recording",
                description: "Lets Hovery read text beneath the pointer.",
                systemImage: "rectangle.dashed.badge.record",
                isAllowed: engine.permissionGranted,
                requestAccess: engine.requestScreenRecordingPermission,
                openSystemSettings: engine.openScreenRecordingSettings
            )

            permissionRow(
                title: "Accessibility",
                description: "Lets Hovery find content beneath the pointer.",
                systemImage: "accessibility",
                isAllowed: engine.accessibilityPermissionGranted,
                requestAccess: engine.requestAccessibilityPermission,
                openSystemSettings: engine.openAccessibilitySettings
            )

            Spacer()

            HStack {
                Button("Check Again") {
                    engine.refreshPermissions()
                }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PermissionsWindowLayout.contentPadding)
        .frame(
            width: PermissionsWindowLayout.contentWidth,
            height: PermissionsWindowLayout.contentHeight
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            engine.refreshPermissions()
        }
    }

    private var summary: String {
        if engine.permissionGranted, engine.accessibilityPermissionGranted {
            return "Hovery has the permissions required for hover recognition."
        }
        return "Hovery needs the following permissions before hover recognition can run."
    }

    private func permissionRow(
        title: String,
        description: String,
        systemImage: String,
        isAllowed: Bool,
        requestAccess: @escaping () -> Void,
        openSystemSettings: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: PermissionsWindowLayout.permissionSpacing) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(isAllowed ? .green : .secondary)
                    .frame(width: PermissionsWindowLayout.iconWidth)

                VStack(alignment: .leading, spacing: PermissionsWindowLayout.permissionSpacing) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(PermissionsWindowLayout.descriptionLineLimit)
                }

                Spacer()

                Label(
                    isAllowed ? "Allowed" : "Not Allowed",
                    systemImage: isAllowed ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
                )
                .foregroundStyle(isAllowed ? .green : .orange)
            }

            HStack {
                Spacer()
                if !isAllowed {
                    Button("Request Access", action: requestAccess)
                }
                Button("Open System Settings", action: openSystemSettings)
            }
        }
        .padding(PermissionsWindowLayout.permissionPadding)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: PermissionsWindowLayout.cornerRadius))
    }
}

@MainActor
final class PermissionsWindowController: NSWindowController {
    private var hasPositionedWindow = false

    init(engine: HoverEngine) {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let hostingController = NSHostingController(
            rootView: PermissionsView(engine: engine, onDone: {})
        )
        window.contentViewController = hostingController
        window.title = "Hovery Permissions"
        window.isReleasedWhenClosed = false
        window.setContentSize(
            NSSize(
                width: PermissionsWindowLayout.contentWidth,
                height: PermissionsWindowLayout.contentHeight
            )
        )
        hostingController.rootView = PermissionsView(
            engine: engine,
            onDone: { [weak window] in window?.performClose(nil) }
        )

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func present() {
        guard let window else { return }
        if !hasPositionedWindow {
            window.center()
            hasPositionedWindow = true
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
