import XCTest
import Network
import HarborCore
@testable import HarborEngine

final class DownloadServiceTests: XCTestCase {
    func testUntrustedFilenamesStayBoundedAndCannotTraverseDirectories() {
        XCTAssertEqual(URLValidation.filename("../../private/video.mp4"), "video.mp4")
        let veryLongExtension = "a." + String(repeating: "x", count: 1_000)
        XCTAssertLessThanOrEqual(URLValidation.filename(veryLongExtension).utf8.count, 200)
        XCTAssertFalse(URLValidation.filename("../..\\evil.mp4").contains("/"))
    }

    func testInvalidSourceURLIsRejectedBeforePersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try DownloadService(rootDirectory: directory)
        let response = await service.handle(BrokerRequest(command: .enqueue, url: "file:///etc/passwd"))
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.jobs.isEmpty)
        await service.stop()
    }

    func testHTTPTransferPublishesExactBytesAndNeverOverwritesAnExistingName() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, output) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let existing = output.appendingPathComponent("file.mp4")
        try Data("keep this existing file".utf8).write(to: existing)
        let response = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url("file.mp4")))
        let job = try await waitForJob(service, id: XCTUnwrap(response.jobID)) { [.completed, .failed].contains($0.status) }
        XCTAssertEqual(job.status, .completed, job.errorMessage ?? "")
        let path = try XCTUnwrap(job.outputPath)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "file (1).mp4")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), fixture.payload)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep this existing file")
        let removed = await service.handle(BrokerRequest(command: .remove, jobID: job.id))
        XCTAssertNil(removed.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Removing history must not delete the downloaded file")
        let retried = await service.handle(BrokerRequest(command: .enqueue, url: job.sourceURL, idempotencyKey: job.idempotencyKey))
        XCTAssertEqual(retried.jobID, job.id, "Delayed retries must retain their accepted identity after history removal")
        XCTAssertTrue(retried.jobs.isEmpty, "A delayed retry must not resurrect removed history or restart a transfer")
        await service.stop()
    }

    func testUnknownLengthIsDownloadedAndHTTPFailuresDoNotPublishFiles() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url("unknown.mp4")))
        let downloaded = try await waitForJob(service, id: XCTUnwrap(good.jobID)) { [.completed, .failed].contains($0.status) }
        XCTAssertEqual(downloaded.status, .completed, downloaded.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(downloaded.outputPath))), fixture.payload)
        for endpoint in ["error.mp4", "truncated.mp4"] {
            let response = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url(endpoint)))
            let job = try await waitForJob(service, id: XCTUnwrap(response.jobID)) { [.completed, .failed].contains($0.status) }
            XCTAssertEqual(job.status, .failed)
            XCTAssertNil(job.outputPath)
            XCTAssertNotNil(job.errorMessage)
        }
        await service.stop()
    }

    func testPauseResumeRestartsDirectDownloadWithoutAppendingCorruptBytes() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url("slow.mp4")))
        let id = try XCTUnwrap(response.jobID)
        _ = try await waitForJob(service, id: id) { $0.bytesReceived > 0 }
        let paused = await service.handle(BrokerRequest(command: .pause, jobID: id))
        XCTAssertTrue(paused.jobs.isEmpty, "Mutation acknowledgments must not contain unbounded job history")
        let pausedState = await service.handle(BrokerRequest(command: .list))
        XCTAssertEqual(pausedState.jobs.first(where: { $0.id == id })?.status, .paused)
        let resumed = await service.handle(BrokerRequest(command: .resume, jobID: id))
        XCTAssertNil(resumed.error)
        let completed = try await waitForJob(service, id: id) { [.completed, .failed].contains($0.status) }
        XCTAssertEqual(completed.status, .completed, completed.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(completed.outputPath))), fixture.slowPayload)
        XCTAssertGreaterThanOrEqual(fixture.count("slow.mp4"), 2, "A direct resume must make a new complete request")
        await service.stop()
    }

    func testAcceptedJobsAndIdempotencySurviveServiceRestart() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = BrokerRequest(command: .enqueue, url: fixture.url("slow.mp4"), idempotencyKey: "stable-retry-key")
        let original = await service.handle(request)
        let id = try XCTUnwrap(original.jobID)
        let duplicate = await service.handle(request)
        XCTAssertEqual(duplicate.jobID, id)
        XCTAssertTrue(duplicate.jobs.isEmpty)
        let initialState = await service.handle(BrokerRequest(command: .list))
        XCTAssertEqual(initialState.jobs.count, 1)
        await service.stop()
        let recovered = try DownloadService(rootDirectory: directory)
        let repeated = await recovered.handle(request)
        XCTAssertEqual(repeated.jobID, id)
        let recoveredState = await recovered.handle(BrokerRequest(command: .list))
        XCTAssertEqual(recoveredState.jobs.count, 1)
        XCTAssertEqual(recoveredState.jobs.first?.status, .paused)
        let conflicting = await recovered.handle(BrokerRequest(command: .enqueue, url: fixture.url("file.mp4"), idempotencyKey: "stable-retry-key"))
        XCTAssertNotNil(conflicting.error)
        await recovered.stop()
    }

    func testCrashRecoveryPausesActiveRowsAndKeepsSettings() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let store = try DownloadStore(url: directory.appendingPathComponent("downloads.sqlite3"))
            var job = DownloadJob(sourceURL: "https://example.com/movie.mp4", destinationDirectory: directory.path, kind: .direct)
            job.status = .downloading
            job.bytesReceived = 123
            try store.save(job)
            try store.save(DownloadSettings(destinationDirectory: directory.path, maxConcurrent: 1))
        }
        let service = try DownloadService(rootDirectory: directory)
        let state = await service.handle(BrokerRequest(command: .list))
        XCTAssertEqual(state.jobs.first?.status, .paused)
        XCTAssertEqual(state.jobs.first?.bytesReceived, 123)
        XCTAssertEqual(state.settings?.maxConcurrent, 1)
        await service.stop()
    }

    func testProxyNeverSilentlyFallsBackForDirectDownload() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, output) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = await service.handle(BrokerRequest(command: .setSettings, settings: DownloadSettings(destinationDirectory: output.path, maxConcurrent: 1, proxyURL: "socks5://127.0.0.1:1080")))
        let response = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url("file.mp4")))
        let failed = try await waitForJob(service, id: XCTUnwrap(response.jobID)) { $0.status == .failed }
        XCTAssertTrue(failed.errorMessage?.contains("proxy") == true)
        XCTAssertEqual(fixture.count("file.mp4"), 0)
        await service.stop()
    }

    func testPublicationReceiptRecoversAFilePublishedBeforeDatabaseCompletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("output", isDirectory: true)
        var job = DownloadJob(sourceURL: "https://example.com/movie.mp4", destinationDirectory: destination.path, kind: .direct)
        job.status = .processing
        let stage = directory.appendingPathComponent("staging/\(job.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let payload = Data("completed payload".utf8)
        let partial = stage.appendingPathComponent("direct.partial")
        try payload.write(to: partial)
        let published = try OutputPublisher.publish(TransferResult(file: partial, filename: "movie.mp4"), destination: destination, control: TransferControl())
        do {
            let store = try DownloadStore(url: directory.appendingPathComponent("downloads.sqlite3"))
            try store.save(job) // Simulates a crash before the completed-row commit.
        }
        let service = try DownloadService(rootDirectory: directory)
        let response = await service.handle(BrokerRequest(command: .list))
        XCTAssertEqual(response.jobs.first?.status, .completed)
        XCTAssertEqual(response.jobs.first?.outputPath, published.path)
        XCTAssertEqual(try Data(contentsOf: published), payload)
        await service.stop()
    }

    func testBrowserCannotEnqueueLocalOrUnqualifiedProviderURLs() async throws {
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = BrokerRequest(command: .enqueue, url: "http://127.0.0.1/private.mp4")
        request.browserInitiated = true
        let response = await service.handle(request)
        XCTAssertNotNil(response.error)
        XCTAssertTrue(response.jobs.isEmpty)
        await service.stop()
    }

    func testMediaProviderProducesAReportedOutputWhenRuntimeIsConfigured() async throws {
        guard ProcessInfo.processInfo.environment["HARBOR_YTDLP_PATH"] != nil else {
            throw XCTSkip("Set HARBOR_YTDLP_PATH to run the real provider subprocess integration test")
        }
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = await service.handle(BrokerRequest(command: .enqueue, url: fixture.url("file.mp4"), kind: .media))
        let completed = try await waitForJob(service, id: XCTUnwrap(response.jobID), timeout: 20) { [.completed, .failed].contains($0.status) }
        XCTAssertEqual(completed.status, .completed, completed.errorMessage ?? "")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(completed.outputPath))), fixture.payload)
        await service.stop()
    }

    func testWebpageInspectionResolvesRelativeMediaLinks() async throws {
        let fixture = try HTTPFixture()
        defer { fixture.stop() }
        let (service, directory, _) = try await configuredService()
        defer { try? FileManager.default.removeItem(at: directory) }
        let response = await service.handle(BrokerRequest(command: .inspectPage, url: fixture.url("page")))
        XCTAssertNil(response.error)
        XCTAssertEqual(response.candidates?.filter { $0.url == fixture.url("file.mp4") }.count, 1)
        XCTAssertTrue(response.candidates?.contains(where: { $0.url == fixture.url("page") }) == true)
        await service.stop()
    }

    func testPreviewUsesOnlyReportedNonDRMVideoHeights() throws {
        let metadata = Data(#"{"title":"Owned test video","thumbnail":"https://example.com/thumbnail.jpg","duration":42.5,"formats":[{"height":1080,"vcodec":"h264","has_drm":false},{"height":720,"vcodec":"vp9"},{"height":720,"vcodec":"h264"},{"height":2160,"vcodec":"h264","has_drm":true},{"height":480,"vcodec":"none"},{"height":999999,"vcodec":"h264"}]}"#.utf8)
        let preview = try MediaResolver.parse(metadata)
        XCTAssertEqual(preview.qualities.map(\.id), ["best", "1080p", "720p"])
        XCTAssertEqual(preview.duration, 42.5)
        XCTAssertEqual(preview.thumbnailURL, "https://example.com/thumbnail.jpg")
        let unsafeThumbnail = try MediaResolver.parse(Data(#"{"title":"Video","thumbnail":"file:///etc/passwd"}"#.utf8))
        XCTAssertNil(unsafeThumbnail.thumbnailURL)
        XCTAssertThrowsError(try MediaQuality.validate(VideoQuality(id: "--exec=bad", label: "720p", height: 720)))
        XCTAssertThrowsError(try MediaQuality.validate(VideoQuality(id: "720p", label: "720p", height: 1080)))
        XCTAssertEqual(try MediaQuality.validate(VideoQuality(id: "720p", label: "Untrusted label", height: 720)), VideoQuality(id: "720p", label: "720p", height: 720))
    }

    func testHistoryIsPaginatedAndMetadataAcknowledgmentsStaySmall() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let store = try DownloadStore(url: directory.appendingPathComponent("downloads.sqlite3"))
            for index in 0..<123 {
                var job = DownloadJob(sourceURL: "https://example.com/" + String(repeating: "x", count: 15_000) + "\(index).mp4", title: String(repeating: "t", count: 400), destinationDirectory: directory.path, kind: .direct)
                job.status = .failed
                job.createdAt = Date(timeIntervalSince1970: 123)
                try store.save(job)
            }
        }
        let service = try DownloadService(rootDirectory: directory)
        let hello = await service.handle(BrokerRequest(command: .hello))
        XCTAssertTrue(hello.jobs.isEmpty)
        XCTAssertEqual(hello.totalJobCount, 123)
        XCTAssertLessThan(try JSONEncoder().encode(hello).count, 16_384)
        var offset: Int? = 0
        var identifiers: [UUID] = []
        while let current = offset {
            let response = await service.handle(BrokerRequest(command: .list, pageOffset: current))
            XCTAssertLessThanOrEqual(response.jobs.count, 50)
            XCTAssertLessThan(try JSONEncoder().encode(response).count, 2 * 1_048_576)
            identifiers += response.jobs.map(\.id)
            offset = response.nextPageOffset
        }
        XCTAssertEqual(identifiers.count, 123)
        XCTAssertEqual(Set(identifiers).count, 123)
        await service.stop()
    }

    private func configuredService() async throws -> (DownloadService, URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HarborTests-\(UUID().uuidString)")
        let output = directory.appendingPathComponent("output", isDirectory: true)
        let service = try DownloadService(rootDirectory: directory)
        let configured = await service.handle(BrokerRequest(command: .setSettings, settings: DownloadSettings(destinationDirectory: output.path, maxConcurrent: 1)))
        XCTAssertNil(configured.error)
        return (service, directory, output)
    }

    private func waitForJob(_ service: DownloadService, id: UUID, timeout: TimeInterval = 10, predicate: (DownloadJob) -> Bool) async throws -> DownloadJob {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let response = await service.handle(BrokerRequest(command: .list))
            if let job = response.jobs.first(where: { $0.id == id }), predicate(job) { return job }
            try await Task.sleep(for: .milliseconds(40))
        }
        let response = await service.handle(BrokerRequest(command: .list))
        throw NSError(domain: "HarborTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for job: \(String(describing: response.jobs.first(where: { $0.id == id })))"])
    }
}

/// An actual local HTTP server exercises streaming, status, truncation, redirects
/// and unknown-length bodies without relying on an external website or Python.
private final class HTTPFixture: @unchecked Sendable {
    let payload = Data((0..<32_768).map { UInt8($0 % 251) })
    let slowPayload = Data((0..<524_288).map { UInt8($0 % 241) })
    private let listener: NWListener
    private let queue = DispatchQueue(label: "HarborTests.HTTP")
    private let lock = NSLock()
    private var requests: [String: Int] = [:]
    private var connections: [NWConnection] = []
    private var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.port = self?.listener.port?.rawValue ?? 0; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, _, _ in
                guard let self, let data, let request = String(data: data, encoding: .utf8) else { connection.cancel(); return }
                let path = request.components(separatedBy: " ").dropFirst().first?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "file.mp4"
                self.lock.withLock { self.requests[path, default: 0] += 1 }
                self.respond(path, connection: connection)
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else { listener.cancel(); throw NSError(domain: "HTTPFixture", code: 1) }
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }
    func count(_ path: String) -> Int { lock.withLock { requests[path] ?? 0 } }
    func stop() { listener.cancel(); queue.async { [self] in connections.forEach { $0.cancel() }; connections = [] } }

    private func respond(_ path: String, connection: NWConnection) {
        let status = path == "error.mp4" ? "403 Forbidden" : "200 OK"
        let body = path == "page" ? Data(#"<video src="/file.mp4"></video><a href="/file.mp4">Same file</a>"#.utf8) : path == "slow.mp4" ? slowPayload : payload
        var headers = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Type: \(path == "page" ? "text/html" : "video/mp4")\r\n"
        if path != "unknown.mp4" { headers += "Content-Length: \(path == "truncated.mp4" ? body.count + 100 : body.count)\r\n" }
        headers += "\r\n"
        if path == "slow.mp4" {
            connection.send(content: Data(headers.utf8), completion: .contentProcessed { [weak self] error in
                guard error == nil, let self else { connection.cancel(); return }
                self.sendSlow(body, offset: 0, connection: connection)
            })
        } else {
            connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func sendSlow(_ body: Data, offset: Int, connection: NWConnection) {
        guard offset < body.count else { connection.cancel(); return }
        let end = min(offset + 8_192, body.count)
        connection.send(content: body[offset..<end], completion: .contentProcessed { [weak self] error in
            guard error == nil, let self else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.025) { self.sendSlow(body, offset: end, connection: connection) }
        })
    }
}
