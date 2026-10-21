import XCTest
import Darwin
@testable import HarborCore

final class ChromeCompanionConnectionTests: XCTestCase {
    private let extensionID = ChromeCompanionConnection.packagedExtensionID
    private let hostPath = "/Applications/MVD.app/Contents/MacOS/HarborNativeHost"

    func testRegistrationRequiresExactHostAndKnownSingleOrigin() {
        let registration = ChromeCompanionConnection.Registration(hostPath: hostPath, extensionID: extensionID)
        XCTAssertEqual(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: hostPath, allowedIDs: [extensionID]), extensionID)
        XCTAssertNil(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: "/tmp/MVD.app/Contents/MacOS/HarborNativeHost", allowedIDs: [extensionID]))
        XCTAssertNil(ChromeCompanionConnection.matchingExtensionID(in: registration, hostPath: hostPath, allowedIDs: [ChromeCompanionConnection.developmentExtensionID]))
        XCTAssertNil(ChromeCompanionConnection.extensionID(forOrigin: "chrome-extension://\(extensionID)/popup.html"))
        XCTAssertNil(ChromeCompanionConnection.extensionID(forOrigin: "https://\(extensionID)/"))
    }

    func testReceiptRequiresRecentLiveProcessAndMatchingIdentity() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let receipt = ChromeCompanionConnection.Receipt(extensionID: extensionID, hostPath: hostPath, hostProcessID: 123, verifiedAt: now)
        XCTAssertTrue(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: hostPath, now: now, processIsAlive: { $0 == 123 }))
        XCTAssertFalse(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: hostPath, now: now, processIsAlive: { _ in false }))
        XCTAssertFalse(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: hostPath, now: now.addingTimeInterval(91), processIsAlive: { _ in true }))
        XCTAssertFalse(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: hostPath, now: now.addingTimeInterval(-10), processIsAlive: { _ in true }))
        XCTAssertFalse(ChromeCompanionConnection.isLive(receipt, extensionID: ChromeCompanionConnection.developmentExtensionID, hostPath: hostPath, now: now, processIsAlive: { _ in true }))
        XCTAssertFalse(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: "/other/MVD.app/Contents/MacOS/HarborNativeHost", now: now, processIsAlive: { _ in true }))
    }

    func testReceiptRoundTripIsPrivateAndRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mvd-companion-receipt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let receiptURL = directory.appendingPathComponent("connection.json")
        try ChromeCompanionConnection.recordHello(origin: "chrome-extension://\(extensionID)/", hostPath: hostPath, at: receiptURL)
        let receipt = try ChromeCompanionConnection.readReceipt(at: receiptURL)
        XCTAssertEqual(receipt.extensionID, extensionID)
        XCTAssertEqual(receipt.hostProcessID, getpid())
        XCTAssertTrue(ChromeCompanionConnection.isLive(receipt, extensionID: extensionID, hostPath: hostPath))
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: receiptURL)
        XCTAssertThrowsError(try ChromeCompanionConnection.readReceipt(at: link))
    }

    func testReleaseKeyMatchesFixedID() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let key = try String(contentsOf: root.appendingPathComponent("Packaging/Extension/public-key.b64"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mvd-companion-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "MVD Companion", "key": key]).write(to: manifest)
        XCTAssertEqual(try ChromeCompanionConnection.extensionID(forManifestAt: manifest), extensionID)
        try JSONSerialization.data(withJSONObject: ["manifest_version": 3, "name": "MVD Companion"]).write(to: manifest)
        XCTAssertThrowsError(try ChromeCompanionConnection.extensionID(forManifestAt: manifest))
    }
}
