#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import WinstonLogging

/// The Mac's ways to get the debug logs out. The Help menu and Settings both call these.
/// (On iOS, Settings exports the logs to the share sheet.)
enum DebugLogs {
    private static let log = Logger(label: "app.debugLogs")

    /// Opens the Logs folder in Finder. Failures are logged and shown in an alert.
    static func openLogFolder() {
        let folder: URL
        do {
            folder = try LogDirectory.logsDirectoryURL()
        } catch {
            // Codes only: a file error's description can name the folder's path.
            log.error("finding log folder failed", error.logCodes())
            showAlert("Couldn't Open the Log Folder", detail: error.localizedDescription)
            return
        }
        if !NSWorkspace.shared.open(folder) {
            log.error("Finder couldn't open the log folder")
            showAlert("Couldn't Open the Log Folder", detail: "Finder couldn't open it.")
        }
    }

    /// Zips the Logs folder, asks where to save the zip, and copies it there. Failures are logged
    /// and shown in an alert.
    static func export() async {
        let archive: URL
        do {
            archive = try await LogExporter.exportLogs()
        } catch {
            log.error("debug log export failed", error.logCodes())
            showAlert("Couldn't Export Debug Logs", detail: error.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = archive.lastPathComponent
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let destination = panel.url else { return }

        do {
            let fileManager = FileManager.default
            // The save panel has already asked whether to replace an existing file.
            if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: archive, to: destination)
        } catch {
            // Codes only: the description names the file and folder the user chose.
            log.error("saving debug logs failed", error.logCodes())
            showAlert("Couldn't Save Debug Logs", detail: error.localizedDescription)
        }
    }

    private static func showAlert(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }
}
#endif
