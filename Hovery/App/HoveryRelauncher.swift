import AppKit
import OSLog

enum HoveryRelauncher {
    private static let logger = Logger(subsystem: "app.hovery.Hovery", category: "Relaunch")

    /// Quits Hovery and opens it again once this process has exited, for changes that macOS only
    /// applies at launch, such as the interface language.
    @MainActor
    static func relaunch() {
        // Waiting for the exit keeps two instances from recognizing text at the same time.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.1; done
        /usr/bin/open -g "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "relaunch",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path
        ]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            logger.error("Could not relaunch Hovery: \(error.localizedDescription, privacy: .public)")
        }
    }
}
