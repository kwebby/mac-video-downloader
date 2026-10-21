import Foundation
import CryptoKit
import Darwin

/// Evidence from Chrome's authenticated native-messaging transport. This is
/// deliberately separate from merely finding an extension folder on disk.
public enum ChromeCompanionConnection {
    public static let hostName = "io.harbor.downloads"
    public static let packagedExtensionID = "dnnkaphbpckoadcmnfdigcbmdhmidghg"
    public static let developmentExtensionID = "cfkgdgjmdkdmkijinogblongofbamadl"
    public static let maximumReceiptAge: TimeInterval = 90

    public struct Registration: Codable, Equatable {
        public let name: String
        public let description: String
        public let path: String
        public let type: String
        public let allowed_origins: [String]

        public init(hostPath: String, extensionID: String) {
            name = ChromeCompanionConnection.hostName
            description = "MVD desktop download handoff"
            path = hostPath
            type = "stdio"
            allowed_origins = ["chrome-extension://\(extensionID)/"]
        }
    }

    public struct Receipt: Codable, Equatable {
        public let protocolVersion: Int
        public let extensionID: String
        public let hostPath: String
        public let hostProcessID: Int32
        public let verifiedAt: Date

        public init(extensionID: String, hostPath: String, hostProcessID: Int32 = getpid(), verifiedAt: Date = Date()) {
            protocolVersion = 1
            self.extensionID = extensionID
            self.hostPath = hostPath
            self.hostProcessID = hostProcessID
            self.verifiedAt = verifiedAt
        }
    }

    public static var registrationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json")
    }

    public static var receiptURL: URL { HarborPaths.supportDirectory.appendingPathComponent("chrome-companion-connection.json") }

    public static func normalizedOrigin(_ raw: String) -> String? {
        guard raw.range(of: "^chrome-extension://[a-p]{32}/?$", options: .regularExpression) != nil else { return nil }
        return raw.hasSuffix("/") ? raw : raw + "/"
    }

    public static func extensionID(forOrigin origin: String) -> String? {
        guard let normalized = normalizedOrigin(origin) else { return nil }
        return String(normalized.dropFirst("chrome-extension://".count).dropLast())
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func readRegistration(at url: URL = registrationURL) throws -> Registration {
        try JSONDecoder().decode(Registration.self, from: boundedOwnedData(at: url, maximumBytes: 65_536))
    }

    public static func matchingExtensionID(in registration: Registration, hostPath: String, allowedIDs: Set<String>) -> String? {
        guard registration.name == hostName, registration.type == "stdio", registration.path.hasPrefix("/"),
              canonicalPath(registration.path) == canonicalPath(hostPath), registration.allowed_origins.count == 1,
              let extensionID = extensionID(forOrigin: registration.allowed_origins[0]), allowedIDs.contains(extensionID) else { return nil }
        return extensionID
    }

    public static func readReceipt(at url: URL = receiptURL) throws -> Receipt {
        try JSONDecoder().decode(Receipt.self, from: boundedOwnedData(at: url, maximumBytes: 8_192))
    }

    public static func isLive(_ receipt: Receipt, extensionID: String, hostPath: String, now: Date = Date(), processIsAlive: (Int32) -> Bool = { kill($0, 0) == 0 }) -> Bool {
        let age = now.timeIntervalSince(receipt.verifiedAt)
        return receipt.protocolVersion == 1 && receipt.extensionID == extensionID && receipt.hostPath.hasPrefix("/")
            && canonicalPath(receipt.hostPath) == canonicalPath(hostPath) && receipt.hostProcessID > 1
            && age >= -5 && age <= maximumReceiptAge && processIsAlive(receipt.hostProcessID)
    }

    public static func recordHello(origin: String, hostPath: String = CommandLine.arguments[0], at url: URL = receiptURL) throws {
        guard let extensionID = extensionID(forOrigin: origin) else { throw CocoaError(.fileReadCorruptFile) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receipt = Receipt(extensionID: extensionID, hostPath: canonicalPath(hostPath))
        try JSONEncoder().encode(receipt).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The manifest's nonsecret public key fixes the unpacked release's ID.
    public static func extensionID(forManifestAt url: URL) throws -> String {
        guard let object = try JSONSerialization.jsonObject(with: boundedOwnedData(at: url, maximumBytes: 65_536, requireOwner: false)) as? [String: Any],
              object["manifest_version"] as? Int == 3, object["name"] as? String == "MVD Companion",
              let encodedKey = object["key"] as? String, let key = Data(base64Encoded: encodedKey), !key.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return SHA256.hash(data: key).prefix(16).map { byte in
            String(UnicodeScalar(97 + UInt32(byte >> 4))!) + String(UnicodeScalar(97 + UInt32(byte & 15))!)
        }.joined()
    }

    private static func boundedOwnedData(at url: URL, maximumBytes: Int, requireOwner: Bool = true) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumBytes,
              !requireOwner || (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf: url)
    }
}
