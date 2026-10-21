import AppKit
import CryptoKit
import Foundation
import HarborCore
import Observation
import SwiftUI

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all, active, queued, paused, completed, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Downloads"
        case .active: "Active"
        case .queued: "Queued"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Needs Attention"
        }
    }
    var symbol: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .queued: "clock"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
    func includes(_ job: DownloadJob) -> Bool {
        switch self {
        case .all: true
        case .active: job.status.isActive
        case .queued: job.status == .queued
        case .paused: job.status == .paused
        case .completed: job.status == .completed
        case .failed: job.status == .failed
        }
    }
}

enum HarborSheet: String, Identifiable {
    case addURL, fetchPage, bulkURLs, folderEditor, editDownload
    var id: String { rawValue }
}

struct ActionFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class DownloadStore {
    var jobs: [DownloadJob] = []
    var settings = DownloadSettings()
    var capabilities: [ToolCapability] = []
    var folders: [DownloadFolder] = []
    var selectedFolderID: UUID?
    var folderToEdit: DownloadFolder?
    var editingJob: DownloadJob?
    var selection: Set<UUID> = []
    var filter: DownloadFilter = .all
    var search = ""
    var sortOrder = [KeyPathComparator(\DownloadJob.createdAt, order: .reverse)]
    var libraryView = DownloadLibraryView(rawValue: UserDefaults.standard.string(forKey: "MVD.libraryView") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(libraryView.rawValue, forKey: "MVD.libraryView") }
    }
    var showsInspector = false
    var sheet: HarborSheet?
    var actionFailure: ActionFailure?
    var connectionLabel = "Connecting…"
    var connectionError: String?
    var connected = false
    var submitting = false
    var urlDraft = ""
    var bulkURLDraft = ""
    var reviewDraftAutomatically = false
    var reviewSourcePageURL: String?
    var pendingJobIDs: Set<UUID> = []
    private(set) var openingPlaybackIDs: Set<UUID> = []
    private var pollingTask: Task<Void, Never>?
    private var refreshing = false
    @ObservationIgnored private var incomingDownloadID: UUID?
    private let client = BrokerClient()
    @ObservationIgnored private let audioPreview = AudioPlaybackPreview()

    var visibleJobs: [DownloadJob] {
        jobs.filter { job in
            filter.includes(job) && (selectedFolderID == nil || job.folderID == selectedFolderID) && (search.isEmpty || "\(job.displayTitle) \(job.sourceURL) \(job.status.label)".localizedStandardContains(search))
        }.sorted(using: sortOrder)
    }
    var selectedJobs: [DownloadJob] { jobs.filter { selection.contains($0.id) } }
    var activeJobs: [DownloadJob] { jobs.filter { $0.status.isActive } }
    var totalSpeed: Double { activeJobs.reduce(0) { $0 + $1.bytesPerSecond } }
    var missingTools: [ToolCapability] { capabilities.filter { !$0.available } }
    var libraryTitle: String { folders.first(where: { $0.id == selectedFolderID })?.name ?? filter.title }
    func count(_ filter: DownloadFilter) -> Int { jobs.filter(filter.includes).count }

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            guard let self else { return }
            await reconnect()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
                await refresh()
            }
        }
    }

    func reconnect() async {
        connectionLabel = "Connecting…"
        do {
            try await BrokerLauncher.ensureRunning()
            let response = try await checkedSend(BrokerRequest(command: .hello))
            applyMetadata(response)
            await refresh()
        } catch { markDisconnected(error) }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var offset = 0
            var visitedOffsets: Set<Int> = []
            var refreshedJobs: [DownloadJob] = []
            var knownIDs: Set<UUID> = []
            var metadata: BrokerResponse?
            while true {
                guard visitedOffsets.insert(offset).inserted else { throw UIError.message("The download service returned a repeated history page. Try reconnecting.") }
                let response = try await checkedSend(BrokerRequest(command: .list, pageOffset: offset))
                if metadata == nil { metadata = response }
                for job in response.jobs where knownIDs.insert(job.id).inserted { refreshedJobs.append(job) }
                guard let next = response.nextPageOffset else { break }
                guard next > offset else { throw UIError.message("The download service returned an invalid history page. Try reconnecting.") }
                offset = next
            }
            if jobs != refreshedJobs { jobs = refreshedJobs }
            selection.formIntersection(Set(jobs.map(\.id)))
            if let incomingDownloadID, knownIDs.contains(incomingDownloadID) {
                selection = [incomingDownloadID]
                self.incomingDownloadID = nil
            }
            if let metadata { applyMetadata(metadata) }
            connected = true
            connectionLabel = "Download service connected"
            connectionError = nil
        } catch { markDisconnected(error) }
    }

    func enqueue(_ raw: String, quality: VideoQuality? = nil, options: DownloadOptions? = nil, destinationDirectory: String? = nil, folderID: UUID? = nil) async -> Bool {
        do {
            _ = try await enqueueReviewedURL(raw, quality: quality, options: options, destinationDirectory: destinationDirectory, folderID: folderID)
            return true
        } catch {
            actionFailure = ActionFailure(title: "Couldn’t start the download", message: error.localizedDescription)
            return false
        }
    }

    /// Batch callers keep failures on their individual rows instead of presenting repeated alerts.
    @discardableResult
    func enqueueReviewedURL(_ raw: String, quality: VideoQuality? = nil, options: DownloadOptions? = nil, destinationDirectory: String? = nil, folderID: UUID? = nil) async throws -> UUID {
        guard let url = Self.normalizedURL(raw) else { throw UIError.message(Self.urlEntryHint) }
        submitting = true
        defer { submitting = false }
        let chosenOptions = options ?? DownloadOptions()
        let chosenDestination = destinationDirectory.flatMap { $0.isEmpty ? nil : $0 } ?? settings.destinationDirectory
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encodedOptions = String(decoding: try encoder.encode(chosenOptions), as: UTF8.self)
        let intent = "\(url)\nquality:\(quality?.id ?? "original"):\(quality?.height.map(String.init) ?? "")\noptions:\(encodedOptions)\ndestination:\(chosenDestination)\nfolder:\(folderID?.uuidString ?? "")"
        let pending = PendingEnqueueKeys.key(for: intent)
        if !connected { try await BrokerLauncher.ensureRunning() }
        let kind: DownloadKind = Self.isRecognizedMediaURL(url) && quality?.height != nil ? .media : .automatic
        let response = try await client.send(BrokerRequest(command: .enqueue, url: url, idempotencyKey: pending, kind: kind, quality: quality, options: chosenOptions, destinationDirectory: chosenDestination, folderID: folderID))
        if let error = response.error {
            PendingEnqueueKeys.clear(for: intent, matching: pending)
            throw UIError.message(error)
        }
        guard let acceptedID = response.jobID else {
            throw UIError.message("The service did not confirm acceptance. Retry the same link and quality to safely check whether the download was added.")
        }
        PendingEnqueueKeys.clear(for: intent, matching: pending)
        filter = .all
        selectedFolderID = nil
        search = ""
        await refresh()
        selection = [acceptedID]
        return acceptedID
    }

    func perform(_ command: BrokerCommand, jobs targets: [DownloadJob]) async {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty else { return }
        pendingJobIDs.formUnion(ids)
        defer { pendingJobIDs.subtract(ids) }
        do {
            for job in targets { _ = try await checkedSend(BrokerRequest(command: command, jobID: job.id)) }
            await refresh()
        } catch {
            actionFailure = ActionFailure(title: "Couldn’t update the download", message: error.localizedDescription)
            await refresh()
        }
    }

    func saveSettings(_ updated: DownloadSettings) async -> Bool {
        do {
            let response = try await checkedSend(BrokerRequest(command: .setSettings, settings: updated))
            settings = response.settings ?? updated
            return true
        } catch {
            actionFailure = ActionFailure(title: "Couldn’t save settings", message: error.localizedDescription)
            return false
        }
    }

    func inspectPage(_ raw: String) async throws -> [PageCandidate] {
        guard let url = Self.normalizedURL(raw) else { throw UIError.message("Enter a complete HTTP or HTTPS page URL.") }
        let response = try await checkedSend(BrokerRequest(command: .inspectPage, url: url))
        return response.candidates ?? []
    }

    func resolveMedia(_ raw: String) async throws -> MediaPreview {
        guard let url = Self.normalizedURL(raw) else { throw UIError.message(Self.urlEntryHint) }
        if !connected { try await BrokerLauncher.ensureRunning() }
        let kind: DownloadKind? = Self.isRecognizedMediaURL(url) ? .media : nil
        let response = try await checkedSend(BrokerRequest(command: .resolveMedia, url: url, kind: kind))
        guard let preview = response.mediaPreview else { throw UIError.message("The service returned no video details. Try the original video page or a direct media link.") }
        return preview
    }

    func saveFolder(_ folder: DownloadFolder) async throws {
        let response = try await checkedSend(BrokerRequest(command: .saveFolder, folder: folder))
        applyMetadata(response)
        await refresh()
    }

    func removeFolder(_ folder: DownloadFolder) async {
        do {
            let response = try await checkedSend(BrokerRequest(command: .removeFolder, folderID: folder.id))
            applyMetadata(response)
            if selectedFolderID == folder.id { selectedFolderID = nil }
            await refresh()
        } catch { actionFailure = ActionFailure(title: "Couldn’t remove the folder shortcut", message: error.localizedDescription) }
    }

    func editOptions(for job: DownloadJob) {
        editingJob = job
        sheet = .editDownload
    }

    /// A changed media selection starts a fresh transfer; completed files get a new job.
    func updateDownload(_ snapshot: DownloadJob, quality: VideoQuality?, options: DownloadOptions, destinationDirectory: String, folderID: UUID?) async throws {
        let job = jobs.first(where: { $0.id == snapshot.id }) ?? snapshot
        if job.status == .completed {
            _ = try await enqueueReviewedURL(job.sourceURL, quality: quality, options: options, destinationDirectory: destinationDirectory, folderID: folderID)
            return
        }
        guard job.status != .processing else { throw UIError.message("Wait for final processing to finish before editing this download.") }
        pendingJobIDs.insert(job.id)
        defer { pendingJobIDs.remove(job.id) }
        let shouldResume = job.status != .paused
        if job.canPause { _ = try await checkedSend(BrokerRequest(command: .pause, jobID: job.id)) }
        var attempts = 0
        while true {
            do {
                _ = try await checkedSend(BrokerRequest(command: .updateOptions, jobID: job.id, quality: quality, options: options, destinationDirectory: destinationDirectory, folderID: folderID))
                break
            } catch {
                let message = error.localizedDescription.lowercased()
                guard attempts < 12, message.contains("stopping") || message.contains("worker") else { await refresh(); throw error }
                attempts += 1
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        if shouldResume { _ = try await checkedSend(BrokerRequest(command: .resume, jobID: job.id)) }
        await refresh()
    }

    func setAcceleration(_ enabled: Bool, jobs targets: [DownloadJob]) async {
        for job in targets where job.status != .completed && job.status != .processing {
            var options = job.options ?? DownloadOptions()
            options.accelerated = enabled
            do {
                try await updateDownload(job, quality: job.quality, options: options, destinationDirectory: job.destinationDirectory, folderID: job.folderID)
            } catch { actionFailure = ActionFailure(title: "Couldn’t change acceleration", message: error.localizedDescription) }
        }
    }

    func primaryAction(_ ids: Set<UUID>) {
        selection = ids
        if let job = jobs.first(where: { ids.contains($0.id) }), ids.count == 1, job.status == .completed {
            if job.canPlay { play(job) } else { reveal(job) }
        } else { showsInspector = true }
    }

    func play(_ snapshot: DownloadJob) {
        let job = jobs.first(where: { $0.id == snapshot.id }) ?? snapshot
        guard openingPlaybackIDs.insert(job.id).inserted else { return }
        do {
            let url = try job.checkedPlaybackURL()
            if job.isAudio {
                defer { openingPlaybackIDs.remove(job.id) }
                let previewAppearance: NSAppearance?
                switch AppearanceStore.shared.colorScheme {
                case .dark: previewAppearance = NSAppearance(named: .darkAqua)
                case .light: previewAppearance = NSAppearance(named: .aqua)
                default: previewAppearance = nil
                }
                try audioPreview.open(url, title: job.displayTitle, appearance: previewAppearance)
            } else {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
                    Task { @MainActor in
                        guard let self else { return }
                        self.openingPlaybackIDs.remove(job.id)
                        if let error {
                            self.actionFailure = ActionFailure(title: "Couldn’t play the video", message: error.localizedDescription)
                        }
                    }
                }
            }
        } catch {
            openingPlaybackIDs.remove(job.id)
            actionFailure = ActionFailure(title: "Couldn’t play the download", message: error.localizedDescription)
        }
    }

    func reveal(_ job: DownloadJob) {
        guard let path = job.outputPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func copyURL(_ job: DownloadJob) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(job.sourceURL, forType: .string)
    }

    func openSource(_ job: DownloadJob) {
        guard let normalized = Self.normalizedURL(job.sourceURL), let url = URL(string: normalized) else { return }
        NSWorkspace.shared.open(url)
    }

    func pasteAndDownload() {
        guard let value = NSPasteboard.general.string(forType: .string), !value.isEmpty else {
            sheet = .addURL
            return
        }
        openPastedURLs(value)
    }

    func openPastedURLs(_ value: String) {
        reviewSourcePageURL = nil
        reviewDraftAutomatically = true
        let lines = value.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count > 1 {
            bulkURLDraft = value
            sheet = .bulkURLs
        } else {
            urlDraft = value
            sheet = .addURL
        }
    }

    /// Browser handoffs prefill a review or reveal an already accepted job.
    /// Opening a handoff URL never enqueues or downloads another resource.
    func handleIncomingURL(_ incoming: URL) {
        guard incoming.scheme?.lowercased() == "harbor-downloads" else { return }
        if incoming.host?.lowercased() == "download" {
            guard incoming.path.isEmpty || incoming.path == "/",
                  incoming.user == nil, incoming.password == nil, incoming.port == nil,
                  incoming.fragment == nil,
                  let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
                  let queries = components.queryItems, queries.count == 1,
                  queries[0].name == "id", let value = queries[0].value,
                  let jobID = UUID(uuidString: value) else { return }
            incomingDownloadID = jobID
            filter = .all
            selectedFolderID = nil
            search = ""
            // Preserve any review or folder editor already in progress. A
            // browser handoff brings the app forward without discarding work.
            if jobs.contains(where: { $0.id == jobID }) {
                selection = [jobID]
                incomingDownloadID = nil
            }
            Task { await refresh() }
            return
        }
        guard incoming.host?.lowercased() == "review",
              incoming.path.isEmpty || incoming.path == "/",
              let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false) else {
            actionFailure = ActionFailure(title: "Couldn’t review the browser link", message: "The browser sent an invalid review request.")
            return
        }
        let queries = components.queryItems ?? []
        let links = queries.filter { $0.name == "url" }
        let pages = queries.filter { $0.name == "sourcePageURL" }
        func checkedURL(_ raw: String?) -> String? {
            guard let raw, raw.utf8.count <= 8192,
                  raw.rangeOfCharacter(from: .controlCharacters) == nil,
                  let scheme = URLComponents(string: raw)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
            return Self.normalizedURL(raw)
        }
        guard links.count == 1, pages.count <= 1,
              let link = checkedURL(links.first?.value),
              pages.isEmpty || checkedURL(pages.first?.value) != nil else {
            actionFailure = ActionFailure(title: "Couldn’t review the browser link", message: Self.urlEntryHint)
            return
        }
        reviewDraftAutomatically = false
        reviewSourcePageURL = checkedURL(pages.first?.value)
        urlDraft = link
        sheet = .addURL
    }

    private func checkedSend(_ request: BrokerRequest) async throws -> BrokerResponse {
        let response = try await client.send(request)
        if let error = response.error { throw UIError.message(error) }
        return response
    }

    private func applyMetadata(_ response: BrokerResponse) {
        if let updated = response.settings, settings != updated { settings = updated }
        if let updated = response.capabilities, capabilities != updated { capabilities = updated }
        if let updated = response.folders, folders != updated {
            folders = updated
            if let selectedFolderID, !updated.contains(where: { $0.id == selectedFolderID }) { self.selectedFolderID = nil }
        }
    }

    private func markDisconnected(_ error: Error) {
        connected = false
        connectionLabel = "Download service unavailable"
        connectionError = error.localizedDescription
    }

    static let urlEntryHint = "Enter a complete HTTP or HTTPS website, video, stream, or file URL without embedded usernames or passwords."

    static func isRecognizedMediaURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        return ["mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "ts", "m2ts", "mpeg", "mpg", "wmv", "ogv", "3gp", "mp3", "m4a", "aac", "wav", "flac", "opus", "ogg", "oga", "aiff", "aif", "alac", "wma"].contains(url.pathExtension.lowercased())
    }

    static func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let value = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.url != nil else { return nil }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        return components.url?.absoluteString
    }
}

private enum PendingEnqueueKeys {
    private static let defaultsKey = "HarborPendingEnqueueKeys.v1"

    static func key(for normalizedURL: String) -> String {
        let digest = urlDigest(normalizedURL)
        var keys = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        if let existing = keys[digest], UUID(uuidString: existing) != nil { return existing }
        let key = UUID().uuidString
        keys[digest] = key
        UserDefaults.standard.set(keys, forKey: defaultsKey)
        return key
    }

    static func clear(for normalizedURL: String, matching key: String) {
        let digest = urlDigest(normalizedURL)
        var keys = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        guard keys[digest] == key else { return }
        keys.removeValue(forKey: digest)
        UserDefaults.standard.set(keys, forKey: defaultsKey)
    }

    private static func urlDigest(_ normalizedURL: String) -> String {
        SHA256.hash(data: Data(normalizedURL.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum UIError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

extension DownloadJob {
    var displayTitle: String {
        if kind == .media, !title.isEmpty { return title }
        if !filename.isEmpty { return filename }
        if !title.isEmpty { return title }
        return URL(string: sourceURL)?.lastPathComponent.removingPercentEncoding.flatMap { $0.isEmpty ? nil : $0 } ?? sourceHost
    }
    var sourceHost: String { URL(string: sourceURL)?.host(percentEncoded: false) ?? sourceURL }
    var canPause: Bool { [.queued, .resolving, .downloading].contains(status) }
    var canResume: Bool { [.paused, .failed, .cancelled].contains(status) }
    var canCancel: Bool { [.queued, .resolving, .downloading, .processing, .paused].contains(status) }
    var canRemove: Bool { [.completed, .failed, .cancelled].contains(status) }
    var fileSymbol: String {
        if isAudio { return "music.note" }
        if isVideo { return "film" }
        let ext = URL(fileURLWithPath: outputPath ?? filename).pathExtension.lowercased()
        if ["zip", "dmg", "pkg", "tar", "gz", "7z"].contains(ext) { return "shippingbox" }
        if ["png", "jpeg", "jpg", "gif", "webp", "heic"].contains(ext) { return "photo" }
        return "doc"
    }
    var statusColor: Color {
        switch status {
        case .failed: .red
        case .completed: .green
        case .paused: .orange
        case .downloading, .resolving, .processing: .accentColor
        default: .secondary
        }
    }
    var sizeLabel: String {
        let received = Format.bytes(bytesReceived)
        guard let totalBytes else { return bytesReceived > 0 ? received : "—" }
        return status == .completed ? Format.bytes(totalBytes) : "\(received) / \(Format.bytes(totalBytes))"
    }
    var etaLabel: String {
        guard status == .downloading, let totalBytes, bytesPerSecond > 0 else { return "—" }
        let seconds = max(0, Double(totalBytes - bytesReceived) / bytesPerSecond)
        if seconds < 60 { return "\(Int(seconds)) sec" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min" }
        return "\(Int(seconds / 3600)) hr \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)) min"
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file) }
    static func speed(_ value: Double) -> String { value > 0 && value.isFinite ? "\(bytes(Int64(min(value, Double(Int64.max / 2)))))/s" : "—" }
    static func folder(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
    static func duration(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0, value < Double(Int.max / 2) else { return nil }
        let seconds = Int(value)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
