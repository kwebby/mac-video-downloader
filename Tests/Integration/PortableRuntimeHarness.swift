import Foundation
import HarborCore
@testable import HarborEngine

@main
enum PortableRuntimeHarness {
    static func main() throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("mvd-portable-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original/MVD.app", isDirectory: true)
        let resources = original.appendingPathComponent("Contents/Resources", isDirectory: true)
        let tools = resources.appendingPathComponent("Tools", isDirectory: true)
        try manager.createDirectory(at: tools, withIntermediateDirectories: true)
        try manager.createDirectory(at: original.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for name in ["yt-dlp", "ffmpeg", "ffprobe", "deno"] {
            precondition(manager.createFile(atPath: tools.appendingPathComponent(name).path, contents: Data("fixture".utf8), attributes: [.posixPermissions: 0o700]))
        }
        let manifest = ["HARBOR_YTDLP_PATH": "Tools/yt-dlp", "HARBOR_FFMPEG_PATH": "Tools/ffmpeg", "HARBOR_DENO_PATH": "Tools/deno"]
        func writeManifest(_ values: [String: String], at resourceRoot: URL) throws {
            try JSONEncoder().encode(values).write(to: resourceRoot.appendingPathComponent("runtime.json"))
        }
        let originalExecutable = original.appendingPathComponent("Contents/MacOS/HarborBroker")
        precondition(ProviderTools(environment: [:], executableURL: originalExecutable).downloader == tools.appendingPathComponent("yt-dlp").path)
        try writeManifest(manifest, at: resources)
        let discovered = ProviderTools(environment: [:], executableURL: originalExecutable)
        precondition(discovered.downloader == tools.appendingPathComponent("yt-dlp").path)
        precondition(discovered.ffmpeg == tools.appendingPathComponent("ffmpeg").path)
        precondition(discovered.deno == tools.appendingPathComponent("deno").path)

        // Moving and renaming the full app must not depend on the previous
        // directory or on the launching app being Bundle.main.
        let moved = directory.appendingPathComponent("Moved MVD ♫.app", isDirectory: true)
        try manager.moveItem(at: original, to: moved)
        let movedResources = moved.appendingPathComponent("Contents/Resources", isDirectory: true)
        let movedTools = movedResources.appendingPathComponent("Tools", isDirectory: true)
        let movedExecutable = moved.appendingPathComponent("Contents/MacOS/HarborNativeHost")
        let relocated = ProviderTools(environment: [:], executableURL: movedExecutable)
        precondition(relocated.downloader == movedTools.appendingPathComponent("yt-dlp").path)
        precondition(relocated.ffmpeg == movedTools.appendingPathComponent("ffmpeg").path)
        precondition(relocated.deno == movedTools.appendingPathComponent("deno").path)
        precondition(manager.isExecutableFile(atPath: URL(fileURLWithPath: relocated.ffmpeg!).deletingLastPathComponent().appendingPathComponent("ffprobe").path))
        let childEnvironment = MediaToolRuntime.environment(merging: ["UNRELATED": "preserved"], executable: movedExecutable)
        precondition(childEnvironment["HARBOR_FFMPEG_PATH"] == relocated.ffmpeg && childEnvironment["UNRELATED"] == "preserved")

        let explicit = directory.appendingPathComponent("custom-yt-dlp")
        precondition(manager.createFile(atPath: explicit.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        let overridden = ProviderTools(environment: ["HARBOR_YTDLP_PATH": explicit.path], executableURL: movedExecutable)
        precondition(overridden.downloader == explicit.path && overridden.ffmpeg == relocated.ffmpeg)
        let missingOverride = ProviderTools(environment: ["HARBOR_YTDLP_PATH": "/missing-mvd-test-tool"], executableURL: movedExecutable)
        precondition(missingOverride.downloader == nil, "An invalid explicit override must not fall through to bundled or system tools.")
        var changed = manifest
        changed["HARBOR_YTDLP_PATH"] = "../custom-yt-dlp"
        try writeManifest(changed, at: movedResources)
        precondition(ProviderTools(environment: [:], executableURL: movedExecutable).downloader == nil)
        try manager.removeItem(at: movedTools.appendingPathComponent("yt-dlp"))
        try manager.createSymbolicLink(at: movedTools.appendingPathComponent("yt-dlp"), withDestinationURL: explicit)
        try writeManifest(manifest, at: movedResources)
        precondition(ProviderTools(environment: [:], executableURL: movedExecutable).downloader == nil, "A relative manifest cannot escape Resources through a symlink.")

        // Absolute paths remain valid only as intentional development entries.
        changed = manifest
        changed["HARBOR_YTDLP_PATH"] = explicit.path
        try writeManifest(changed, at: movedResources)
        precondition(ProviderTools(environment: [:], executableURL: movedExecutable).downloader == explicit.path)
        try manager.removeItem(at: movedTools.appendingPathComponent("ffmpeg"))
        precondition(ProviderTools(environment: [:], executableURL: movedExecutable).ffmpeg == nil, "A declared missing tool must not select an unrelated system installation.")
        precondition(MediaToolRuntime.resourceDirectory(forExecutable: directory.appendingPathComponent("HarborBroker")) == nil)
        print("Portable runtime fixtures passed: app relocation/rename, all tools, child environment, explicit and legacy overrides, missing-tool isolation, and relative traversal/symlink guards.")
    }
}
