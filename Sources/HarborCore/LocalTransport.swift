import Foundation
import Darwin

public enum TransportError: LocalizedError {
    case unavailable, invalidFrame, protocolMismatch, system(String), unsafePeer
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The download service is not connected. Try reconnecting."
        case .invalidFrame: return "The download service returned an invalid message."
        case .protocolMismatch: return "The app and download service need matching versions."
        case .system(let message): return message
        case .unsafePeer: return "The local download service belongs to another user."
        }
    }
}

/// Length-prefixed local messages. No HTTP listener or media bytes cross this channel.
public enum LocalTransport {
    public static let maximumFrameBytes = 4 * 1024 * 1024

    public static func address(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw TransportError.system("The service path is too long. Choose a shorter application-support path.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        return address
    }

    public static func validatePeer(_ descriptor: Int32) throws {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(descriptor, &effectiveUID, &effectiveGID) == 0, effectiveUID == getuid() else {
            throw TransportError.unsafePeer
        }
    }

    public static func readFrame(_ descriptor: Int32) throws -> Data {
        let header = try readExactly(descriptor, count: 4)
        let length = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        guard length > 0, length <= maximumFrameBytes else { throw TransportError.invalidFrame }
        return try readExactly(descriptor, count: length)
    }

    public static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard !data.isEmpty, data.count <= maximumFrameBytes else { throw TransportError.invalidFrame }
        var length = UInt32(data.count).littleEndian
        try withUnsafeBytes(of: &length) { try writeAll(Data($0), to: descriptor) }
        try writeAll(data, to: descriptor)
    }

    private static func readExactly(_ descriptor: Int32, count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let size = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), count - offset)
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw TransportError.invalidFrame }
                offset += size
            }
        }
        return result
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let size = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw TransportError.unavailable }
                offset += size
            }
        }
    }
}

public struct BrokerClient: Sendable {
    public var socketPath: String
    public init(socketPath: String = HarborPaths.socketPath) { self.socketPath = socketPath }

    public func send(_ request: BrokerRequest) async throws -> BrokerResponse {
        try await Task.detached(priority: .userInitiated) { try self.sendBlocking(request) }.value
    }

    private func sendBlocking(_ request: BrokerRequest) throws -> BrokerResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TransportError.unavailable }
        defer { Darwin.close(descriptor) }
        var noPipe: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 35, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = try LocalTransport.address(path: socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw TransportError.unavailable }
        try LocalTransport.validatePeer(descriptor)
        try LocalTransport.writeFrame(JSONEncoder().encode(request), to: descriptor)
        let response = try JSONDecoder().decode(BrokerResponse.self, from: LocalTransport.readFrame(descriptor))
        guard response.protocolVersion == 1, response.requestID == request.requestID else { throw TransportError.protocolMismatch }
        return response
    }
}

/// Tool locations in a distributed app are relative to its own Resources
/// directory, so dragging or renaming MVD does not preserve build-Mac paths.
/// Explicit environment overrides and absolute development manifests retain
/// their existing meaning.
public enum MediaToolRuntime {
    private static let tools = [
        "HARBOR_YTDLP_PATH": "yt-dlp",
        "HARBOR_FFMPEG_PATH": "ffmpeg",
        "HARBOR_DENO_PATH": "deno"
    ]

    public static func resourceDirectory(forExecutable executable: URL) -> URL? {
        let directory = executable.standardizedFileURL.deletingLastPathComponent()
        guard directory.lastPathComponent == "MacOS",
              directory.deletingLastPathComponent().lastPathComponent == "Contents" else { return nil }
        return directory.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
    }

    public static func environment(merging environment: [String: String], executable: URL) -> [String: String] {
        guard let resources = resourceDirectory(forExecutable: executable) else { return environment }
        let manifest = resources.appendingPathComponent("runtime.json")
        guard let size = try? manifest.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16_384,
              let data = try? Data(contentsOf: manifest),
              let locations = try? JSONDecoder().decode([String: String].self, from: data) else { return environment }
        var result = environment
        for (key, name) in tools where result[key] == nil {
            guard let value = locations[key] else { continue }
            if value.hasPrefix("/"), !value.contains("\0") {
                result[key] = value
            } else {
                guard value == "Tools/\(name)" else { result[key] = ""; continue }
                let target = resources.appendingPathComponent(value).standardizedFileURL
                let resourceRoot = resources.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                // Relative manifests can name only their packaged tool. A
                // declared but invalid location disables that tool rather than
                // falling through to a different executable on this Mac.
                let valid = target.resolvingSymlinksInPath().path.hasPrefix(resourceRoot)
                result[key] = valid ? target.path : ""
            }
        }
        return result
    }
}

public enum BrokerLauncher {
    public static func ensureRunning() async throws {
        if let hello = try? await BrokerClient().send(BrokerRequest(command: .hello)) {
            if hello.serviceVersion == HarborBuild.serviceVersion { return }
            // Developer updates may add commands while preserving the wire protocol.
            // Checkpoint the older service before launching the matching sibling.
            _ = try await BrokerClient().send(BrokerRequest(command: .shutdown))
            for _ in 0..<30 {
                if (try? await BrokerClient().send(BrokerRequest(command: .hello))) == nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let executableDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        let sibling = executableDirectory.appendingPathComponent("HarborBroker")
        guard FileManager.default.isExecutableFile(atPath: sibling.path) else {
            throw TransportError.system("HarborBroker is missing. Rebuild the complete app bundle.")
        }
        try FileManager.default.createDirectory(at: HarborPaths.supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let log = HarborPaths.supportDirectory.appendingPathComponent("broker.log")
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let process = Process()
        process.executableURL = sibling
        process.environment = MediaToolRuntime.environment(merging: ProcessInfo.processInfo.environment, executable: sibling)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try output.close()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if (try? await BrokerClient().send(BrokerRequest(command: .hello))) != nil { return }
        }
        throw TransportError.system("The download service could not start. See broker.log in Harbor’s application-support folder.")
    }
}
