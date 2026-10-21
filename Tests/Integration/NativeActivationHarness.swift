import Foundation
import HarborCore

@main
struct NativeActivationHarness {
    static func main() throws {
        let requestID = UUID().uuidString
        let jobID = UUID()
        let accepted = HostResponse(requestID: requestID, jobID: jobID)
        for command in ["enqueue", "enqueueMedia"] {
            let request = try makeRequest(command, requestID: requestID, gesture: true)
            guard let link = ReviewApplication.acceptedDownloadLink(for: request, response: accepted),
                  let components = URLComponents(url: link, resolvingAgainstBaseURL: false) else {
                fatalError("Explicit accepted download did not produce an activation link")
            }
            require(components.scheme == "harbor-downloads" && components.host == "download", "Activation escaped the internal download route")
            require(components.queryItems == [URLQueryItem(name: "id", value: jobID.uuidString)], "Activation contained anything other than the confirmed job ID")
            require(components.path.isEmpty && components.user == nil && components.password == nil && components.port == nil && components.fragment == nil, "Activation contained untrusted URL components")
            require(ReviewApplication.acceptedDownloadLink(for: request, response: HostResponse(requestID: requestID)) == nil, "Unconfirmed enqueue activated the app")
            require(ReviewApplication.acceptedDownloadLink(for: request, response: HostResponse(requestID: requestID, jobID: jobID, error: "Rejected")) == nil, "Rejected enqueue activated the app")
            require(ReviewApplication.acceptedDownloadLink(for: request, response: HostResponse(requestID: UUID().uuidString, jobID: jobID)) == nil, "An unrelated acknowledgement activated the app")
        }
        for gesture in [nil, false] {
            let request = try makeRequest("enqueue", requestID: requestID, gesture: gesture)
            require(ReviewApplication.acceptedDownloadLink(for: request, response: accepted) == nil, "Automatic direct enqueue stole focus")
        }
        for command in ["hello", "list", "listFolders", "resolveMedia", "openReview"] {
            let request = try makeRequest(command, requestID: requestID, gesture: true)
            require(ReviewApplication.acceptedDownloadLink(for: request, response: accepted) == nil, "Background or preview command activated a download window")
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mvd-activation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = try makeBundle(at: directory.appendingPathComponent("Moved folder/MVD.app"))
        let actualApp = host.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require(try ReviewApplication.bundledApplication(executablePath: host.path) == actualApp, "The containing app could not be resolved after relocation")
        rejects("An external app path was accepted") { try ReviewApplication.bundledApplication(executablePath: "/Applications/Other.app/Contents/MacOS/HarborNativeHost") }
        rejects("A different executable name was accepted") { try ReviewApplication.bundledApplication(executablePath: host.deletingLastPathComponent().appendingPathComponent("MVD").path) }
        let wrongID = try makeBundle(at: directory.appendingPathComponent("Wrong ID/MVD.app"), bundleID: "com.example.other")
        rejects("An app with an unrelated bundle identifier was accepted") { try ReviewApplication.bundledApplication(executablePath: wrongID.path) }
        let missingScheme = try makeBundle(at: directory.appendingPathComponent("Missing scheme/MVD.app"), scheme: "other-app")
        rejects("An app without the internal URL handler was accepted") { try ReviewApplication.bundledApplication(executablePath: missingScheme.path) }
        try FileManager.default.removeItem(at: host.deletingLastPathComponent().appendingPathComponent("MVD"))
        rejects("An incomplete app was accepted") { try ReviewApplication.bundledApplication(executablePath: host.path) }

        print("Native activation policy passed: only explicit, confirmed, correlated downloads activate; previews, background requests and rejected/unconfirmed jobs do not. Exact relocated app validation passed. No app was launched and user Chrome configuration and downloads were untouched.")
    }

    private static func makeRequest(_ command: String, requestID: String, gesture: Bool?) throws -> HostRequest {
        var object: [String: Any] = ["protocolVersion": 1, "requestID": requestID, "command": command]
        if let gesture { object["userGesture"] = gesture }
        if ["enqueue", "enqueueMedia", "resolveMedia", "openReview"].contains(command) {
            object["url"] = "https://example.com/video.mp4"
            object["sourcePageURL"] = "https://example.com/watch?token=not-forwarded"
        }
        if ["enqueue", "enqueueMedia"].contains(command) { object["idempotencyKey"] = UUID().uuidString }
        return try HostRequest.decode(JSONSerialization.data(withJSONObject: object))
    }

    private static func makeBundle(at app: URL, bundleID: String = "io.harbor.downloads.dev", scheme: String = "harbor-downloads") throws -> URL {
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let information: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleExecutable": "MVD", "CFBundlePackageType": "APPL",
                                          "CFBundleURLTypes": [["CFBundleURLSchemes": [scheme]]]]
        try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        for name in ["MVD", "HarborNativeHost"] {
            let executable = macOS.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return macOS.appendingPathComponent("HarborNativeHost")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
    private static func rejects<T>(_ message: String, _ action: () throws -> T) {
        do { _ = try action(); fatalError(message) } catch { }
    }
}
