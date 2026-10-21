import Foundation
import HarborCore

@main
struct HarborCLI {
    static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard let verb = args.first else { usage(); return }
            let request: BrokerRequest
            switch verb {
            case "hello": request = BrokerRequest(command: .hello)
            case "list": request = BrokerRequest(command: .list)
            case "add":
                guard args.count >= 2 else { usage(); exit(1) }
                var kind = DownloadKind.automatic
                var quality: VideoQuality?
                var index = 2
                while index < args.count {
                    switch args[index] {
                    case "--direct": kind = .direct
                    case "--media": kind = .media
                    case "--quality":
                        guard index + 1 < args.count else { usage(); exit(1) }
                        index += 1
                        let value = args[index].lowercased()
                        if value == "best" { quality = .best }
                        else if let height = Int(value.hasSuffix("p") ? String(value.dropLast()) : value), (1...8640).contains(height) {
                            quality = VideoQuality(id: "\(height)p", label: "\(height)p", height: height)
                        } else { usage(); exit(1) }
                    default: usage(); exit(1)
                    }
                    index += 1
                }
                request = BrokerRequest(command: .enqueue, url: args[1], idempotencyKey: UUID().uuidString, kind: kind, quality: quality)
            case "resolve":
                guard args.count == 2 else { usage(); exit(1) }
                request = BrokerRequest(command: .resolveMedia, url: args[1])
            case "fetch":
                guard args.count == 2 else { usage(); exit(1) }
                request = BrokerRequest(command: .inspectPage, url: args[1])
            case "pause", "resume", "cancel", "remove":
                guard args.count == 2, let id = UUID(uuidString: args[1]), let command = BrokerCommand(rawValue: verb) else { usage(); exit(1) }
                request = BrokerRequest(command: command, jobID: id)
            case "settings":
                try await BrokerLauncher.ensureRunning()
                let current = try await BrokerClient().send(BrokerRequest(command: .hello))
                var settings = current.settings ?? DownloadSettings()
                var index = 1
                while index < args.count {
                    guard index + 1 < args.count else { usage(); exit(1) }
                    switch args[index] {
                    case "--destination": settings.destinationDirectory = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.path
                    case "--concurrent": settings.maxConcurrent = Int(args[index + 1]) ?? 0
                    case "--proxy": settings.proxyURL = args[index + 1] == "none" ? nil : args[index + 1]
                    default: usage(); exit(1)
                    }
                    index += 2
                }
                request = BrokerRequest(command: .setSettings, settings: settings)
            case "shutdown": request = BrokerRequest(command: .shutdown)
            default: usage(); exit(1)
            }
            if request.command != .shutdown { try await BrokerLauncher.ensureRunning() }
            let response = try await BrokerClient().send(request)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(response))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if response.error != nil { exit(1) }
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
    static func usage() {
        print("""
        Harbor developer CLI
          harborctl hello | list
          harborctl add URL [--direct|--media] [--quality best|720p|1080p|...]
          harborctl resolve URL
          harborctl fetch URL
          harborctl pause|resume|cancel|remove JOB_ID
          harborctl settings [--destination PATH] [--concurrent 1..8] [--proxy URL|none]
          harborctl shutdown
        Set HARBOR_SUPPORT_DIR to isolate test data.
        """)
    }
}
