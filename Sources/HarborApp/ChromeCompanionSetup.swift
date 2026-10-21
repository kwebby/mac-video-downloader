import AppKit
import Foundation
import HarborCore
import Observation

@MainActor @Observable
final class ChromeCompanionSetup {
    enum Status { case notConfigured, awaitingConnection, connected, needsRepair, unavailable }
    static let shared = ChromeCompanionSetup()

    private(set) var status: Status = .notConfigured
    private(set) var isBusy = false
    private(set) var isPrepared = false
    private(set) var chromeAvailable = false
    private(set) var errorMessage: String?
    private(set) var lastVerifiedAt: Date?
    @ObservationIgnored private var monitor: Task<Void, Never>?

    let extensionFolderURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MVD/Chrome Companion", isDirectory: true)

    var isConfigured: Bool { status == .connected }
    var statusTitle: String {
        switch status {
        case .notConfigured: "Set up Chrome"
        case .awaitingConnection: "Waiting for Chrome"
        case .connected: "Installed & configured"
        case .needsRepair: "Chrome setup needs attention"
        case .unavailable: "Companion unavailable"
        }
    }
    var statusDetail: String {
        switch status {
        case .notConfigured: "Add MVD Companion to Chrome to send videos to this app."
        case .awaitingConnection: "In Chrome, load the companion folder and open MVD Companion to verify the connection."
        case .connected: "Chrome Companion is enabled and has connected to this copy of MVD."
        case .needsRepair: "The native host points to another app or extension. Set up Chrome again to repair it."
        case .unavailable: "Open the complete MVD app to set up its bundled Chrome companion."
        }
    }

    init() {
        recheck()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.recheck()
            }
        }
    }

    /// This action only stages files and registers MVD's native host. Chrome
    /// itself asks the user to load and enable the extension.
    func prepareInstallation() {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false; recheck() }
        do {
            let app = try runningApplication()
            guard !app.path.hasPrefix("/Volumes/"), !app.path.contains("/AppTranslocation/") else {
                throw SetupError.message("Move MVD to Applications and open it there before setting up Chrome.")
            }
            guard let source = bundledExtensionFolder else { throw SetupError.missingPayload }
            try validatePayload(at: source)
            let host = app.appendingPathComponent("Contents/MacOS/HarborNativeHost")
            guard FileManager.default.isExecutableFile(atPath: host.path) else { throw SetupError.missingHost }
            try installPayload(from: source, host: host)
            recheck()
            revealExtensionFolder()
            openChromeExtensions()
        } catch { errorMessage = error.localizedDescription }
    }

    func recheck() {
        chromeAvailable = chromeApplicationURL != nil
        isPrepared = (try? validatePayload(at: extensionFolderURL)) != nil
        lastVerifiedAt = nil
        guard let app = try? runningApplication(), let source = bundledExtensionFolder,
              (try? validatePayload(at: source)) != nil else { status = .unavailable; return }
        let host = app.appendingPathComponent("Contents/MacOS/HarborNativeHost").path
        let registrationURL = ChromeCompanionConnection.registrationURL
        guard FileManager.default.fileExists(atPath: registrationURL.path) else { status = .notConfigured; return }
        guard let registration = try? ChromeCompanionConnection.readRegistration(),
              let extensionID = ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: host, allowedIDs: [ChromeCompanionConnection.packagedExtensionID, ChromeCompanionConnection.developmentExtensionID]),
              FileManager.default.isExecutableFile(atPath: host) else { status = .needsRepair; return }
        guard let receipt = try? ChromeCompanionConnection.readReceipt(),
              ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: host) else { status = .awaitingConnection; return }
        lastVerifiedAt = receipt.verifiedAt
        status = .connected
    }

    func openChromeExtensions() {
        errorMessage = nil
        guard let chrome = chromeApplicationURL else { errorMessage = "Install Google Chrome, then return here to finish setup."; return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([URL(string: "chrome://extensions/")!], withApplicationAt: chrome, configuration: configuration) { [weak self] _, error in
            guard let error else { return }
            Task { @MainActor in self?.errorMessage = "Chrome could not open its extensions page: \(error.localizedDescription)" }
        }
    }

    func revealExtensionFolder() {
        guard (try? validatePayload(at: extensionFolderURL)) != nil else { errorMessage = "Set up Chrome first to prepare its companion folder."; return }
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolderURL])
    }

    private var chromeApplicationURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") }
    private var bundledExtensionFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("Chrome Companion/MVD Companion", isDirectory: true) }

    private func runningApplication() throws -> URL {
        let app = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app", ["io.harbor.downloads", "io.harbor.downloads.dev"].contains(Bundle.main.bundleIdentifier ?? "") else { throw SetupError.missingHost }
        return app
    }

    private func validatePayload(at folder: URL) throws {
        let manifest = folder.appendingPathComponent("manifest.json")
        guard try ChromeCompanionConnection.extensionID(forManifestAt: manifest) == ChromeCompanionConnection.packagedExtensionID,
              let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]) else { throw SetupError.missingPayload }
        var bytes = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw SetupError.missingPayload }
            if values.isRegularFile == true { bytes += values.fileSize ?? 0 }
            guard bytes < 10 * 1_024 * 1_024 else { throw SetupError.missingPayload }
        }
        for name in ["background.js", "popup.html", "popup.js", "core.js", "collector.js", "icons/icon-128.png"] {
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) else { throw SetupError.missingPayload }
        }
    }

    private func installPayload(from source: URL, host: URL) throws {
        let files = FileManager.default
        let parent = extensionFolderURL.deletingLastPathComponent()
        if files.fileExists(atPath: parent.path) {
            let attributes = try files.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw SetupError.message("MVD's application-support location must be a normal folder before Chrome setup can continue.")
            }
        }
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".Chrome-Companion-\(UUID().uuidString)")
        let backup = parent.appendingPathComponent(".Chrome-Companion-backup-\(UUID().uuidString)")
        let registrationURL = ChromeCompanionConnection.registrationURL
        let priorRegistration: Data?
        if files.fileExists(atPath: registrationURL.path) {
            let attributes = try files.attributesOfItem(atPath: registrationURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 65_536 else { throw SetupError.message("The Chrome native-host registration cannot be safely replaced. Check its file permissions.") }
            priorRegistration = try Data(contentsOf: registrationURL)
        } else { priorRegistration = nil }
        try files.copyItem(at: source, to: staging)
        defer { try? files.removeItem(at: staging) }
        try validatePayload(at: staging)
        var hasBackup = false
        var replacedFolder = false
        var wroteRegistration = false
        do {
            if files.fileExists(atPath: extensionFolderURL.path) {
                let attributes = try files.attributesOfItem(atPath: extensionFolderURL.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw SetupError.message("The companion folder is not a normal folder. Choose a valid installation before retrying.") }
                // Never replace an unrelated folder merely because it happens
                // to use MVD's destination name.
                try validatePayload(at: extensionFolderURL)
                try files.moveItem(at: extensionFolderURL, to: backup)
                hasBackup = true
            }
            try files.moveItem(at: staging, to: extensionFolderURL)
            replacedFolder = true
            try files.createDirectory(at: registrationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let registration = ChromeCompanionConnection.Registration(hostPath: host.path, extensionID: ChromeCompanionConnection.packagedExtensionID)
            try encoder.encode(registration).write(to: registrationURL, options: .atomic)
            wroteRegistration = true
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: registrationURL.path)
        } catch {
            if replacedFolder { try? files.removeItem(at: extensionFolderURL) }
            if hasBackup { try? files.moveItem(at: backup, to: extensionFolderURL) }
            if wroteRegistration {
                if let priorRegistration { try? priorRegistration.write(to: registrationURL, options: .atomic) }
                else { try? files.removeItem(at: registrationURL) }
            }
            throw error
        }
        if hasBackup { try? files.removeItem(at: backup) }
    }

    private enum SetupError: LocalizedError {
        case missingPayload, missingHost, message(String)
        var errorDescription: String? {
            switch self {
            case .missingPayload: "The bundled Chrome companion is incomplete. Install the complete MVD release and try again."
            case .missingHost: "Open the complete MVD app before setting up Chrome."
            case .message(let message): message
            }
        }
    }
}
