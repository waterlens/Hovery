import AppKit
import Combine
import SwiftUI

@main
struct HoveryApp: App {
    @NSApplicationDelegateAdaptor(HoveryAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(
                engine: appDelegate.engine,
                showPermissions: appDelegate.showPermissionsWindow,
                showExtensions: appDelegate.showExtensionsWindow
            )
        } label: {
            Label("Hovery", image: "MenuBarIcon")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: appDelegate.settings)
        }
    }
}

@MainActor
final class HoveryAppDelegate: NSObject, NSApplicationDelegate {
    let settings: HoverySettings
    let engine: HoverEngine
    private lazy var permissionsWindowController = PermissionsWindowController(engine: engine)
    private lazy var extensionsWindowController = ExtensionsWindowController(
        manager: engine.webExtensions
    )
    private var permissionsCancellable: AnyCancellable?

    override init() {
        let settings = HoverySettings()
        self.settings = settings
        engine = HoverEngine(settings: settings)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            engine.start()
            observePermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    func showPermissionsWindow() {
        permissionsWindowController.present()
    }

    func showExtensionsWindow() {
        extensionsWindowController.present()
    }

    private func observePermissions() {
        permissionsCancellable = Publishers.CombineLatest(
            engine.$permissionGranted,
            engine.$accessibilityPermissionGranted
        )
        .map { screenRecordingAllowed, accessibilityAllowed in
            screenRecordingAllowed && accessibilityAllowed
        }
        .removeDuplicates()
        .sink { [weak self] allPermissionsAllowed in
            guard !allPermissionsAllowed else { return }
            self?.showPermissionsWindow()
        }
    }
}
