import Foundation
import HarborCore

/// Own one instance in the long-lived broker, never in a window or extension.
public actor DownloadService {
    private struct Worker {
        let token: UUID
        let control: TransferControl
        let connections: Int
        var task: Task<Void, Never>?
    }
    private struct CachedPreview {
        let preview: MediaPreview
        let proxy: String?
        let createdAt: Date
    }

    private let store: DownloadStore
    private let rootDirectory: URL
    private let tools: ProviderTools
    private var settings: DownloadSettings
    private var jobs: [UUID: DownloadJob]
    private var folders: [UUID: DownloadFolder]
    private var workers: [UUID: Worker] = [:]
    private var progressSaved: [UUID: Date] = [:]
    private var cleanupAfterWorker: Set<UUID> = []
    private var isStopped = false
    private var persistenceFailure: String?
    private var previewCache: [String: CachedPreview] = [:]
    private var resolvers: [UUID: TransferControl] = [:]

    public init(rootDirectory: URL = HarborPaths.supportDirectory) throws {
        self.rootDirectory = rootDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = try DownloadStore(url: rootDirectory.appendingPathComponent("downloads.sqlite3"))
        self.store = store
        var settings = try store.loadSettings() ?? DownloadSettings()
        let oldDefault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Harbor").path
        if settings.destinationDirectory == oldDefault {
            settings.destinationDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MVD").path
            try store.save(settings)
        }
        self.settings = settings
        self.folders = Dictionary(uniqueKeysWithValues: try store.loadFolders().map { ($0.id, $0) })
        self.tools = ProviderTools()
        var recovered: [UUID: DownloadJob] = [:]
        for var job in try store.loadJobs() {
            let stage = rootDirectory.appendingPathComponent("staging/\(job.id.uuidString)", isDirectory: true)
            if job.status != .completed, let output = PublicationReceipt.recover(in: stage, destination: job.destinationDirectory) {
                let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                job.status = .completed
                job.outputPath = output.path
                job.filename = output.lastPathComponent
                job.bytesReceived = Int64(size)
                job.totalBytes = Int64(size)
                job.bytesPerSecond = 0
                job.completedAt = Date()
                job.errorMessage = nil
                try store.save(job)
                try? FileManager.default.removeItem(at: stage)
            } else if job.status.isActive {
                job.status = .paused
                job.bytesPerSecond = 0
                job.errorMessage = "The broker stopped before this download finished. Resume to retry; direct files restart safely."
                try store.save(job)
            }
            recovered[job.id] = job
        }
        self.jobs = recovered
    }

    public func handle(_ request: BrokerRequest) async -> BrokerResponse {
        guard request.protocolVersion == 1 else { return response(request, error: "This client uses an unsupported broker protocol version.") }
        do {
            switch request.command {
            case .hello:
                pump()
                return response(request, error: persistenceFailure)
            case .list:
                guard (request.pageOffset ?? 0) >= 0 else { throw EngineError.invalid("The download list offset must be zero or greater.") }
                pump()
                return response(request, error: persistenceFailure)
            case .enqueue:
                return try await enqueue(request)
            case .updateOptions:
                return try await updateOptions(request)
            case .saveFolder:
                try requireWritable()
                guard let proposed = request.folder else { throw EngineError.invalid("No folder shortcut was supplied.") }
                let folder = try OptionValidation.folder(proposed)
                guard folders[folder.id] != nil || folders.count < 100 else { throw EngineError.invalid("Keep at most 100 managed folder shortcuts.") }
                try FileManager.default.createDirectory(at: URL(fileURLWithPath: folder.path, isDirectory: true), withIntermediateDirectories: true)
                try store.save(folder)
                folders[folder.id] = folder
                return response(request)
            case .removeFolder:
                try requireWritable()
                guard let id = request.folderID, folders[id] != nil else { throw EngineError.invalid("This folder shortcut no longer exists.") }
                let detached = jobs.values.filter { $0.folderID == id }.map { job -> DownloadJob in var copy = job; copy.folderID = nil; return copy }
                try store.removeFolder(id, detaching: detached)
                for job in detached { jobs[job.id] = job }
                folders.removeValue(forKey: id)
                return response(request)
            case .pause, .resume, .cancel, .remove:
                try requireWritable()
                guard let id = request.jobID, var job = jobs[id] else { throw EngineError.invalid("This download no longer exists.") }
                switch request.command {
                case .pause:
                    if job.status == .paused { return response(request, jobID: id) }
                    guard job.status.isActive || job.status == .queued else { throw EngineError.invalid("Only queued or running downloads can be paused.") }
                    job.status = .paused
                    job.bytesPerSecond = 0
                    job.errorMessage = job.kind == .direct ? "Paused. Resume restarts this direct file safely from the beginning." : "Paused. Resume reuses available provider partial files."
                    try store.save(job)
                    jobs[id] = job
                    workers[id]?.control.stop()
                case .resume:
                    guard [.paused, .failed, .cancelled].contains(job.status) else { throw EngineError.invalid("This download is not paused, failed or cancelled.") }
                    job.status = .queued
                    job.errorMessage = nil
                    job.completedAt = nil
                    job.outputPath = nil
                    job.bytesPerSecond = 0
                    if job.kind == .direct { job.bytesReceived = 0; job.totalBytes = nil }
                    try store.save(job)
                    jobs[id] = job
                case .cancel:
                    if job.status == .cancelled { return response(request, jobID: id) }
                    guard job.status != .completed else { throw EngineError.invalid("The completed file is already saved. Remove from List clears only its history.") }
                    job.status = .cancelled
                    job.bytesPerSecond = 0
                    job.errorMessage = nil
                    try store.save(job)
                    jobs[id] = job
                    cleanupAfterWorker.insert(id)
                    workers[id]?.control.stop()
                    if workers[id] == nil { cleanup(id) }
                case .remove:
                    guard !job.status.isActive else { throw EngineError.invalid("Pause or cancel this download before removing it from the list.") }
                    try store.delete(id)
                    jobs.removeValue(forKey: id)
                    cleanupAfterWorker.insert(id)
                    if workers[id] == nil { cleanup(id) }
                default: break
                }
                pump()
                return response(request, jobID: id)
            case .setSettings:
                try requireWritable()
                guard let updated = request.settings else { throw EngineError.invalid("No settings were supplied.") }
                let validated = try URLValidation.settings(updated)
                try store.save(validated)
                settings = validated
                pump()
                return response(request)
            case .inspectPage:
                guard request.browserInitiated != true else { throw EngineError.unavailable("Use Fetch Page in the desktop app; browser webpage scanning is still being qualified.") }
                guard let string = request.url else { throw EngineError.invalid("Enter a webpage URL to inspect.") }
                let url = try URLValidation.source(string)
                guard settings.proxyURL == nil else { throw EngineError.unavailable("Webpage scanning cannot use the media proxy yet. Add the page URL as a media download, or disable the proxy before scanning.") }
                let candidates = try await PageScanner.inspect(url)
                var result = response(request)
                result.candidates = candidates
                return result
            case .resolveMedia:
                try requireWritable()
                if request.browserInitiated == true {
                    guard request.browserMediaAuthorized == true else { throw EngineError.unavailable("Open the companion's media panel and choose Preview to authorize this request.") }
                    guard let raw = request.url else { throw EngineError.invalid("Enter a video URL to preview.") }
                    _ = try PublicNetworkPolicy.validate(raw, allowVideoProviders: true)
                }
                guard let raw = request.url else { throw EngineError.invalid("Enter a video URL to preview.") }
                let url = try URLValidation.source(raw)
                let resolvingProxy = settings.proxyURL
                let preview: MediaPreview
                if request.kind == .direct || (request.kind != .media && URLValidation.isDirectFile(url)) {
                    preview = MediaPreview(title: URLValidation.filename(url.lastPathComponent), isDirectFile: true)
                } else if let cached = cachedPreview(url.absoluteString), !cached.isDirectFile {
                    preview = cached
                } else {
                    guard resolvers.count < 3 else { throw EngineError.unavailable("Three video previews are already resolving. Wait briefly and retry this URL.") }
                    let identifier = UUID()
                    let control = TransferControl()
                    let directory = rootDirectory.appendingPathComponent("resolving/\(identifier.uuidString)", isDirectory: true)
                    resolvers[identifier] = control
                    defer { resolvers.removeValue(forKey: identifier); try? FileManager.default.removeItem(at: directory) }
                    preview = try await MediaResolver.resolve(source: url, directory: directory, proxy: resolvingProxy, tools: tools, control: control)
                }
                cache(preview, for: url.absoluteString, proxy: resolvingProxy)
                var result = response(request)
                result.mediaPreview = preview
                return result
            case .shutdown:
                await stop()
                return response(request)
            }
        } catch {
            return response(request, error: ErrorRedactor.message(error))
        }
    }

    private func destination(for request: BrokerRequest, fallback: String) throws -> String {
        if let id = request.folderID {
            guard let folder = folders[id] else { throw EngineError.invalid("Choose an existing folder shortcut or a destination path.") }
            return try OptionValidation.destination(folder.path)
        }
        return try OptionValidation.destination(request.destinationDirectory ?? fallback)
    }

    private func providerPreview(_ source: URL) async throws -> MediaPreview {
        if let preview = cachedPreview(source.absoluteString), !preview.isDirectFile { return preview }
        guard resolvers.count < 3 else { throw EngineError.unavailable("Three video previews are already resolving. Wait briefly and retry.") }
        let id = UUID(), control = TransferControl()
        let directory = rootDirectory.appendingPathComponent("resolving/\(id.uuidString)", isDirectory: true)
        let proxy = settings.proxyURL
        resolvers[id] = control
        defer { resolvers.removeValue(forKey: id); try? FileManager.default.removeItem(at: directory) }
        let preview = try await MediaResolver.resolve(source: source, directory: directory, proxy: proxy, tools: tools, control: control)
        cache(preview, for: source.absoluteString, proxy: proxy)
        return preview
    }

    private func validateIntent(options: DownloadOptions, quality: VideoQuality, source: URL) async throws -> MediaPreview? {
        if options.mode == .audioOnly, quality.height != nil { throw EngineError.invalid("Audio Only does not use a video resolution. Choose Best available.") }
        if options.mode != .videoWithAudio || options.container != "auto" {
            guard tools.ffmpeg != nil else { throw EngineError.unavailable("These output options require FFmpeg. Install the development runtime and restart MVD.") }
        }
        var preview = cachedPreview(source.absoluteString)
        if options.formatID != nil {
            preview = try await providerPreview(source)
            _ = try OptionValidation.selectedFormat(options: options, quality: quality, preview: preview)
        }
        return preview
    }

    private func enqueue(_ request: BrokerRequest) async throws -> BrokerResponse {
        try requireWritable()
        guard let string = request.url else { throw EngineError.invalid("Enter a URL to download.") }
        let source = try URLValidation.source(string)
        let key = request.idempotencyKey ?? request.requestID
        guard !key.isEmpty, key.utf8.count <= 256, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw EngineError.invalid("The request has an invalid idempotency key.") }
        let options = try OptionValidation.options(request.options)
        let quality = try MediaQuality.validate(request.quality)
        let kind: DownloadKind = OptionValidation.requiresMedia(options) ? .media : request.kind == .direct ? .direct : request.kind == .media ? .media : URLValidation.isDirectFile(source) ? .direct : .media
        guard kind != .direct || quality.height == nil else { throw EngineError.invalid("A direct file has one original quality. Choose Best available or resolve its video page.") }
        if request.browserInitiated == true {
            _ = try PublicNetworkPolicy.validate(source.absoluteString, allowVideoProviders: request.browserMediaAuthorized == true)
            guard request.destinationDirectory == nil else { throw EngineError.invalid("Browser downloads can select a saved folder or the default folder. Choose custom paths in MVD.") }
            guard kind == .direct || request.browserMediaAuthorized == true else { throw EngineError.unavailable("Open the companion's media panel and confirm this video download.") }
        }
        let path = try destination(for: request, fallback: settings.destinationDirectory)
        func matches(_ existing: DownloadJob) -> Bool {
            existing.sourceURL == source.absoluteString && existing.kind == kind && (existing.quality ?? .best) == quality && (existing.options ?? DownloadOptions()) == options && existing.destinationDirectory == path && existing.folderID == request.folderID
        }
        if let existing = try jobs.values.first(where: { $0.idempotencyKey == key }) ?? store.retiredRequest(key) {
            guard matches(existing) else { throw EngineError.invalid("This request key belongs to a download with different source, output options or destination. Review the new intent and use a new request key.") }
            return response(request, jobID: existing.id)
        }
        let preview = try await validateIntent(options: options, quality: quality, source: source)
        try requireWritable()
        // Metadata resolution yields the actor. Recheck the durable identity in
        // case another retry accepted this same intent while it was resolving.
        if let existing = try jobs.values.first(where: { $0.idempotencyKey == key }) ?? store.retiredRequest(key) {
            guard matches(existing) else { throw EngineError.invalid("This request key already belongs to another download intent.") }
            return response(request, jobID: existing.id)
        }
        if let id = request.folderID, folders[id] == nil { throw EngineError.invalid("The selected folder shortcut was removed during review. Choose a destination again.") }
        let title = kind == .direct ? URLValidation.filename(source.lastPathComponent) : (source.host ?? "Video")
        var job = DownloadJob(sourceURL: source.absoluteString, title: title, filename: kind == .direct ? title : "", destinationDirectory: path, kind: kind, idempotencyKey: key)
        job.browserInitiated = request.browserInitiated; job.browserMediaAuthorized = request.browserMediaAuthorized
        job.quality = quality; job.options = options; job.folderID = request.folderID
        if let preview, preview.isDirectFile == (kind == .direct) {
            if quality.height != nil && !preview.qualities.contains(quality) { throw EngineError.invalid("That resolution is unavailable. Resolve the video again and choose an available quality.") }
            job.title = preview.title; job.thumbnailURL = preview.thumbnailURL; job.duration = preview.duration
        }
        try store.save(job)
        jobs[job.id] = job
        pump()
        return response(request, jobID: job.id)
    }

    private func updateOptions(_ request: BrokerRequest) async throws -> BrokerResponse {
        try requireWritable()
        guard let id = request.jobID, let original = jobs[id] else { throw EngineError.invalid("This download no longer exists.") }
        guard !original.status.isActive, original.status != .completed else { throw EngineError.invalid("Pause this download before changing its options. Completed files need a new download copy.") }
        let options = try OptionValidation.options(request.options ?? original.options)
        let quality = try MediaQuality.validate(request.quality)
        let source = try URLValidation.source(original.sourceURL)
        let preview = try await validateIntent(options: options, quality: quality, source: source)
        if let worker = workers[id] { worker.control.stop(); await worker.task?.value }
        try requireWritable()
        guard var job = jobs[id], !job.status.isActive, job.status != .completed else { throw EngineError.invalid("The download changed while its options were being reviewed. Pause it and retry.") }
        let path = try destination(for: request, fallback: job.destinationDirectory)
        let stage = stagingDirectory(id)
        if FileManager.default.fileExists(atPath: stage.path) { try FileManager.default.removeItem(at: stage) }
        job.options = options; job.quality = quality; job.folderID = request.folderID; job.destinationDirectory = path
        if OptionValidation.requiresMedia(options) { job.kind = .media }
        else { job.kind = quality.height != nil ? .media : URLValidation.isDirectFile(source) ? .direct : .media }
        if job.kind == .direct, quality.height != nil { throw EngineError.invalid("Direct files have one original quality. Choose Best available.") }
        job.status = .paused; job.bytesReceived = 0; job.totalBytes = nil; job.bytesPerSecond = 0
        job.errorMessage = "Options saved. Resume starts a fresh transfer with these settings."
        job.outputPath = nil; job.completedAt = nil
        if let preview { job.title = preview.title; job.thumbnailURL = preview.thumbnailURL; job.duration = preview.duration }
        try store.save(job)
        jobs[id] = job
        return response(request, jobID: id)
    }

    public func stop() async {
        isStopped = true
        for control in resolvers.values { control.stop() }
        let pending = workers.values.compactMap(\.task)
        for (id, worker) in workers {
            if var job = jobs[id], job.status.isActive {
                job.status = .paused
                job.bytesPerSecond = 0
                job.errorMessage = "Paused when the broker stopped. Direct downloads restart safely on resume."
                do { try store.save(job); jobs[id] = job }
                catch { persistenceFailure = ErrorRedactor.message(error) }
            }
            worker.control.stop()
        }
        for task in pending { await task.value }
    }

    private func requireWritable() throws {
        if isStopped { throw EngineError.unavailable("The broker is shutting down. Reopen the app to start it again.") }
        if let persistenceFailure { throw EngineError.storage(persistenceFailure) }
    }

    private func response(_ request: BrokerRequest, jobID: UUID? = nil, error: String? = nil) -> BrokerResponse {
        var result = BrokerResponse(requestID: request.requestID, jobID: jobID, settings: settings, capabilities: tools.capabilities, error: error, totalJobCount: jobs.count, folders: folders.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
        guard request.command == .list else { return result }
        let ordered = jobs.values.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.id.uuidString < rhs.id.uuidString : lhs.createdAt > rhs.createdAt
        }
        let start = min(max(0, request.pageOffset ?? 0), ordered.count)
        let end = start + min(50, ordered.count - start)
        result.jobs = Array(ordered[start..<end])
        result.nextPageOffset = end < ordered.count ? end : nil
        // Defend the transport envelope even if a future model gains large
        // metadata fields or old persisted records exceed today's field limits.
        while !result.jobs.isEmpty, let encoded = try? JSONEncoder().encode(result), encoded.count >= 2 * 1_048_576 {
            result.jobs.removeLast()
            result.nextPageOffset = start + result.jobs.count
        }
        if result.jobs.isEmpty, start < ordered.count {
            result.nextPageOffset = start + 1 < ordered.count ? start + 1 : nil
            result.error = "A stored download record is too large to display. Its history remains saved on disk."
        }
        return result
    }

    private func cachedPreview(_ source: String) -> MediaPreview? {
        guard let cached = previewCache[source], cached.proxy == settings.proxyURL, Date().timeIntervalSince(cached.createdAt) < 10 * 60 else { return nil }
        return cached.preview
    }

    private func cache(_ preview: MediaPreview, for source: String, proxy: String?) {
        previewCache[source] = CachedPreview(preview: preview, proxy: proxy, createdAt: Date())
        if previewCache.count > 200, let oldest = previewCache.min(by: { $0.value.createdAt < $1.value.createdAt })?.key { previewCache.removeValue(forKey: oldest) }
    }

    private func pump() {
        guard !isStopped, persistenceFailure == nil else { return }
        while workers.count < settings.maxConcurrent {
            guard var job = jobs.values.filter({ $0.status == .queued && workers[$0.id] == nil }).min(by: { $0.createdAt < $1.createdAt }) else { return }
            let connections = job.options?.accelerated == true ? 4 : 1
            guard workers.values.reduce(0, { $0 + $1.connections }) + connections <= 8 else { return }
            job.status = job.kind == .direct ? .downloading : .resolving
            job.bytesPerSecond = 0
            let token = UUID()
            let control = TransferControl()
            do { try store.save(job) }
            catch { failPersistence(error); return }
            jobs[job.id] = job
            workers[job.id] = Worker(token: token, control: control, connections: connections)
            let proxy = settings.proxyURL
            let task = Task { await self.run(job: job, token: token, proxy: proxy, connections: connections, control: control) }
            workers[job.id]?.task = task
        }
    }

    private func run(job: DownloadJob, token: UUID, proxy: String?, connections: Int, control: TransferControl) async {
        let directory = stagingDirectory(job.id)
        do {
            let source = try URLValidation.source(job.sourceURL)
            let transfer: TransferResult
            let report: @Sendable (TransferProgress) -> Void = { progress in
                Task { await self.update(job.id, token: token, progress: progress) }
            }
            if job.kind == .direct {
                if proxy != nil { throw EngineError.unavailable("The configured proxy is supported for media jobs only. Direct-file downloads cannot use it yet; no direct connection was attempted.") }
                if job.options?.accelerated == true, let segmented = try await SegmentedDirectTransfer.run(source: source, stagingDirectory: directory, control: control, browserInitiated: job.browserInitiated == true, maximumConnections: connections, progress: report) {
                    transfer = segmented
                } else {
                    transfer = try await DirectTransfer(source: source, stagingDirectory: directory, control: control, rejectHTML: true, browserInitiated: job.browserInitiated == true, browserMediaAuthorized: job.browserMediaAuthorized == true, progress: report).start()
                }
            } else {
                if job.browserInitiated == true {
                    guard job.browserMediaAuthorized == true else { throw EngineError.unavailable("Open the companion's media panel and confirm this video download.") }
                    _ = try PublicNetworkPolicy.validate(source.absoluteString, allowVideoProviders: true)
                }
                transfer = try await MediaTransfer.run(source: source, stagingDirectory: directory, proxy: proxy, tools: tools, quality: job.quality, options: job.options, fragmentConnections: connections, control: control, progress: report)
            }
            guard !control.isStopped else { throw EngineError.cancelled }
            try markProcessing(job.id, token: token)
            let output = try await Task.detached(priority: .utility) {
                try OutputPublisher.publish(transfer, destination: URL(fileURLWithPath: job.destinationDirectory, isDirectory: true), control: control)
            }.value
            // Only this worker can publish. Once publication succeeds, complete
            // even if a stop request arrives while its result is being delivered.
            try finish(job.id, token: token, output: output)
        } catch {
            failed(job.id, token: token, error: error)
        }
        if workers[job.id]?.token == token { workers.removeValue(forKey: job.id) }
        progressSaved.removeValue(forKey: job.id)
        if cleanupAfterWorker.contains(job.id) { cleanup(job.id) }
        pump()
    }

    private func update(_ id: UUID, token: UUID, progress: TransferProgress) {
        guard workers[id]?.token == token, var job = jobs[id], job.status.isActive, job.status != .processing else { return }
        job.status = progress.isProcessing ? .processing : .downloading
        job.bytesReceived = progress.isProcessing ? job.bytesReceived : max(0, progress.received)
        if let total = progress.total, total >= 0 { job.totalBytes = total }
        job.bytesPerSecond = progress.speed.isFinite ? max(0, progress.speed) : 0
        if let title = progress.title, !title.isEmpty { job.title = title }
        if let thumbnail = progress.thumbnailURL { job.thumbnailURL = thumbnail }
        if let duration = progress.duration { job.duration = duration }
        jobs[id] = job
        if Date().timeIntervalSince(progressSaved[id] ?? .distantPast) >= 0.75 {
            do { try store.save(job); progressSaved[id] = Date() }
            catch { failPersistence(error) }
        }
    }

    private func markProcessing(_ id: UUID, token: UUID) throws {
        guard workers[id]?.token == token, var job = jobs[id], job.status.isActive else { throw EngineError.cancelled }
        job.status = .processing
        job.bytesPerSecond = 0
        try store.save(job)
        jobs[id] = job
    }

    private func finish(_ id: UUID, token: UUID, output: URL) throws {
        guard workers[id]?.token == token, var job = jobs[id] else { return }
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        job.status = .completed
        job.outputPath = output.path
        job.filename = output.lastPathComponent
        if job.title.isEmpty || job.title == URL(string: job.sourceURL)?.host { job.title = output.deletingPathExtension().lastPathComponent }
        job.bytesReceived = Int64(size)
        job.totalBytes = Int64(size)
        job.bytesPerSecond = 0
        job.completedAt = Date()
        job.errorMessage = nil
        try store.save(job)
        jobs[id] = job
        cleanupAfterWorker.insert(id)
    }

    private func failed(_ id: UUID, token: UUID, error: Error) {
        guard workers[id]?.token == token, var job = jobs[id], job.status.isActive else { return }
        job.status = .failed
        job.bytesPerSecond = 0
        job.errorMessage = ErrorRedactor.message(error)
        do { try store.save(job); jobs[id] = job }
        catch { failPersistence(error) }
    }

    private func failPersistence(_ error: Error) {
        persistenceFailure = ErrorRedactor.message(error)
        for (id, worker) in workers {
            if var job = jobs[id], job.status.isActive {
                job.status = .paused
                job.bytesPerSecond = 0
                job.errorMessage = persistenceFailure
                jobs[id] = job
            }
            worker.control.stop()
        }
    }

    private func stagingDirectory(_ id: UUID) -> URL { rootDirectory.appendingPathComponent("staging/\(id.uuidString)", isDirectory: true) }

    private func cleanup(_ id: UUID) {
        try? FileManager.default.removeItem(at: stagingDirectory(id))
        cleanupAfterWorker.remove(id)
    }
}

private enum PageScanner {
    static func inspect(_ url: URL) async throws -> [PageCandidate] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode), let finalURL = response.url,
              (try? URLValidation.source(finalURL.absoluteString)) != nil else {
            throw EngineError.transfer("This webpage could not be fetched. Try adding its URL directly as a media download.")
        }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= 1_048_576 { break }
        }
        let html = String(decoding: data, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"(?i)(?:href|src)\s*=\s*["']([^"']+)["']"#)
        var result: [PageCandidate] = []
        var seen: Set<String> = []
        for match in expression.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            let string = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
            guard let candidate = URL(string: string, relativeTo: finalURL)?.absoluteURL,
                  (try? URLValidation.source(candidate.absoluteString)) != nil,
                  URLValidation.isDirectFile(candidate) || ["m3u8", "mpd"].contains(candidate.pathExtension.lowercased()), seen.insert(candidate.absoluteString).inserted else { continue }
            result.append(PageCandidate(url: candidate.absoluteString, title: URLValidation.filename(candidate.lastPathComponent, fallback: candidate.host ?? "Media")))
            if result.count >= 100 { break }
        }
        if seen.insert(url.absoluteString).inserted {
            result.append(PageCandidate(url: url.absoluteString, title: "Resolve video from this page using yt-dlp"))
        }
        return result
    }
}
