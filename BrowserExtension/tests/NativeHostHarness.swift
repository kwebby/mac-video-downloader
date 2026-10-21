import Foundation
import HarborCore

@main
struct NativeHostHarness {
    static func require(_ condition: Bool, _ message: String) { if !condition { fatalError(message) } }
    static func decode(_ values: [String: Any]) throws -> HostRequest { try HostRequest.decode(JSONSerialization.data(withJSONObject: values)) }
    static func main() throws {
        let requestID = UUID().uuidString
        let target = "https://8.8.8.8/master.m3u8?signature=a%2Fb&list=x+y#fragment"
        let source = "https://1.1.1.1/watch?id=video&context=%2F"
        let review: [String: Any] = ["protocolVersion": 1, "requestID": requestID, "command": "openReview", "url": target, "sourcePageURL": source]
        let request = try decode(review)
        let link = try request.validatedReviewLink()
        let components = URLComponents(url: link, resolvingAgainstBaseURL: false)!
        require(components.scheme == "harbor-downloads" && components.host == "review", "Review must use only the fixed MVD scheme/route")
        require(components.queryItems?.first(where: { $0.name == "url" })?.value == target, "Signed target URL changed in deep-link encoding")
        require(components.queryItems?.first(where: { $0.name == "sourcePageURL" })?.value == source, "Source context changed in deep-link encoding")
        for invalid in [review.merging(["appPath": "/tmp/Other.app"]) { _, right in right }, review.merging(["command": "execute"]) { _, right in right }, review.merging(["idempotencyKey": UUID().uuidString]) { _, right in right }, review.merging(["requestID": "not-a-uuid"]) { _, right in right }, review.merging(["protocolVersion": 2]) { _, right in right }] {
            var rejected = false; do { _ = try decode(invalid) } catch { rejected = true }; require(rejected, "Host accepted forbidden command fields/schema")
        }
        for forbidden in ["https://youtube.com/watch?v=x", "https://r1.googlevideo.com/a", "http://127.0.0.1/a", "file:///tmp/a"] {
            var rejected = false; do { _ = try decode(review.merging(["url": forbidden]) { _, right in right }).validatedReviewLink() } catch { rejected = true }; require(rejected, "Review bypassed target URL policy")
            rejected = false; do { _ = try decode(review.merging(["sourcePageURL": forbidden]) { _, right in right }).validatedReviewLink() } catch { rejected = true }; require(rejected, "Review bypassed page URL policy")
        }
        let enqueue = try decode(["protocolVersion": 1, "requestID": requestID, "command": "enqueue", "url": "https://8.8.8.8/a.mp4", "sourcePageURL": source, "idempotencyKey": UUID().uuidString])
        require(try enqueue.brokerRequest().browserInitiated == true, "Direct browser jobs lost their network policy marker")
        let response = HostResponse(requestID: requestID, opened: true)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as! [String: Any]
        require(encoded["opened"] as? Bool == true && encoded["jobID"] == nil && encoded["jobs"] == nil, "Review response falsely claims a durable job")
        require(encoded["serviceVersion"] as? String == HarborBuild.serviceVersion, "Host/service handshake version mismatched")
        let media: [String: Any] = ["protocolVersion": 1, "requestID": requestID, "command": "resolveMedia", "url": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "sourcePageURL": "https://www.youtube.com/watch?v=jNQXAC9IVRw", "userGesture": true]
        let resolution = try decode(media).brokerRequest()
        require(resolution.command == .resolveMedia && resolution.kind == .media && resolution.browserInitiated == true && resolution.browserMediaAuthorized == true, "Explicit private media preview lost its provider routing, authorization or command")
        for invalid in [media.merging(["userGesture": false]) { _, right in right }, media.merging(["destinationDirectory": "/Users/private"]) { _, right in right }, media.merging(["options": ["exec": "bad"]]) { _, right in right }] {
            var rejected = false; do { _ = try decode(invalid) } catch { rejected = true }; require(rejected, "Media preview accepted missing consent, filesystem paths or arbitrary options")
        }
        for forbidden in ["http://127.0.0.1/video", "http://10.0.0.1/video", "file:///tmp/a"] {
            var rejected = false; do { _ = try decode(media.merging(["url": forbidden]) { _, right in right }).brokerRequest() } catch { rejected = true }; require(rejected, "Private media consent bypassed public network checks")
        }
        let folderID = UUID()
        let mediaEnqueue = media.merging(["command": "enqueueMedia", "idempotencyKey": UUID().uuidString, "folderID": folderID.uuidString, "options": ["mode": "audioOnly", "audioFormat": "mp3", "audioBitrateKbps": 128], "quality": ["id": "best", "label": "Best available"]]) { _, right in right }
        let accepted = try decode(mediaEnqueue).brokerRequest()
        require(accepted.command == .enqueue && accepted.kind == .media && accepted.folderID == folderID && accepted.options?.mode == .audioOnly && accepted.options?.audioBitrateKbps == 128 && accepted.destinationDirectory == nil && accepted.browserMediaAuthorized == true, "Validated media choices or opaque folder ID were not forwarded")
        let directResolution = try decode(media.merging(["url": "https://8.8.8.8/video.mp4"]) { _, right in right }).brokerRequest()
        require(directResolution.kind == .media, "Browser video preview fell through the synthetic direct-file fast path")
        for options: [String: Any] in [["mode": "execute"], ["formatID": "--exec=bad"], ["formatID": "137+ba"], ["container": "/tmp/path"], ["mode": "audioOnly", "audioFormat": "original", "audioBitrateKbps": 128], ["mode": "audioOnly", "audioFormat": "mp3", "audioBitrateKbps": 999]] {
            var rejected = false; do { _ = try decode(mediaEnqueue.merging(["options": options]) { _, right in right }) } catch { rejected = true }; require(rejected, "Host accepted an invalid media mode, format selector, output path or bitrate")
        }
        var rejectedQuality = false; do { _ = try decode(mediaEnqueue.merging(["quality": ["id": "720p", "label": "720p", "height": 1080]]) { _, right in right }) } catch { rejectedQuality = true }; require(rejectedQuality, "Host accepted a contradictory quality selection")
        let folders = HostResponse(requestID: requestID, folders: [HostFolder(DownloadFolder(id: folderID, name: "Learning", path: "/Users/private/learning", icon: "book", colorHex: "#16874B"))], defaultFolderName: "Default download folder", mediaPanelAvailable: true)
        let folderJSON = try JSONEncoder().encode(folders)
        require(!String(decoding: folderJSON, as: UTF8.self).contains("/Users/private"), "Native folder list leaked an absolute filesystem path")
        let largeFormats = (0..<512).map { index in MediaFormatChoice(id: "\(index)", label: String(repeating: "🟢", count: 240), hasVideo: true, hasAudio: false) }
        let large = HostResponse(requestID: requestID, mediaPreview: MediaPreview(title: "Owned video", qualities: [.best, VideoQuality(id: "720p", label: "720p", height: 720)], formats: largeFormats)).bounded()
        require(try JSONEncoder().encode(large).count < NativeMessageFraming.maximumBytes, "Large real format metadata exceeds native framing")
        require(large.previewTruncated == true && large.mediaPreview?.qualities.count == 2 && (large.mediaPreview?.formats.count ?? 0) > 0, "Metadata trimming invented choices or lost available qualities")
        let redacted = HostErrorSanitizer.message("Could not write /Volumes/Private Folder/video.mp4 at https://site.test/x?token=secret")
        require(!redacted.contains("Private Folder") && !redacted.contains("token=secret"), "Broker errors leaked paths or signed URLs")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("MVD.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "io.harbor.downloads.dev", "CFBundleExecutable": "MVD", "CFBundlePackageType": "APPL", "CFBundleName": "MVD", "CFBundleURLTypes": [["CFBundleURLSchemes": ["harbor-downloads"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("MVD")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let resolved = try ReviewApplication.bundledApplication(executablePath: macOS.appendingPathComponent("HarborNativeHost").path)
        require(resolved == app.standardizedFileURL.resolvingSymlinksInPath(), "Host did not select its exact containing app")
        var rejected = false; do { _ = try ReviewApplication.bundledApplication(executablePath: directory.appendingPathComponent("HarborNativeHost").path) } catch { rejected = true }; require(rejected, "Unpackaged host resolved an arbitrary handler")
        print("Native host: strict consent/schema, private provider opt-in, public network policy, validated media options, opaque folders, bounded format metadata, redacted errors, signed URL encoding and exact app selection passed. No app was launched.")
    }
}
