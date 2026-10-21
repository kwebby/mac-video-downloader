import AppKit
import HarborCore
import SwiftUI

@main
struct HarborApp: App {
    @NSApplicationDelegateAdaptor(HarborAppDelegate.self) private var delegate
    @ViewState private var store = DownloadStore()
    @ViewState private var appearance = AppearanceStore.shared

    var body: some Scene {
        WindowGroup("MVD", id: "main") {
            MainWindow(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .task { store.start() }
                .onOpenURL { url in
                    store.handleIncomingURL(url)
                    HarborAppDelegate.bringLibraryForward()
                }
                .harborEnvironment(store: store, appearance: appearance)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .handlesExternalEvents(matching: ["*"])
        .commands { HarborCommands(store: store) }

        Settings {
            HarborSettingsView(store: store)
                .harborEnvironment(store: store, appearance: appearance)
        }

        MenuBarExtra {
            HarborMenuBar(store: store)
                .task { store.start() }
                .harborEnvironment(store: store, appearance: appearance)
        } label: {
            Image(systemName: store.activeJobs.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
                .accessibilityLabel("MVD, \(store.activeJobs.count) active downloads")
        }
    }
}

final class HarborAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !Self.bringLibraryForward(sender)
    }

    /// URL delivery can bypass the normal Dock/reopen event. Restore the
    /// existing library explicitly so a confirmed browser handoff is visible
    /// even when its window was minimized or behind another application.
    @MainActor @discardableResult
    static func bringLibraryForward(_ application: NSApplication = .shared) -> Bool {
        application.activate(ignoringOtherApps: true)
        if let library = application.windows.first(where: { $0.title == "MVD" || $0.identifier?.rawValue.hasPrefix("main-AppWindow") == true }) {
            if library.isMiniaturized { library.deminiaturize(nil) }
            library.makeKeyAndOrderFront(nil)
            return true
        }
        return false
    }
}

struct HarborCommands: Commands {
    let store: DownloadStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Download…") { show(.addURL) }.keyboardShortcut("n")
            Button("Bulk URLs…") { show(.bulkURLs) }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Paste and Download") {
                openWindow(id: "main")
                store.pasteAndDownload()
            }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Fetch Links from Page…") { show(.fetchPage) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("New Folder Shortcut…") { store.folderToEdit = nil; show(.folderEditor) }
        }
        CommandMenu("Downloads") {
            Button("Edit Download Options…") {
                if let job = store.selectedJobs.first { openWindow(id: "main"); store.editOptions(for: job) }
            }.keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(store.selectedJobs.count != 1 || store.selectedJobs.first?.status == .processing)
            Divider()
            Button("Pause Selected") { Task { await store.perform(.pause, jobs: store.selectedJobs.filter(\.canPause)) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!store.selectedJobs.contains(where: \.canPause))
            Button("Resume Selected") { Task { await store.perform(.resume, jobs: store.selectedJobs.filter(\.canResume)) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!store.selectedJobs.contains(where: \.canResume))
            Button("Cancel Selected") { Task { await store.perform(.cancel, jobs: store.selectedJobs.filter(\.canCancel)) } }
                .disabled(!store.selectedJobs.contains(where: \.canCancel))
            Divider()
            Button(store.selectedJobs.first?.isAudio == true ? "Play Audio" : "Play Video") {
                if let job = store.selectedJobs.first { store.play(job) }
            }.keyboardShortcut("o", modifiers: [.command])
                .disabled(store.selectedJobs.count != 1 || store.selectedJobs.first?.canPlay != true || !store.openingPlaybackIDs.isDisjoint(with: store.selection))
            Button("Show in Finder") {
                if let job = store.selectedJobs.first { store.reveal(job) }
            }.keyboardShortcut("r", modifiers: [.command])
                .disabled(store.selectedJobs.count != 1 || store.selectedJobs.first?.outputPath == nil)
            Button("Remove Selected from List") { Task { await store.perform(.remove, jobs: store.selectedJobs.filter(\.canRemove)) } }
                .disabled(!store.selectedJobs.contains(where: \.canRemove))
        }
        CommandGroup(after: .sidebar) {
            Button("Search Downloads") {
                openWindow(id: "main")
                NotificationCenter.default.post(name: .mvdFocusSearch, object: nil)
            }.keyboardShortcut("f")
            Divider()
            Button("View as Grid") { store.libraryView = .grid }
                .keyboardShortcut("1", modifiers: [.command])
            Button("View as List") { store.libraryView = .list }
                .keyboardShortcut("2", modifiers: [.command])
            Divider()
            Button(store.showsInspector ? "Hide Inspector" : "Show Inspector") { store.showsInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private func show(_ sheet: HarborSheet) {
        openWindow(id: "main")
        store.sheet = sheet
    }
}

struct HarborMenuBar: View {
    let store: DownloadStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("MVD · Mac Video Downloader").harborFont(.headline)
        Text(store.connected ? "\(store.activeJobs.count) active · \(Format.speed(store.totalSpeed))" : store.connectionLabel)
        Divider()
        if !store.activeJobs.isEmpty {
            ForEach(Array(store.activeJobs.prefix(5))) { job in
                Text("\(job.displayTitle) — \(job.status.label)")
            }
            Divider()
        }
        Button("Show Downloads") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("New Download…") {
            openWindow(id: "main")
            NSApplication.shared.activate(ignoringOtherApps: true)
            store.sheet = .addURL
        }
        Button("Pause All") { Task { await store.perform(.pause, jobs: store.jobs.filter(\.canPause)) } }
            .disabled(!store.jobs.contains(where: \.canPause))
        Divider()
        Button("Quit MVD") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        Text("Accepted downloads continue in the background.").harborFont(.caption)
    }
}
