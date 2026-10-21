import Foundation
import HarborCore

/// This first direct engine streams a fresh HTTP response to an owned staging
/// file. Resume intentionally starts over; it never appends unverifiable bytes.
final class DirectTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: URL
    private let stagingFile: URL
    private let control: TransferControl
    private let progress: @Sendable (TransferProgress) -> Void
    private let rejectHTML: Bool
    private let browserInitiated: Bool
    private let browserMediaAuthorized: Bool
    private var session: URLSession?
    private var continuation: CheckedContinuation<TransferResult, Error>?
    private var writer: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var filename: String
    private var failure: Error?
    private var startDate = Date()
    private var lastUpdate = Date.distantPast
    private var redirects = 0

    init(source: URL, stagingDirectory: URL, control: TransferControl, rejectHTML: Bool, browserInitiated: Bool = false, browserMediaAuthorized: Bool = false, progress: @escaping @Sendable (TransferProgress) -> Void) {
        self.source = source
        self.stagingFile = stagingDirectory.appendingPathComponent("direct.partial")
        self.control = control
        self.progress = progress
        self.rejectHTML = rejectHTML
        self.browserInitiated = browserInitiated
        self.browserMediaAuthorized = browserMediaAuthorized
        self.filename = URLValidation.filename(source.lastPathComponent)
    }

    func start() async throws -> TransferResult {
        if browserInitiated { _ = try PublicNetworkPolicy.validate(source.absoluteString, allowVideoProviders: browserMediaAuthorized) }
        try FileManager.default.createDirectory(at: stagingFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        // This is an app-owned path, not a user file. Direct resume is a restart.
        if FileManager.default.fileExists(atPath: stagingFile.path) { try FileManager.default.removeItem(at: stagingFile) }
        guard FileManager.default.createFile(atPath: stagingFile.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw EngineError.storage("Could not create the download staging file.")
        }
        writer = try FileHandle(forWritingTo: stagingFile)
        if control.isStopped { try? writer?.close(); throw EngineError.cancelled }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: source)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("Harbor/0.1", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request)
            control.install { [weak task] in task?.cancel() }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            failure = EngineError.transfer("The source did not return an HTTP response.")
            completionHandler(.cancel); return
        }
        guard (200...299).contains(response.statusCode), response.statusCode != 206 else {
            failure = EngineError.transfer("The server returned HTTP \(response.statusCode). Refresh an expired URL or retry later.")
            completionHandler(.cancel); return
        }
        if rejectHTML && response.mimeType?.lowercased() == "text/html" {
            failure = EngineError.transfer("The file URL returned a webpage. Try the original video page using automatic detection.")
            completionHandler(.cancel); return
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        // URLSession transparently decodes compressed responses, so their wire
        // Content-Length cannot be compared to the decoded bytes written here.
        if response.expectedContentLength >= 0 && (encoding == nil || encoding == "identity") { expected = response.expectedContentLength }
        if let suggested = response.suggestedFilename, !suggested.isEmpty {
            filename = URLValidation.filename(suggested, fallback: filename)
        }
        progress(TransferProgress(received: 0, total: expected, speed: 0, title: filename))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, !control.isStopped else { dataTask.cancel(); return }
        do {
            try writer?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastUpdate) >= 0.35 {
                lastUpdate = Date()
                progress(TransferProgress(received: received, total: expected, speed: Double(received) / max(0.01, Date().timeIntervalSince(startDate)), title: nil))
            }
        } catch {
            failure = EngineError.storage("Could not write download data. Check free disk space and folder permissions.")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 10, let url = request.url, (try? URLValidation.source(url.absoluteString)) != nil,
              !(response.url?.scheme == "https" && url.scheme == "http") else {
            failure = EngineError.transfer("The source returned an unsafe redirect or too many redirects.")
            completionHandler(nil); task.cancel(); return
        }
        if browserInitiated {
            do { _ = try PublicNetworkPolicy.validate(url.absoluteString, allowVideoProviders: browserMediaAuthorized) }
            catch { failure = error; completionHandler(nil); task.cancel(); return }
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { control.clear(); session.finishTasksAndInvalidate(); self.session = nil }
        var outcome: Result<TransferResult, Error>
        do {
            if control.isStopped { throw EngineError.cancelled }
            if let failure { throw failure }
            if let error { throw error }
            if let expected, expected != received { throw EngineError.transfer("The response ended before all expected bytes arrived. Resume to restart safely.") }
            try writer?.synchronize()
            try writer?.close()
            writer = nil
            progress(TransferProgress(received: received, total: expected, speed: 0, title: nil))
            outcome = .success(TransferResult(file: stagingFile, filename: filename, allowsEmpty: true))
        } catch {
            try? writer?.close()
            writer = nil
            outcome = .failure(error)
        }
        continuation?.resume(with: outcome)
        continuation = nil
    }
}
