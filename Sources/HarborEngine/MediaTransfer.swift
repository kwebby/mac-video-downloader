import Foundation
import Darwin
import HarborCore

enum MediaTransfer {
    static func run(source: URL, stagingDirectory: URL, proxy: String?, tools: ProviderTools, quality: VideoQuality? = nil, options proposedOptions: DownloadOptions? = nil, fragmentConnections: Int = 1, control: TransferControl, progress: @escaping @Sendable (TransferProgress) -> Void) async throws -> TransferResult {
        guard let executable = tools.downloader else {
            throw EngineError.unavailable("Video downloading needs yt-dlp. Run Scripts/setup-tools.sh, then restart Harbor.")
        }
        let options = try OptionValidation.options(proposedOptions)
        if options.mode != .videoWithAudio || options.container != "auto", tools.ffmpeg == nil {
            throw EngineError.unavailable("These output options require FFmpeg. Run Scripts/setup-tools.sh and restart MVD.")
        }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var arguments = [
            "--ignore-config", "--no-plugin-dirs", "--no-update", "--no-cache-dir",
            "--no-playlist", "--max-downloads", "1", "--no-colors", "--newline", "--progress", "--no-simulate",
            "--continue", "--part", "--no-overwrites", "--restrict-filenames", "--trim-filenames", "180",
            "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3",
            "--concurrent-fragments", "\(min(8, max(1, fragmentConnections)))", "--no-write-info-json", "--no-write-thumbnail", "--no-write-subs",
            "--no-warnings", "--proxy", proxy ?? "", "--no-js-runtimes",
            "--progress-template", "download:__HARBOR_PROGRESS__%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s",
            "--print", "before_dl:__HARBOR_TITLE__%(title)j",
            "--print", "before_dl:__HARBOR_METADATA__{\"title\":%(title)j,\"thumbnail\":%(thumbnail)j,\"duration\":%(duration)j}",
            "--print", "after_move:__HARBOR_OUTPUT__%(filepath)j",
            "--print", "post_process:__HARBOR_PROCESSING__",
            "--output", stagingDirectory.appendingPathComponent("%(title).140B [%(id)s]" + (options.mode == .audioOnly ? "-audio" : "") + ".%(ext)s").path
        ]
        let selection = try MediaQuality.validate(quality)
        if let ffmpeg = tools.ffmpeg { arguments += ["--ffmpeg-location", ffmpeg] }
        let format: String
        if let id = options.formatID {
            // IDs are validated against actual metadata at acceptance. This
            // second canonical check also protects legacy persisted intents.
            guard OptionValidation.safeFormatID(id) else { throw EngineError.invalid("The stored format ID is invalid. Resolve this video again.") }
            // A bare ID such as "mp4" or "best" has selector semantics in
            // yt-dlp. Filter its literal format_id so it cannot select another
            // rendition with the same extension or a reserved selector name.
            let exact = "all[format_id='\(id)']"
            if options.mode == .videoWithAudio && tools.ffmpeg != nil { format = "\(exact)[acodec!=none]/\(exact)+ba/\(exact)" }
            else { format = exact }
        } else {
            switch options.mode {
            case .audioOnly: format = "ba/b"
            case .videoOnly: format = selection.height.map { "bv[height=\($0)]/b[height=\($0)]" } ?? "bv/b"
            case .videoWithAudio:
                if tools.ffmpeg != nil { format = selection.height.map { "bv*[height=\($0)]+ba/b[height=\($0)]" } ?? "bv*+ba/b" }
                else { format = selection.height.map { "b[height=\($0)]" } ?? "b" }
            }
        }
        arguments += ["--format", format]
        if let deno = tools.deno { arguments += ["--js-runtimes", "deno:\(deno)"] }
        // A URL is always the final positional operand and can never become an option.
        arguments += ["--", source.absoluteString]

        return try await Task.detached(priority: .utility) {
            let parser = MediaOutputParser(progress: progress)
            let status = try SafeSubprocess.run(executable: executable, arguments: arguments, directory: stagingDirectory, control: control) { parser.consume($0) }
            if control.isStopped { throw EngineError.cancelled }
            // --max-downloads 1 returns 101 after a successful first item on some
            // providers. A reported, verified final path is still required.
            guard status == 0 || status == 101 else {
                let detail = parser.diagnostic.isEmpty ? "The provider rejected the request or could not resolve this URL." : parser.diagnostic
                throw EngineError.transfer("Video download failed (exit \(status)). \(detail)")
            }
            guard let output = parser.output else {
                throw EngineError.transfer("The provider finished without reporting a completed media file.")
            }
            let file = URL(fileURLWithPath: output).standardizedFileURL
            let stage = stagingDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(stage), resolved == file.path else {
                throw EngineError.transfer("The provider reported an output outside this job's staging folder.")
            }
            if options.mode == .audioOnly {
                guard let ffmpeg = tools.ffmpeg else { throw EngineError.unavailable("FFmpeg is required for audio output.") }
                progress(TransferProgress(received: 0, total: nil, speed: 0, title: nil, isProcessing: true))
                return try AudioPostprocessor.run(file: file, ffmpeg: ffmpeg, options: options, control: control)
            }
            if options.mode == .videoOnly || options.container != "auto" {
                guard let ffmpeg = tools.ffmpeg else { throw EngineError.unavailable("FFmpeg is required for the requested output.") }
                progress(TransferProgress(received: 0, total: nil, speed: 0, title: nil, isProcessing: true))
                let ext = options.container == "auto" ? (["mp4", "mkv", "webm", "mov", "m4v"].contains(file.pathExtension.lowercased()) ? file.pathExtension.lowercased() : "mkv") : options.container
                let filename = file.deletingPathExtension().lastPathComponent + (options.mode == .videoOnly ? "-silent" : "-remux") + "." + ext
                let output = stagingDirectory.appendingPathComponent(URLValidation.filename(filename))
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                var processing = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", file.path]
                if options.mode == .videoOnly { processing += ["-map", "0:v:0", "-an", "-c:v", "copy"] }
                else { processing += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"] }
                processing += [output.path]
                var detail = ""
                let status = try SafeSubprocess.run(executable: ffmpeg, arguments: processing, directory: stagingDirectory, control: control, maximumOutputBytes: 1_048_576, timeout: 30 * 60) { line in detail = ErrorRedactor.message(line) }
                if control.isStopped { throw EngineError.cancelled }
                guard status == 0 else { throw EngineError.transfer("The requested container cannot preserve these source codecs, or media processing failed. Choose Auto or MKV. " + detail) }
                return TransferResult(file: output, filename: output.lastPathComponent)
            }
            return TransferResult(file: file, filename: file.lastPathComponent)
        }.value
    }
}

private final class MediaOutputParser {
    private let progress: @Sendable (TransferProgress) -> Void
    private(set) var output: String?
    private(set) var diagnostic = ""

    init(progress: @escaping @Sendable (TransferProgress) -> Void) { self.progress = progress }

    func consume(_ line: String) {
        if line.hasPrefix("__HARBOR_PROCESSING__") {
            progress(TransferProgress(received: 0, total: nil, speed: 0, title: nil, isProcessing: true))
        } else if line.hasPrefix("__HARBOR_PROGRESS__") {
            let parts = line.dropFirst("__HARBOR_PROGRESS__".count).split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 4 {
                let received = max(0, Int64(parts[0]) ?? 0)
                let total = Int64(parts[1]) ?? Int64(parts[2])
                let speed = max(0, Double(parts[3]) ?? 0)
                progress(TransferProgress(received: received, total: total, speed: speed, title: nil))
            }
        } else if line.hasPrefix("__HARBOR_TITLE__") {
            if let title = decode(String(line.dropFirst("__HARBOR_TITLE__".count))) {
                progress(TransferProgress(received: 0, total: nil, speed: 0, title: String(title.prefix(400))))
            }
        } else if line.hasPrefix("__HARBOR_METADATA__") {
            let data = Data(line.dropFirst("__HARBOR_METADATA__".count).utf8)
            if let preview = try? MediaResolver.parse(data) {
                progress(TransferProgress(received: 0, total: nil, speed: 0, title: preview.title, thumbnailURL: preview.thumbnailURL, duration: preview.duration))
            }
        } else if line.hasPrefix("__HARBOR_OUTPUT__") {
            output = decode(String(line.dropFirst("__HARBOR_OUTPUT__".count)))
        } else if line.contains("ERROR:") {
            diagnostic = ErrorRedactor.message(line)
        }
    }

    private func decode(_ value: String) -> String? { try? JSONDecoder().decode(String.self, from: Data(value.utf8)) }
}

/// Launch arguments directly with posix_spawn. A private process group lets
/// pause/cancel stop FFmpeg and other descendants as well as yt-dlp itself.
enum SafeSubprocess {
    static func run(executable: String, arguments: [String], directory: URL, control: TransferControl, maximumOutputBytes: Int? = nil, maximumLineBytes: Int = 32_768, timeout: TimeInterval? = nil, line: (String) -> Void) throws -> Int32 {
        if control.isStopped { throw EngineError.cancelled }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw EngineError.unavailable("Could not create the media worker output pipe.") }
        let readFD = descriptors[0], writeFD = descriptors[1]
        defer { close(readFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, writeFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, readFD)
        posix_spawn_file_actions_addclose(&actions, writeFD)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("DYLD_") || ["PYTHONPATH", "PYTHONHOME"].contains(key) {
            environment.removeValue(forKey: key)
        }
        environment["PYTHONUNBUFFERED"] = "1"
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnError = argv.withUnsafeBufferPointer { argvBuffer in
            envp.withUnsafeBufferPointer { envBuffer in
                posix_spawn(&pid, executable, &actions, &attributes, UnsafeMutablePointer(mutating: argvBuffer.baseAddress!), UnsafeMutablePointer(mutating: envBuffer.baseAddress!))
            }
        }
        close(writeFD)
        guard spawnError == 0 else { throw EngineError.unavailable("The media worker could not start (\(String(cString: strerror(spawnError)))). Repair its runtime installation.") }
        let group = ProcessGroup(pid: pid)
        control.install { group.stop() }
        let deadline = timeout.map { timeout -> DispatchWorkItem in
            let item = DispatchWorkItem { group.stop(reason: "Media information lookup timed out. Try again or use a direct media URL.") }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            return item
        }
        defer { deadline?.cancel(); group.finish(); control.clear() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var pending = Data()
        var outputBytes = 0
        while true {
            let count = read(readFD, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            outputBytes += count
            if let maximumOutputBytes, outputBytes > maximumOutputBytes {
                group.stop(reason: "The provider returned too much media information. Try a single video URL.")
                pending.removeAll(keepingCapacity: false)
                continue
            }
            pending.append(contentsOf: buffer.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let data = pending[..<newline]
                line(String(decoding: data.suffix(maximumLineBytes), as: UTF8.self).trimmingCharacters(in: .newlines))
                pending.removeSubrange(...newline)
            }
            // Corrupt or hostile provider output cannot grow broker memory forever.
            if pending.count > maximumLineBytes * 2 { pending = Data(pending.suffix(maximumLineBytes)) }
        }
        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { throw EngineError.transfer("Could not collect the media worker's exit status.") }
        }
        if let reason = group.limitReason { throw EngineError.unavailable(reason) }
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}

private final class ProcessGroup: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var finished = false
    private var reason: String?
    var limitReason: String? { lock.withLock { reason } }
    init(pid: pid_t) { self.pid = pid }
    func finish() { lock.withLock { finished = true } }
    func stop(reason: String? = nil) {
        lock.withLock {
            if !finished {
                if self.reason == nil { self.reason = reason }
                kill(-pid, SIGTERM)
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock { if !finished { kill(-pid, SIGKILL) } }
        }
    }
}
