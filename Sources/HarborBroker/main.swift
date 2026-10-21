import Foundation
import Darwin
import HarborCore
import HarborEngine

@main
struct HarborBrokerMain {
    static func main() async {
        do {
            signal(SIGPIPE, SIG_IGN)
            let root = HarborPaths.supportDirectory
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(root.path, 0o700)
            let lock = Darwin.open(root.appendingPathComponent("broker.lock").path, O_CREAT | O_RDWR, 0o600)
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
            defer { flock(lock, LOCK_UN); Darwin.close(lock) }
            let service = try DownloadService(rootDirectory: root)
            let server = try LocalServer(service: service)
            await server.run()
        } catch {
            FileHandle.standardError.write(Data("Harbor service could not start: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}

final class LocalServer: @unchecked Sendable {
    let service: DownloadService
    let descriptor: Int32
    init(service: DownloadService) throws {
        self.service = service
        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TransportError.unavailable }
        unlink(HarborPaths.socketPath)
        var address = try LocalTransport.address(path: HarborPaths.socketPath)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw TransportError.system("Could not create the local download-service socket.") }
        chmod(HarborPaths.socketPath, 0o600)
        guard listen(descriptor, 16) == 0 else { Darwin.close(descriptor); throw TransportError.unavailable }
    }
    func run() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let peer = accept(self.descriptor, nil, nil)
                    if peer < 0 { if errno == EINTR { continue }; break }
                    var timeout = timeval(tv_sec: 10, tv_usec: 0)
                    setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                    var noPipe: Int32 = 1
                    setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
                    Task.detached { await self.handle(peer) }
                }
                continuation.resume()
            }
        }
    }
    func handle(_ peer: Int32) async {
        defer { Darwin.close(peer) }
        do {
            try LocalTransport.validatePeer(peer)
            let request = try JSONDecoder().decode(BrokerRequest.self, from: LocalTransport.readFrame(peer))
            guard request.protocolVersion == 1 else {
                try LocalTransport.writeFrame(JSONEncoder().encode(BrokerResponse(requestID: request.requestID, error: "The app and service need matching versions.")), to: peer)
                return
            }
            if request.command == .shutdown {
                await service.stop()
                try LocalTransport.writeFrame(JSONEncoder().encode(BrokerResponse(requestID: request.requestID)), to: peer)
                unlink(HarborPaths.socketPath)
                exit(0)
            }
            let response = await service.handle(request)
            try LocalTransport.writeFrame(JSONEncoder().encode(response), to: peer)
        } catch {
            // A disconnected/malformed client must not interrupt accepted jobs.
        }
    }
}
