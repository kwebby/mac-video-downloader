import Foundation
import AppKit

enum ReviewApplication {
    /// Resolve the app containing this host. Never ask Launch Services to pick a
    /// default handler, accept an app path from Chrome, or launch an arbitrary URL.
    static func bundledApplication(executablePath: String = CommandLine.arguments[0]) throws -> URL {
        let executable = URL(fileURLWithPath: executablePath).standardizedFileURL.resolvingSymlinksInPath()
        let macOS = executable.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "HarborNativeHost", macOS.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents", app.lastPathComponent == "MVD.app",
              FileManager.default.isExecutableFile(atPath: macOS.appendingPathComponent("MVD").path),
              let bundle = Bundle(url: app),
              ["io.harbor.downloads", "io.harbor.downloads.dev"].contains(bundle.bundleIdentifier ?? ""),
              let urlTypes = bundle.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]],
              urlTypes.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains("harbor-downloads") == true }) else { throw ReviewApplicationError.unavailable }
        return app
    }

    @MainActor
    static func open(_ request: HostRequest) async throws {
        let link = try request.validatedReviewLink()
        let app = try bundledApplication()
        try await open(link, in: app)
    }

    /// A notification about a confirmed job, never another enqueue instruction.
    /// Browser scans, previews, unacknowledged requests and automatic handoffs
    /// cannot bring the desktop app forward through this path.
    static func acceptedDownloadLink(for request: HostRequest, response: HostResponse) -> URL? {
        guard request.userGesture == true,
              ["enqueue", "enqueueMedia"].contains(request.command),
              response.requestID == request.requestID, response.error == nil,
              let jobID = response.jobID else { return nil }
        var components = URLComponents()
        components.scheme = "harbor-downloads"
        components.host = "download"
        components.queryItems = [URLQueryItem(name: "id", value: jobID.uuidString)]
        return components.url
    }

    @MainActor
    static func openAcceptedDownload(_ request: HostRequest, response: HostResponse) async throws {
        guard let link = acceptedDownloadLink(for: request, response: response) else { return }
        let app = try bundledApplication()
        try await open(link, in: app)
    }

    @MainActor
    private static func open(_ link: URL, in app: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        _ = try await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
    }
}

enum ReviewApplicationError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Package and register the complete MVD.app to open it from Chrome." }
}
