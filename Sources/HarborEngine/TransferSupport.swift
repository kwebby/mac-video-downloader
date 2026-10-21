import Foundation
import Darwin
import HarborCore

struct TransferProgress: Sendable {
    var received: Int64
    var total: Int64?
    var speed: Double
    var title: String?
    var thumbnailURL: String? = nil
    var duration: Double? = nil
    var isProcessing: Bool = false
}

struct TransferResult: Sendable {
    var file: URL
    var filename: String
    var allowsEmpty = false
}

/// Cancellation is shared with URLSession callbacks and a POSIX process group.
final class TransferControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var cancellation: (() -> Void)?

    var isStopped: Bool { lock.withLock { stopped } }

    func install(_ action: @escaping () -> Void) {
        let shouldStop = lock.withLock { () -> Bool in
            if stopped { return true }
            cancellation = action
            return false
        }
        if shouldStop { action() }
    }

    func clear() { lock.withLock { cancellation = nil } }

    func stop() {
        let action = lock.withLock { () -> (() -> Void)? in
            stopped = true
            return cancellation
        }
        action?()
    }
}

enum URLValidation {
    static func source(_ string: String) throws -> URL {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 16_384, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw EngineError.invalid("Enter a complete HTTP or HTTPS URL without embedded credentials.")
        }
        return url
    }

    static func settings(_ settings: DownloadSettings) throws -> DownloadSettings {
        guard (1...8).contains(settings.maxConcurrent) else { throw EngineError.invalid("Choose between 1 and 8 simultaneous downloads.") }
        guard settings.destinationDirectory.hasPrefix("/"), !settings.destinationDirectory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), settings.destinationDirectory.utf8.count < 4_096 else {
            throw EngineError.invalid("Choose an absolute destination folder path.")
        }
        var result = settings
        result.destinationDirectory = URL(fileURLWithPath: settings.destinationDirectory, isDirectory: true).standardizedFileURL.path
        if let value = settings.proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            guard let parts = URLComponents(string: value), let scheme = parts.scheme?.lowercased(),
                  ["http", "https", "socks4", "socks4a", "socks5", "socks5h"].contains(scheme),
                  let host = parts.host, !host.isEmpty, parts.port.map({ (1...65_535).contains($0) }) ?? true,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.path.isEmpty || parts.path == "/" else {
                throw EngineError.invalid("Enter an HTTP(S) or SOCKS proxy URL without credentials. Authenticated proxy profiles are not available yet.")
            }
            result.proxyURL = value
        } else { result.proxyURL = nil }
        return result
    }

    static func isDirectFile(_ url: URL) -> Bool {
        let extensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "zip", "gz", "bz2", "xz", "7z", "rar", "dmg", "pkg", "iso", "pdf", "epub", "jpg", "jpeg", "png", "gif", "webp", "csv", "json", "txt", "exe", "msi", "deb", "rpm"]
        return extensions.contains(url.pathExtension.lowercased())
    }

    static func filename(_ proposed: String, fallback: String = "download") -> String {
        let basename = proposed.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? fallback
        let characters = basename.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" }
        let cleaned = String(String.UnicodeScalarView(characters)).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = cleaned.isEmpty || cleaned == "." || cleaned == ".." ? fallback : cleaned
        // Keep room for a numeric collision suffix within the filesystem's byte limit.
        if result.utf8.count <= 200 { return result.hasPrefix(".") ? "download-\(result)" : result }
        var ext = (result as NSString).pathExtension
        while ext.utf8.count > 32 { ext.removeLast() }
        var stem = (result as NSString).deletingPathExtension
        while stem.utf8.count + ext.utf8.count > 190 { stem.removeLast() }
        let shortened = (stem.isEmpty ? "download" : stem) + (ext.isEmpty ? "" : "." + ext)
        return shortened.hasPrefix(".") ? "download-\(shortened)" : shortened
    }
}

enum OutputPublisher {
    /// Copy into the destination filesystem, fsync, then publish with link(2).
    /// link never replaces an existing name, including one created concurrently.
    static func publish(_ result: TransferResult, destination: URL, control: TransferControl) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let values = try result.file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, result.allowsEmpty || (values.fileSize ?? 0) > 0 else {
            throw EngineError.transfer("The server did not produce a valid, nonempty file.")
        }
        let temporary = destination.appendingPathComponent(".harbor-\(UUID().uuidString).partial")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw EngineError.storage("Could not create a file in the destination folder: \(String(cString: strerror(errno))).") }
        let writer = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? writer.close(); try? manager.removeItem(at: temporary) }
        let reader = try FileHandle(forReadingFrom: result.file)
        defer { try? reader.close() }
        while true {
            if control.isStopped { throw EngineError.cancelled }
            guard let block = try reader.read(upToCount: 1_048_576), !block.isEmpty else { break }
            try writer.write(contentsOf: block)
        }
        try writer.synchronize()
        var identity = stat()
        guard fstat(fd, &identity) == 0 else { throw EngineError.storage("Could not verify the staged output file.") }
        let filename = URLValidation.filename(result.filename)
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for suffix in 0..<10_000 {
            if control.isStopped { throw EngineError.cancelled }
            let name = suffix == 0 ? filename : "\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            let output = destination.appendingPathComponent(name)
            // The receipt precedes publication. On recovery its inode identity
            // proves whether this exact file reached its final name before a
            // crash between filesystem publication and SQLite completion.
            try PublicationReceipt(path: output.path, device: UInt64(truncatingIfNeeded: identity.st_dev), inode: UInt64(identity.st_ino), size: identity.st_size)
                .save(in: result.file.deletingLastPathComponent())
            if link(temporary.path, output.path) == 0 {
                let directoryFD = open(destination.path, O_RDONLY)
                if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
                return output
            }
            guard errno == EEXIST else {
                throw EngineError.storage("Could not publish the completed file: \(String(cString: strerror(errno))).")
            }
        }
        throw EngineError.storage("Too many files already use this filename. Choose another destination folder.")
    }
}

struct PublicationReceipt: Codable {
    let path: String
    let device: UInt64
    let inode: UInt64
    let size: Int64

    func save(in directory: URL) throws {
        let url = directory.appendingPathComponent("publication.json")
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let fd = open(directory.path, O_RDONLY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }

    static func recover(in directory: URL, destination: String) -> URL? {
        let receiptURL = directory.appendingPathComponent("publication.json")
        guard let data = try? Data(contentsOf: receiptURL), data.count < 16_384,
              let receipt = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        let output = URL(fileURLWithPath: receipt.path).standardizedFileURL
        guard output.deletingLastPathComponent().path == URL(fileURLWithPath: destination).standardizedFileURL.path else { return nil }
        var identity = stat()
        guard lstat(output.path, &identity) == 0, (identity.st_mode & S_IFMT) == S_IFREG,
              UInt64(truncatingIfNeeded: identity.st_dev) == receipt.device, UInt64(identity.st_ino) == receipt.inode, identity.st_size == receipt.size else { return nil }
        return output
    }
}

enum ErrorRedactor {
    static func message(_ error: Error) -> String { message(error.localizedDescription) }
    static func message(_ string: String) -> String {
        var result = string
        for pattern in [#"https?://[^\s\"'<>]+"#, #"(?i)(authorization|cookie|token|password)\s*[:=]\s*[^\s]+"#] {
            if let expression = try? NSRegularExpression(pattern: pattern) {
                result = expression.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "[redacted]")
            }
        }
        return String(result.suffix(2_000))
    }
}
