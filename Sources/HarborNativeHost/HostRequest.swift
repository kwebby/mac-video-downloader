import Foundation
import HarborCore

struct HostRequest: Decodable {
    let protocolVersion: Int
    let requestID: String
    let command: String
    let url: String?
    let sourcePageURL: String?
    let idempotencyKey: String?
    let userGesture: Bool?
    let options: DownloadOptions?
    let quality: VideoQuality?
    let folderID: UUID?
    let pageOffset: Int?

    static func decode(_ payload: Data) throws -> HostRequest {
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              Set(object.keys).isSubset(of: ["protocolVersion", "requestID", "command", "url", "sourcePageURL", "idempotencyKey", "userGesture", "options", "quality", "folderID", "pageOffset"]) else { throw NativeMessageError.invalidRequest }
        if let options = object["options"] as? [String: Any], !Set(options.keys).isSubset(of: ["mode", "formatID", "container", "audioFormat", "audioBitrateKbps", "accelerated"]) { throw NativeMessageError.invalidRequest }
        if let quality = object["quality"] as? [String: Any], !Set(quality.keys).isSubset(of: ["id", "label", "height"]) { throw NativeMessageError.invalidRequest }
        let request = try JSONDecoder().decode(HostRequest.self, from: payload)
        guard request.protocolVersion == 1, UUID(uuidString: request.requestID) != nil,
              ["hello", "list", "listFolders", "resolveMedia", "enqueue", "enqueueMedia", "openReview"].contains(request.command),
              (request.pageOffset ?? 0) >= 0 else { throw NativeMessageError.invalidRequest }
        switch request.command {
        case "enqueue", "enqueueMedia":
            guard request.url != nil, request.sourcePageURL != nil,
                  let key = request.idempotencyKey, UUID(uuidString: key) != nil,
                  request.pageOffset == nil else { throw NativeMessageError.invalidRequest }
            if request.command == "enqueueMedia" || request.options != nil || request.quality != nil || request.folderID != nil {
                guard request.userGesture == true else { throw NativeMessageError.invalidRequest }
            }
        case "resolveMedia":
            guard request.url != nil, request.sourcePageURL != nil, request.userGesture == true,
                  request.idempotencyKey == nil, request.options == nil, request.quality == nil,
                  request.folderID == nil, request.pageOffset == nil else { throw NativeMessageError.invalidRequest }
        case "openReview":
            guard request.url != nil, request.sourcePageURL != nil, request.idempotencyKey == nil,
                  request.options == nil, request.quality == nil, request.folderID == nil, request.pageOffset == nil else { throw NativeMessageError.invalidRequest }
        default:
            guard request.url == nil, request.sourcePageURL == nil, request.idempotencyKey == nil,
                  request.options == nil, request.quality == nil, request.folderID == nil,
                  request.command == "list" || request.pageOffset == nil else { throw NativeMessageError.invalidRequest }
        }
        if let options = request.options {
            guard ["auto", "mp4", "mkv", "webm"].contains(options.container), ["original", "m4a", "mp3", "opus", "wav", "flac"].contains(options.audioFormat) else { throw NativeMessageError.invalidRequest }
            if let id = options.formatID {
                guard id.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else { throw NativeMessageError.invalidRequest }
            }
            if let bitrate = options.audioBitrateKbps {
                guard options.mode == .audioOnly, ["m4a", "mp3", "opus"].contains(options.audioFormat), (64...320).contains(bitrate) else { throw NativeMessageError.invalidRequest }
            }
            if options.mode == .audioOnly { guard options.container == "auto" else { throw NativeMessageError.invalidRequest } }
            else { guard options.audioFormat == "original", options.audioBitrateKbps == nil else { throw NativeMessageError.invalidRequest } }
        }
        if let quality = request.quality {
            if quality.id == "best" { guard quality.height == nil else { throw NativeMessageError.invalidRequest } }
            else {
                guard let height = quality.height, (1...8_640).contains(height), quality.id == "\(height)p" else { throw NativeMessageError.invalidRequest }
            }
        }
        return request
    }

    static func validRequestID(in payload: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = object["requestID"] as? String, UUID(uuidString: id) != nil else { return "" }
        return id
    }

    func validatedReviewLink() throws -> URL {
        guard command == "openReview", let url, let sourcePageURL else { throw NativeMessageError.invalidRequest }
        let source = try PublicNetworkPolicy.validate(sourcePageURL, allowVideoProviders: userGesture == true)
        let target = try PublicNetworkPolicy.validate(url, allowVideoProviders: userGesture == true)
        var components = URLComponents()
        components.scheme = "harbor-downloads"
        components.host = "review"
        components.queryItems = [URLQueryItem(name: "url", value: target), URLQueryItem(name: "sourcePageURL", value: source)]
        guard let link = components.url else { throw NativeMessageError.invalidRequest }
        return link
    }

    func brokerRequest() throws -> BrokerRequest {
        if ["enqueue", "enqueueMedia", "resolveMedia"].contains(command) {
            guard let url, let sourcePageURL else { throw NativeMessageError.invalidRequest }
            let authorized = userGesture == true
            _ = try PublicNetworkPolicy.validate(sourcePageURL, allowVideoProviders: authorized)
            let target = try PublicNetworkPolicy.validate(url, allowVideoProviders: authorized)
            let mediaKind: DownloadKind? = command == "resolveMedia" || command == "enqueueMedia" || quality?.height != nil ? .media : nil
            return BrokerRequest(command: command == "resolveMedia" ? .resolveMedia : .enqueue, url: target,
                                 idempotencyKey: idempotencyKey, kind: mediaKind, requestID: requestID, browserInitiated: true,
                                 quality: quality, options: options, folderID: folderID,
                                 browserMediaAuthorized: authorized)
        }
        let command: BrokerCommand
        switch self.command {
        case "hello", "listFolders": command = .hello
        case "list": command = .list
        default: throw NativeMessageError.invalidRequest
        }
        return BrokerRequest(command: command, requestID: requestID, pageOffset: pageOffset)
    }
}

/// Browser responses intentionally omit absolute destinations, settings, source
/// URLs, headers, proxies, and executable paths. Managed folders use opaque IDs.
struct HostResponse: Encodable {
    var protocolVersion = 1
    let requestID: String
    var jobID: UUID?
    var jobs: [HostJob]?
    var error: String?
    var opened: Bool?
    var reviewAvailable: Bool?
    var nextPageOffset: Int?
    var totalJobCount: Int?
    var mediaPreview: MediaPreview?
    var folders: [HostFolder]?
    var defaultFolderName: String?
    var mediaPanelAvailable: Bool?
    var commands: [String]?
    var previewTruncated: Bool?
    var serviceVersion = HarborBuild.serviceVersion
    var appVersion = HarborBuild.serviceVersion

    init(requestID: String, jobID: UUID? = nil, jobs: [HostJob]? = nil, error: String? = nil, opened: Bool? = nil, reviewAvailable: Bool? = nil, nextPageOffset: Int? = nil, totalJobCount: Int? = nil, mediaPreview: MediaPreview? = nil, folders: [HostFolder]? = nil, defaultFolderName: String? = nil, mediaPanelAvailable: Bool? = nil, commands: [String]? = nil) {
        self.requestID = requestID; self.jobID = jobID; self.jobs = jobs; self.error = error
        self.opened = opened; self.reviewAvailable = reviewAvailable
        self.nextPageOffset = nextPageOffset; self.totalJobCount = totalJobCount
        self.mediaPreview = mediaPreview; self.folders = folders; self.defaultFolderName = defaultFolderName
        self.mediaPanelAvailable = mediaPanelAvailable; self.commands = commands
    }

    func bounded() -> HostResponse {
        var value = self
        while let data = try? JSONEncoder().encode(value), data.count > 240 * 1024 {
            if !(value.mediaPreview?.formats.isEmpty ?? true) { value.mediaPreview?.formats.removeLast(); value.previewTruncated = true }
            else if (value.mediaPreview?.qualities.count ?? 0) > 1 { value.mediaPreview?.qualities.removeLast(); value.previewTruncated = true }
            else {
                value.mediaPreview = nil
                value.error = "This video's information is too large for the companion. Open it in MVD."
                break
            }
        }
        return value
    }
}

struct HostFolder: Encodable {
    let id: UUID
    let name: String
    let icon: String
    let colorHex: String?
    init(_ folder: DownloadFolder) {
        id = folder.id; name = String(folder.name.prefix(80)); icon = String(folder.icon.prefix(80)); colorHex = folder.colorHex
    }
}

struct HostJob: Encodable {
    let id: UUID
    let status: String
    let progress: Double?
    init(_ job: DownloadJob) { id = job.id; status = job.status.rawValue; progress = job.progress }
}

enum HostErrorSanitizer {
    static func message(_ raw: String) -> String {
        var result = raw
        for pattern in [#"https?://[^\s\"'<>]+"#, #"(?<![A-Za-z0-9:])(?:file://)?/[^\r\n\"<>]*"#, #"(?i)(authorization|cookie|token|password)\s*[:=]\s*[^\s]+"#] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        return String(result.prefix(600))
    }
}
