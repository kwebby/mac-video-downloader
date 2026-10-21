import Foundation
import HarborCore

struct ProviderTools: Sendable {
    let downloader: String?
    let ffmpeg: String?
    let deno: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment, executableURL: URL? = nil) {
        let executable = executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "/").standardizedFileURL
        let resources = MediaToolRuntime.resourceDirectory(forExecutable: executable)
        let runtime = MediaToolRuntime.environment(merging: environment, executable: executable)
        // The broker and native host are plain sibling executables. Derive
        // Resources from their actual path rather than assuming Bundle.main is
        // the top-level app bundle when Chrome launches the host directly.
        let candidates: [String?] = [
            resources?.appendingPathComponent("Tools", isDirectory: true).path,
            executable.deletingLastPathComponent().path,
            resources?.deletingLastPathComponent().appendingPathComponent("Helpers", isDirectory: true).path,
            resources?.appendingPathComponent("tools", isDirectory: true).path,
            "/opt/homebrew/bin", "/usr/local/bin"
        ]
        let directories = candidates.compactMap { $0 }
        func find(_ name: String, override: String) -> String? {
            // An explicit bad override or declared missing packaged tool must
            // not silently run a different executable from this computer.
            let paths = runtime[override].map { [$0] } ?? directories.map { $0 + "/" + name }
            return paths.first { $0.hasPrefix("/") && !$0.contains("\0") && FileManager.default.isExecutableFile(atPath: $0) }
        }
        downloader = find("yt-dlp", override: "HARBOR_YTDLP_PATH")
        ffmpeg = find("ffmpeg", override: "HARBOR_FFMPEG_PATH")
        deno = find("deno", override: "HARBOR_DENO_PATH")
    }

    var capabilities: [ToolCapability] {
        [
            ToolCapability(id: "direct", name: "Direct files", available: true, detail: "HTTP(S) streaming with optional validated range acceleration for eligible servers. Direct resumes restart safely; no fixed speed multiplier is promised."),
            ToolCapability(id: "yt-dlp", name: "Video providers", available: downloader != nil, detail: downloader.map { "yt-dlp: \($0). Supported public pages, HLS and DASH; sites may require access or change." } ?? "yt-dlp is missing. Repair the MVD installation or use direct file URLs."),
            ToolCapability(id: "ffmpeg", name: "Media assembly", available: ffmpeg != nil, detail: ffmpeg.map { "FFmpeg: \($0)" } ?? "FFmpeg is missing. Separate audio/video tracks cannot be merged."),
            ToolCapability(id: "deno", name: "YouTube JavaScript runtime", available: deno != nil, detail: deno.map { "Deno: \($0). The matching yt-dlp EJS package must also be installed." } ?? "Deno is missing. Some providers, including YouTube, may be unavailable."),
            ToolCapability(id: "proxy", name: "Proxy support", available: downloader != nil, detail: "Unauthenticated HTTP(S)/SOCKS proxies apply to media jobs. Direct-file proxies and authenticated profiles are not available yet.")
        ]
    }
}
