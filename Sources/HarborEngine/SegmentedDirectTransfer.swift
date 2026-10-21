import Foundation

/// Conservative acceleration: validate the same representation on every range,
/// or discard all segmented bytes and let the ordinary worker start afresh.
enum SegmentedDirectTransfer {
    static func run(source: URL, stagingDirectory: URL, control: TransferControl, browserInitiated: Bool = false, maximumConnections: Int = 4, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferResult? {
        guard !browserInitiated, maximumConnections > 1 else { return nil }
        if control.isStopped { throw EngineError.cancelled }
        guard let representation = try await RangeProbe(source: source, control: control).start() else { return nil }
        let file = stagingDirectory.appendingPathComponent("accelerated.partial")
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        do {
            return try await RangeGroup(representation: representation, file: file, connections: min(4, maximumConnections), control: control, progress: progress).start()
        } catch is RangeFallback {
            try? FileManager.default.removeItem(at: file)
            if control.isStopped { throw EngineError.cancelled }
            return nil
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }
}

private struct RangeRepresentation {
    let url: URL
    let total: Int64
    let etag: String
    let filename: String
}

private enum RangeFallback: Error { case unsupported }

private enum RangeHeaders {
    static func isStrongETag(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (2...8192).contains(bytes.count), bytes.first == 0x22, bytes.last == 0x22 else { return false }
        return bytes.dropFirst().dropLast().allSatisfy { byte in
            byte == 0x21 || (0x23...0x7E).contains(byte) || byte >= 0x80
        }
    }
    static func interval(_ response: HTTPURLResponse) -> (start: Int64, end: Int64, total: Int64)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"),
              header.hasPrefix("bytes ") else { return nil }
        let parts = header.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = Int64(bounds[0]), let end = Int64(bounds[1]), start >= 0, end >= start, end < total else { return nil }
        return (start, end, total)
    }
    static func isIdentity(_ response: HTTPURLResponse) -> Bool {
        guard let encoding = response.value(forHTTPHeaderField: "Content-Encoding") else { return true }
        return encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "identity"
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("MVD/0.3", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return configuration
    }
    static func safeRedirect(_ response: HTTPURLResponse, _ request: URLRequest) -> URLRequest? {
        guard let url = request.url, (try? URLValidation.source(url.absoluteString)) != nil,
              !(response.url?.scheme == "https" && url.scheme == "http") else { return nil }
        return request
    }
}

private final class RangeProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let control: TransferControl
    private var session: URLSession?
    private var continuation: CheckedContinuation<RangeRepresentation?, Error>?
    private var representation: RangeRepresentation?
    private var received = 0
    private var redirects = 0

    init(source: URL, control: TransferControl) { self.source = source; self.control = control }

    func start() async throws -> RangeRepresentation? {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = RangeHeaders.configuration()
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 15
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = RangeHeaders.request(source)
            request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            let task = session.dataTask(with: request)
            control.install { [weak task] in task?.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 206,
              let interval = RangeHeaders.interval(response), interval.start == 0, interval.end == 0,
              interval.total >= 4 * 1024 * 1024, RangeHeaders.isIdentity(response),
              let etag = response.value(forHTTPHeaderField: "ETag"), RangeHeaders.isStrongETag(etag),
              let finalURL = response.url,
              response.mimeType?.lowercased() != "text/html" else {
            completionHandler(.cancel)
            return
        }
        representation = RangeRepresentation(url: finalURL, total: interval.total, etag: etag, filename: URLValidation.filename(response.suggestedFilename ?? source.lastPathComponent))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        if received > 1 { representation = nil; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 8 else { completionHandler(nil); task.cancel(); return }
        completionHandler(RangeHeaders.safeRedirect(response, request))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<RangeRepresentation?, Error>
        if control.isStopped { result = .failure(EngineError.cancelled) }
        else if error == nil, received == 1 { result = .success(representation) }
        else { result = .success(nil) }
        control.clear()
        session.finishTasksAndInvalidate()
        self.session = nil
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }
}

private final class RangeGroup: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Part {
        let start: Int64
        let end: Int64
        var received: Int64 = 0
        var validated = false
        var length: Int64 { end - start + 1 }
    }
    private let representation: RangeRepresentation
    private let file: URL
    private let connections: Int
    private let control: TransferControl
    private let progress: @Sendable (TransferProgress) -> Void
    private var session: URLSession?
    private var writer: FileHandle?
    private var continuation: CheckedContinuation<TransferResult, Error>?
    private var parts: [Int: Part] = [:]
    private var pending: Set<Int> = []
    private var tasks: [URLSessionTask] = []
    private var failure: Error?
    private var started = Date()
    private var lastProgress = Date.distantPast

    init(representation: RangeRepresentation, file: URL, connections: Int, control: TransferControl, progress: @escaping @Sendable (TransferProgress) -> Void) {
        self.representation = representation; self.file = file; self.connections = connections
        self.control = control; self.progress = progress
    }

    func start() async throws -> TransferResult {
        guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw EngineError.storage("Could not create the accelerated download staging file.")
        }
        writer = try FileHandle(forWritingTo: file)
        try writer?.truncate(atOffset: UInt64(representation.total))
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = RangeHeaders.configuration()
            configuration.httpMaximumConnectionsPerHost = connections
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let chunk = representation.total / Int64(connections) + (representation.total % Int64(connections) == 0 ? 0 : 1)
            for index in 0..<connections {
                let start = Int64(index) * chunk
                guard start < representation.total else { break }
                let end = start + min(chunk, representation.total - start) - 1
                var request = RangeHeaders.request(representation.url)
                request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
                request.setValue(representation.etag, forHTTPHeaderField: "If-Range")
                let task = session.dataTask(with: request)
                parts[task.taskIdentifier] = Part(start: start, end: end)
                pending.insert(task.taskIdentifier)
                tasks.append(task)
            }
            control.install { [weak session] in session?.invalidateAndCancel() }
            progress(TransferProgress(received: 0, total: representation.total, speed: 0, title: representation.filename))
            for task in tasks { task.resume() }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard failure == nil, !control.isStopped, var part = parts[dataTask.taskIdentifier],
              let response = response as? HTTPURLResponse, response.statusCode == 206,
              let interval = RangeHeaders.interval(response), interval.start == part.start, interval.end == part.end,
              interval.total == representation.total, RangeHeaders.isIdentity(response),
              response.value(forHTTPHeaderField: "ETag") == representation.etag,
              response.expectedContentLength < 0 || response.expectedContentLength == part.length else {
            abort(RangeFallback.unsupported)
            completionHandler(.cancel)
            return
        }
        part.validated = true
        parts[dataTask.taskIdentifier] = part
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !control.isStopped, var part = parts[dataTask.taskIdentifier], part.validated else { dataTask.cancel(); return }
        guard Int64(data.count) <= part.length - part.received else { abort(RangeFallback.unsupported); return }
        do {
            try writer?.seek(toOffset: UInt64(part.start + part.received))
            try writer?.write(contentsOf: data)
            part.received += Int64(data.count)
            parts[dataTask.taskIdentifier] = part
            if Date().timeIntervalSince(lastProgress) >= 0.3 {
                lastProgress = Date()
                let total = parts.values.reduce(Int64(0)) { $0 + $1.received }
                progress(TransferProgress(received: total, total: representation.total, speed: Double(total) / max(0.01, Date().timeIntervalSince(started)), title: nil))
            }
        } catch { abort(EngineError.storage("Could not write accelerated download data. Check free disk space.")) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Representation changed after the probe: discard ranges and retry one
        // complete response through the normal redirect-aware worker.
        abort(RangeFallback.unsupported)
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard pending.remove(task.taskIdentifier) != nil else { return }
        if control.isStopped { abort(EngineError.cancelled) }
        else if failure == nil {
            if let error { abort(error) }
            else if let part = parts[task.taskIdentifier], !part.validated || part.received != part.length { abort(RangeFallback.unsupported) }
        }
        guard pending.isEmpty else { return }
        let result: Result<TransferResult, Error>
        do {
            if control.isStopped { throw EngineError.cancelled }
            if let failure { throw failure }
            guard parts.values.allSatisfy({ $0.validated && $0.received == $0.length }),
                  parts.values.reduce(Int64(0), { $0 + $1.received }) == representation.total else { throw RangeFallback.unsupported }
            try writer?.synchronize()
            try writer?.close(); writer = nil
            progress(TransferProgress(received: representation.total, total: representation.total, speed: 0, title: nil))
            result = .success(TransferResult(file: file, filename: representation.filename))
        } catch {
            try? writer?.close(); writer = nil
            result = .failure(error)
        }
        control.clear()
        session.finishTasksAndInvalidate(); self.session = nil
        let callback = continuation; continuation = nil
        callback?.resume(with: result)
    }

    private func abort(_ error: Error) {
        if failure == nil { failure = error }
        for task in tasks { task.cancel() }
    }
}
