import Foundation

public enum HarborBuild {
    public static let serviceVersion = "0.4.0"
}

public enum JobStatus: String, Codable, Sendable, CaseIterable {
    case queued, resolving, downloading, paused, processing, completed, failed, cancelled
    public var isActive: Bool { [.resolving, .downloading, .processing].contains(self) }
    public var label: String { rawValue.capitalized }
}

public enum DownloadKind: String, Codable, Sendable { case automatic, direct, media }

public struct VideoQuality: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var height: Int?
    public init(id: String, label: String, height: Int? = nil) { self.id = id; self.label = label; self.height = height }
    public static let best = VideoQuality(id: "best", label: "Best available")
}

public enum MediaMode: String, Codable, Equatable, Sendable, CaseIterable { case videoWithAudio, videoOnly, audioOnly }

public struct DownloadOptions: Codable, Equatable, Sendable {
    public var mode: MediaMode
    public var formatID: String?
    public var container: String
    public var audioFormat: String
    public var audioBitrateKbps: Int?
    public var accelerated: Bool
    public init(mode: MediaMode = .videoWithAudio, formatID: String? = nil, container: String = "auto", audioFormat: String = "original", audioBitrateKbps: Int? = nil, accelerated: Bool = false) {
        self.mode = mode; self.formatID = formatID; self.container = container; self.audioFormat = audioFormat
        self.audioBitrateKbps = audioBitrateKbps; self.accelerated = accelerated
    }
    private enum CodingKeys: String, CodingKey { case mode, formatID, container, audioFormat, audioBitrateKbps, accelerated }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(MediaMode.self, forKey: .mode) ?? .videoWithAudio
        formatID = try values.decodeIfPresent(String.self, forKey: .formatID)
        container = try values.decodeIfPresent(String.self, forKey: .container) ?? "auto"
        audioFormat = try values.decodeIfPresent(String.self, forKey: .audioFormat) ?? "original"
        audioBitrateKbps = try values.decodeIfPresent(Int.self, forKey: .audioBitrateKbps)
        accelerated = try values.decodeIfPresent(Bool.self, forKey: .accelerated) ?? false
    }
}

public struct MediaFormatChoice: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var height: Int?
    public var width: Int?
    public var fps: Double?
    public var videoCodec: String?
    public var audioCodec: String?
    public var container: String?
    public var videoBitrateKbps: Double?
    public var audioBitrateKbps: Double?
    public var fileSize: Int64?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public init(id: String, label: String, height: Int? = nil, width: Int? = nil, fps: Double? = nil, videoCodec: String? = nil, audioCodec: String? = nil, container: String? = nil, videoBitrateKbps: Double? = nil, audioBitrateKbps: Double? = nil, fileSize: Int64? = nil, hasVideo: Bool, hasAudio: Bool) {
        self.id = id; self.label = label; self.height = height; self.width = width; self.fps = fps
        self.videoCodec = videoCodec; self.audioCodec = audioCodec; self.container = container
        self.videoBitrateKbps = videoBitrateKbps; self.audioBitrateKbps = audioBitrateKbps; self.fileSize = fileSize
        self.hasVideo = hasVideo; self.hasAudio = hasAudio
    }
}

public struct DownloadFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    public var icon: String
    public var colorHex: String?
    public init(id: UUID = UUID(), name: String, path: String, icon: String = "folder", colorHex: String? = nil) {
        self.id = id; self.name = name; self.path = path; self.icon = icon; self.colorHex = colorHex
    }
}

public struct MediaPreview: Codable, Equatable, Sendable {
    public var title: String
    public var thumbnailURL: String?
    public var duration: Double?
    public var qualities: [VideoQuality]
    public var isDirectFile: Bool
    public var formats: [MediaFormatChoice]
    public init(title: String, thumbnailURL: String? = nil, duration: Double? = nil, qualities: [VideoQuality] = [.best], isDirectFile: Bool = false, formats: [MediaFormatChoice] = []) {
        self.title = title; self.thumbnailURL = thumbnailURL; self.duration = duration
        self.qualities = qualities; self.isDirectFile = isDirectFile
        self.formats = formats
    }
    private enum CodingKeys: String, CodingKey { case title, thumbnailURL, duration, qualities, isDirectFile, formats }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        thumbnailURL = try values.decodeIfPresent(String.self, forKey: .thumbnailURL)
        duration = try values.decodeIfPresent(Double.self, forKey: .duration)
        qualities = try values.decodeIfPresent([VideoQuality].self, forKey: .qualities) ?? [.best]
        isDirectFile = try values.decodeIfPresent(Bool.self, forKey: .isDirectFile) ?? false
        formats = try values.decodeIfPresent([MediaFormatChoice].self, forKey: .formats) ?? []
    }
}

public struct DownloadJob: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var sourceURL: String
    public var title: String
    public var filename: String
    public var destinationDirectory: String
    public var outputPath: String?
    public var status: JobStatus
    public var kind: DownloadKind
    public var bytesReceived: Int64
    public var totalBytes: Int64?
    public var bytesPerSecond: Double
    public var errorMessage: String?
    public var createdAt: Date
    public var completedAt: Date?
    public var idempotencyKey: String
    public var browserInitiated: Bool?
    public var browserMediaAuthorized: Bool?
    public var quality: VideoQuality?
    public var thumbnailURL: String?
    public var duration: Double?
    public var options: DownloadOptions?
    public var folderID: UUID?
    public var progress: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(bytesReceived) / Double(totalBytes)))
    }
    public init(id: UUID = UUID(), sourceURL: String, title: String = "", filename: String = "", destinationDirectory: String, kind: DownloadKind = .automatic, idempotencyKey: String = UUID().uuidString) {
        self.id = id; self.sourceURL = sourceURL; self.title = title; self.filename = filename
        self.destinationDirectory = destinationDirectory; self.kind = kind; self.idempotencyKey = idempotencyKey
        self.status = .queued; self.bytesReceived = 0; self.bytesPerSecond = 0; self.createdAt = Date()
    }
}

public struct DownloadSettings: Codable, Equatable, Sendable {
    public var destinationDirectory: String
    public var maxConcurrent: Int
    public var proxyURL: String?
    public init(destinationDirectory: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MVD").path, maxConcurrent: Int = 3, proxyURL: String? = nil) {
        self.destinationDirectory = destinationDirectory; self.maxConcurrent = maxConcurrent; self.proxyURL = proxyURL
    }
}

public struct ToolCapability: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var available: Bool
    public var detail: String
    public init(id: String, name: String, available: Bool, detail: String) { self.id = id; self.name = name; self.available = available; self.detail = detail }
}

public struct PageCandidate: Codable, Identifiable, Sendable {
    public var id: String { url }
    public var url: String
    public var title: String
    public init(url: String, title: String) { self.url = url; self.title = title }
}

public enum BrokerCommand: String, Codable, Sendable {
    case hello, list, enqueue, pause, resume, cancel, remove, setSettings, inspectPage, resolveMedia, updateOptions, saveFolder, removeFolder, shutdown
}

public struct BrokerRequest: Codable, Sendable {
    public var protocolVersion = 1
    public var requestID: String
    public var command: BrokerCommand
    public var url: String?
    public var jobID: UUID?
    public var idempotencyKey: String?
    public var settings: DownloadSettings?
    public var kind: DownloadKind?
    public var browserInitiated: Bool?
    public var browserMediaAuthorized: Bool?
    public var quality: VideoQuality?
    public var pageOffset: Int?
    public var options: DownloadOptions?
    public var destinationDirectory: String?
    public var folderID: UUID?
    public var folder: DownloadFolder?
    public init(command: BrokerCommand, url: String? = nil, jobID: UUID? = nil, idempotencyKey: String? = nil, settings: DownloadSettings? = nil, kind: DownloadKind? = nil, requestID: String = UUID().uuidString, browserInitiated: Bool? = nil, quality: VideoQuality? = nil, pageOffset: Int? = nil, options: DownloadOptions? = nil, destinationDirectory: String? = nil, folderID: UUID? = nil, folder: DownloadFolder? = nil, browserMediaAuthorized: Bool? = nil) {
        self.requestID = requestID; self.command = command; self.url = url; self.jobID = jobID
        self.idempotencyKey = idempotencyKey; self.settings = settings; self.kind = kind
        self.browserInitiated = browserInitiated
        self.browserMediaAuthorized = browserMediaAuthorized
        self.quality = quality; self.pageOffset = pageOffset
        self.options = options; self.destinationDirectory = destinationDirectory; self.folderID = folderID; self.folder = folder
    }
}

public struct BrokerResponse: Codable, Sendable {
    public var protocolVersion = 1
    public var serviceVersion: String? = HarborBuild.serviceVersion
    public var requestID: String
    public var jobs: [DownloadJob]
    public var jobID: UUID?
    public var settings: DownloadSettings?
    public var capabilities: [ToolCapability]?
    public var candidates: [PageCandidate]?
    public var error: String?
    public var mediaPreview: MediaPreview?
    public var nextPageOffset: Int?
    public var totalJobCount: Int?
    public var folders: [DownloadFolder]?
    public init(requestID: String, jobs: [DownloadJob] = [], jobID: UUID? = nil, settings: DownloadSettings? = nil, capabilities: [ToolCapability]? = nil, candidates: [PageCandidate]? = nil, error: String? = nil, mediaPreview: MediaPreview? = nil, nextPageOffset: Int? = nil, totalJobCount: Int? = nil, folders: [DownloadFolder]? = nil) {
        self.requestID = requestID; self.jobs = jobs; self.jobID = jobID; self.settings = settings
        self.capabilities = capabilities; self.candidates = candidates; self.error = error
        self.mediaPreview = mediaPreview; self.nextPageOffset = nextPageOffset; self.totalJobCount = totalJobCount
        self.folders = folders
    }
}

public enum HarborPaths {
    public static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["HARBOR_SUPPORT_DIR"] { return URL(fileURLWithPath: override) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Harbor", isDirectory: true)
    }
    public static var socketPath: String { supportDirectory.appendingPathComponent("broker.sock").path }
}
