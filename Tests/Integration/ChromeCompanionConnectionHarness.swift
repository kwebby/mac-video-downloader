import Foundation
import Darwin
import HarborCore

@main
struct ChromeCompanionConnectionHarness {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mvd-connection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = ChromeCompanionConnection.packagedExtensionID
        let origin = "chrome-extension://\(id)/"
        let host = directory.appendingPathComponent("Moved folder/MVD.app/Contents/MacOS/HarborNativeHost").path
        let registrationURL = directory.appendingPathComponent("registration.json")
        let registration = ChromeCompanionConnection.Registration(hostPath: host, extensionID: id)
        try JSONEncoder().encode(registration).write(to: registrationURL)
        try require(try HostRegistration.validateCaller(arguments: [host, origin], registrationURL: registrationURL) == origin, "Exact Chrome caller was not accepted")
        rejects("Different extension accepted") { try HostRegistration.validateCaller(arguments: [host, "chrome-extension://\(ChromeCompanionConnection.developmentExtensionID)/"], registrationURL: registrationURL) }
        rejects("Other app accepted") { try HostRegistration.validateCaller(arguments: ["/tmp/other.app/Contents/MacOS/HarborNativeHost", origin], registrationURL: registrationURL) }
        rejects("Web origin accepted") { try HostRegistration.validateCaller(arguments: [host, "https://example.com/"], registrationURL: registrationURL) }
        rejects("Unexpected browser argument accepted") { try HostRegistration.validateCaller(arguments: [host, origin, "extra"], registrationURL: registrationURL) }
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as! [String: Any]
        object["allowed_origins"] = [origin, "chrome-extension://\(ChromeCompanionConnection.developmentExtensionID)/"]
        try JSONSerialization.data(withJSONObject: object).write(to: registrationURL)
        rejects("Multiple allowed origins accepted") { try HostRegistration.validateCaller(arguments: [host, origin], registrationURL: registrationURL) }
        try JSONEncoder().encode(registration).write(to: registrationURL)
        require(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: host, allowedIDs: [id]) == id, "Valid registration was not recognized")
        require(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: host + "-old", allowedIDs: [id]) == nil, "Wrong app path was recognized")
        require(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: host, allowedIDs: [ChromeCompanionConnection.developmentExtensionID]) == nil, "Wrong release ID was recognized")

        let receiptURL = directory.appendingPathComponent("state/connection.json")
        try ChromeCompanionConnection.recordHello(origin: origin, hostPath: host, at: receiptURL)
        let receipt = try ChromeCompanionConnection.readReceipt(at: receiptURL)
        require(ChromeCompanionConnection.isLive(receipt, extensionID: id, hostPath: host), "Fresh live receipt was not recognized")
        require(!ChromeCompanionConnection.isLive(receipt, extensionID: id, hostPath: host, processIsAlive: { _ in false }), "Dead host counted as configured")
        require(!ChromeCompanionConnection.isLive(receipt, extensionID: id, hostPath: host, now: receipt.verifiedAt.addingTimeInterval(91)), "Expired heartbeat counted as configured")
        require(!ChromeCompanionConnection.isLive(receipt, extensionID: id, hostPath: host, now: receipt.verifiedAt.addingTimeInterval(-10)), "Future heartbeat counted as configured")
        require(!ChromeCompanionConnection.isLive(receipt, extensionID: id, hostPath: host + "-old"), "Moved app retained old receipt")
        require(!ChromeCompanionConnection.isLive(receipt, extensionID: ChromeCompanionConnection.developmentExtensionID, hostPath: host), "Different extension retained receipt")
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Receipt is not private")
        let link = directory.appendingPathComponent("receipt-link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: receiptURL)
        rejects("Symbolic-link receipt accepted") { try ChromeCompanionConnection.readReceipt(at: link) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run(); child.waitUntilExit()
        let deadReceipt = ChromeCompanionConnection.Receipt(extensionID: id, hostPath: host, hostProcessID: child.processIdentifier)
        require(!ChromeCompanionConnection.isLive(deadReceipt, extensionID: id, hostPath: host), "Exited native host retained configured tick")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let key = try String(contentsOf: root.appendingPathComponent("Packaging/Extension/public-key.b64"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "MVD Companion", "key": key]).write(to: manifest)
        try require(try ChromeCompanionConnection.extensionID(forManifestAt: manifest) == id, "Packaged public key has wrong extension ID")
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "MVD Companion"]).write(to: manifest)
        rejects("Unkeyed payload accepted") { try ChromeCompanionConnection.extensionID(forManifestAt: manifest) }
        print("Chrome connection state passed: exact native caller and moved app binding, stable release ID, live/expired/dead host receipts, private bounded files and symlink rejection. User Chrome registration and queue were untouched.")
    }

    private static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        if try !condition() { fatalError(message) }
    }
    private static func rejects<T>(_ message: String, _ action: () throws -> T) {
        do { _ = try action(); fatalError(message) } catch { }
    }
}
