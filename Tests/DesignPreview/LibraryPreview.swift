import AppKit
import Foundation
import HarborCore
import SwiftUI

/// A separate, nonshipping app for visual and keyboard checks. Production UI
/// sources are compiled unchanged; only this in-memory store is test content.
@main
struct LibraryPreviewApp: App {
    @NSApplicationDelegateAdaptor(LibraryPreviewDelegate.self) private var delegate
    @ViewState private var store: DownloadStore
    @ViewState private var appearance: AppearanceStore
    private let size: CGSize

    init() {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "io.harbor.downloads.designpreview",
              let supportPath = environment["HARBOR_SUPPORT_DIR"],
              supportPath.hasPrefix(NSTemporaryDirectory()),
              let fixturePath = environment["MVD_PREVIEW_FIXTURES"] else {
            fatalError("Use Tests/DesignPreview/run.sh to launch with isolated state.")
        }
        let appearance = AppearanceStore.shared
        switch environment["MVD_PREVIEW_THEME"] ?? "light" {
        case "dark": appearance.mode = .dark
        case "custom": appearance.mode = .custom
        case "system": appearance.mode = .system
        default: appearance.mode = .light
        }
        appearance.fontFamily = "System"
        appearance.fontSize = Double(environment["MVD_PREVIEW_FONT_SIZE"] ?? "13") ?? 13
        appearance.density = .comfortable
        _appearance = ViewState(wrappedValue: appearance)
        _store = ViewState(wrappedValue: LibraryPreviewFixtures.makeStore(supportPath: supportPath, fixturePath: fixturePath))
        size = CGSize(width: Double(environment["MVD_PREVIEW_WIDTH"] ?? "1440") ?? 1440,
                      height: Double(environment["MVD_PREVIEW_HEIGHT"] ?? "920") ?? 920)
    }

    var body: some Scene {
        WindowGroup("MVD — Design Preview", id: "main") {
            MainWindow(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .harborEnvironment(store: store, appearance: appearance)
        }
        .defaultSize(width: size.width, height: size.height)
        // The preview owns its test dimensions. The production scene's
        // contentMinSize policy otherwise replaces them with a restored or
        // freshly computed intrinsic minimum before narrow-layout checks.
        .windowResizability(.automatic)
        .windowToolbarStyle(.unified)
        .commands { HarborCommands(store: store) }

        Settings {
            HarborSettingsView(store: store)
                .harborEnvironment(store: store, appearance: appearance)
        }
    }
}

final class LibraryPreviewDelegate: NSObject, NSApplicationDelegate {
    private var appliedInitialSize = false
    private var mainWindowObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        // SwiftUI's defaultSize yields to the previous session's restored
        // frame. A visual test must instead honor its explicit launch size.
        mainWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak window] in
                guard let window else { return }
                self?.applyInitialSize(to: window)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let window = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first(where: { !($0 is NSPanel) && $0.sheetParent == nil }) else { return }
            self?.applyInitialSize(to: window)
        }
    }

    private func applyInitialSize(to window: NSWindow) {
        guard !appliedInitialSize, !(window is NSPanel), window.sheetParent == nil else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let widthText = environment["MVD_PREVIEW_WIDTH"], let width = Double(widthText), width.isFinite,
              let heightText = environment["MVD_PREVIEW_HEIGHT"], let height = Double(heightText), height.isFinite else { return }
        appliedInitialSize = true
        window.isRestorable = false
        window.setFrameAutosaveName("")
        let requested = NSSize(width: max(900, width), height: max(600, height))
        logWindow(window, phase: "before explicit sizing", requested: requested)
        setTestSize(requested, on: window)
        logWindow(window, phase: "initial after setContentSize", requested: requested)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak window] in
            guard let self, let window else { return }
            self.logWindow(window, phase: "after 0.5 seconds before final override", requested: requested)
            self.setTestSize(requested, on: window)
            self.logWindow(window, phase: "after 0.5 seconds after final override", requested: requested)
        }
        if let mainWindowObserver {
            NotificationCenter.default.removeObserver(mainWindowObserver)
            self.mainWindowObserver = nil
        }
    }

    private func setTestSize(_ requested: NSSize, on window: NSWindow) {
        let minimum = NSSize(width: 900, height: 600)
        window.contentMinSize = minimum
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        window.setContentSize(requested)
        window.center()
    }

    private func logWindow(_ window: NSWindow, phase: String, requested: NSSize) {
        let content = window.contentView
        let line = "DesignPreview [\(phase)] requested=\(NSStringFromSize(requested)) frame=\(NSStringFromRect(window.frame)) contentFrame=\(NSStringFromRect(content?.frame ?? .zero)) contentBounds=\(NSStringFromRect(content?.bounds ?? .zero)) fittingSize=\(NSStringFromSize(content?.fittingSize ?? .zero)) minSize=\(NSStringFromSize(window.minSize)) contentMinSize=\(NSStringFromSize(window.contentMinSize)) contentLayoutRect=\(NSStringFromRect(window.contentLayoutRect))\n"
        if let data = line.data(using: .utf8) { FileHandle.standardError.write(data) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private enum LibraryPreviewFixtures {
    static func makeStore(supportPath: String, fixturePath: String) -> DownloadStore {
        let store = DownloadStore()
        let publicPreview = ProcessInfo.processInfo.environment["MVD_PREVIEW_PUBLIC"] == "1"
        let root = URL(fileURLWithPath: supportPath).appendingPathComponent("Downloads")
        let films = DownloadFolder(id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!, name: "Films", path: root.appendingPathComponent("Films").path, icon: "film", colorHex: "9B6CE5")
        let nature = DownloadFolder(id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!, name: publicPreview ? "Clips" : "Nature", path: root.appendingPathComponent("Nature").path, icon: publicPreview ? "film" : "tree.fill", colorHex: "389D67")
        let audio = DownloadFolder(id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!, name: "Audio", path: root.appendingPathComponent("Audio").path, icon: "music.note", colorHex: "3688F4")
        for folder in [films, nature, audio] {
            try? FileManager.default.createDirectory(atPath: folder.path, withIntermediateDirectories: true)
        }
        let videoPath = URL(fileURLWithPath: films.path).appendingPathComponent("Big Buck Bunny.mp4").path
        let audioPath = URL(fileURLWithPath: audio.path).appendingPathComponent("Audio playback sample.mp3").path
        try? FileManager.default.copyItem(atPath: "\(fixturePath)/sample.mp4", toPath: videoPath)
        try? FileManager.default.copyItem(atPath: "\(fixturePath)/sample.mp3", toPath: audioPath)

        var completed = job(id: "20000000-0000-0000-0000-000000000001", title: "Big Buck Bunny — Blender open movie", source: "https://www.youtube.com/watch?v=aqz-KE-bpKQ", filename: "Big Buck Bunny.mp4", folder: films)
        completed.thumbnailURL = "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg"
        completed.status = .completed
        completed.outputPath = videoPath
        completed.bytesReceived = fileSize(videoPath)
        completed.totalBytes = completed.bytesReceived
        completed.completedAt = Date()
        completed.duration = 10
        completed.createdAt = Date().addingTimeInterval(-100)

        var downloading = job(id: "20000000-0000-0000-0000-000000000002", title: publicPreview ? "Big Buck Bunny - 1080p download" : "Planet Earth — Amazing nature scenery", source: publicPreview ? "https://www.youtube.com/watch?v=aqz-KE-bpKQ" : "https://www.youtube.com/watch?v=6v2L2UGZJAM", filename: "Big Buck Bunny download.mp4", folder: nature)
        downloading.thumbnailURL = publicPreview ? "https://i.ytimg.com/vi/aqz-KE-bpKQ/hqdefault.jpg" : "https://i.ytimg.com/vi/6v2L2UGZJAM/hqdefault.jpg"
        downloading.status = .downloading
        downloading.totalBytes = 3_400_000_000
        downloading.bytesReceived = 1_600_000_000
        downloading.bytesPerSecond = 18_400_000
        downloading.options?.accelerated = true
        downloading.createdAt = Date().addingTimeInterval(-200)

        var completedAudio = job(id: "20000000-0000-0000-0000-000000000003", title: "Audio playback sample", source: "https://www.w3schools.com/html/horse.mp3", filename: "Audio playback sample.mp3", folder: audio)
        completedAudio.status = .completed
        completedAudio.outputPath = audioPath
        completedAudio.bytesReceived = fileSize(audioPath)
        completedAudio.totalBytes = completedAudio.bytesReceived
        completedAudio.options = DownloadOptions(mode: .audioOnly, audioFormat: "mp3", audioBitrateKbps: 128)
        completedAudio.quality = nil
        completedAudio.completedAt = Date()
        completedAudio.duration = 3
        completedAudio.createdAt = Date().addingTimeInterval(-300)

        var paused = job(id: "20000000-0000-0000-0000-000000000004", title: "Tears of Steel — Blender VFX open movie", source: "https://www.youtube.com/watch?v=R6MlUcmOul8", filename: "Tears of Steel.mp4", folder: films)
        paused.thumbnailURL = "https://i.ytimg.com/vi/R6MlUcmOul8/hqdefault.jpg"
        paused.status = .paused
        paused.bytesReceived = 312_000_000
        paused.totalBytes = 892_000_000
        paused.createdAt = Date().addingTimeInterval(-400)

        let displayDestination = publicPreview ? NSHomeDirectory() + "/Downloads/MVD" : root.path
        store.settings = DownloadSettings(destinationDirectory: displayDestination)
        store.jobs = [completed, downloading, completedAudio, paused]
        store.folders = [films, nature, audio]
        store.libraryView = .list
        store.showsInspector = false
        store.connected = true
        store.connectionLabel = "Design preview — simulated transfer state"
        store.capabilities = [ToolCapability(id: "yt-dlp", name: "yt-dlp", available: true, detail: "Preview fixture"), ToolCapability(id: "ffmpeg", name: "FFmpeg", available: true, detail: "Preview fixture"), ToolCapability(id: "deno", name: "Deno", available: true, detail: "Preview fixture")]
        return store
    }

    private static func job(id: String, title: String, source: String, filename: String, folder: DownloadFolder) -> DownloadJob {
        var job = DownloadJob(id: UUID(uuidString: id)!, sourceURL: source, title: title, filename: filename, destinationDirectory: folder.path, kind: .media)
        job.folderID = folder.id
        job.quality = VideoQuality(id: "1080", label: "1080p", height: 1080)
        job.options = DownloadOptions(container: "mp4")
        return job
    }

    private static func fileSize(_ path: String) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}
