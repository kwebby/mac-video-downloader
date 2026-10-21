import AppKit
import HarborCore
import SwiftUI

struct LibraryHeader: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance
    @ViewState private var url = ""
    @ViewState private var validationError: String?
    @FocusState private var focusesURL: Bool
    @FocusState private var focusesSearch: Bool
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { heading; Spacer(minLength: 12); DownloadSortMenu(store: store); search.frame(width: 230); utilityButtons }
                VStack(alignment: .leading, spacing: 15) {
                    HStack { heading; Spacer(minLength: 6); DownloadSortMenu(store: store); utilityButtons }
                    search
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField("Paste a video or file URL…", text: $url)
                            .textFieldStyle(.plain).harborFont(.body)
                            .focused($focusesURL).onSubmit(review)
                            .accessibilityLabel("Download URL").accessibilityIdentifier("downloadURLField")
                        Button(action: paste) { Image(systemName: "doc.on.clipboard") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("Paste a URL, or several links for bulk review")
                            .accessibilityLabel("Paste URL")
                    }
                    .padding(.horizontal, 15).frame(height: 50)
                    .background(appearance.fieldColor, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(focusesURL ? appearance.tintColor : appearance.separatorColor, lineWidth: focusesURL ? 1.5 : 1) }
                    Button(action: review) {
                        Label("Review link", systemImage: "arrow.down.to.line")
                            .harborFont(.body, weight: .semibold)
                            .foregroundStyle(appearance.onTintColor)
                            .padding(.horizontal, 18).frame(height: 50)
                            .background(appearance.tintColor, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain).disabled(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.58 : 1)
                    .accessibilityIdentifier("startDownloadButton")
                }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.circle")
                        .harborFont(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 20) {
                Button("Bulk URLs", systemImage: "plus.circle") { store.sheet = .bulkURLs }
                    .help("Review several links at once (⇧⌘N)")
                Button("Fetch page", systemImage: "link.badge.plus") { store.sheet = .fetchPage }
                    .help("Find downloadable links on a webpage (⇧⌘F)")
                Spacer(minLength: 4)
                if !store.missingTools.isEmpty {
                    Button("Check media tools", systemImage: "exclamationmark.circle") { appearance.settingsTab = .mediaTools; openSettings() }
                        .foregroundStyle(.orange)
                }
            }
            .buttonStyle(.plain).harborFont(.callout).foregroundStyle(appearance.tintColor)
        }
        .onChange(of: url) { _, _ in validationError = nil }
        .background(WindowDragSurface())
        .onReceive(NotificationCenter.default.publisher(for: .mvdFocusSearch)) { _ in focusesSearch = true }
    }

    private var heading: some View {
        Text(store.selectedFolderID != nil ? store.libraryTitle : "Downloads")
            .harborFont(.largeTitle, weight: .bold)
            .lineLimit(1).truncationMode(.tail)
            .frame(minWidth: 140, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search downloads…", text: $store.search)
                .textFieldStyle(.plain).harborFont(.callout).focused($focusesSearch)
                .accessibilityLabel("Search downloads")
            if !store.search.isEmpty {
                Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11).frame(height: 38)
        .background(appearance.fieldColor, in: RoundedRectangle(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(focusesSearch ? appearance.tintColor : appearance.separatorColor) }
    }
    private var utilityButtons: some View {
        HStack(spacing: 9) {
            AppearanceMenu()
            Button { store.showsInspector.toggle() } label: { Image(systemName: "sidebar.right").frame(width: 22, height: 25) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Download details (⌥⌘I)")
                .accessibilityLabel(store.showsInspector ? "Hide download details" : "Show download details")
        }
    }
    private func review() {
        guard DownloadStore.normalizedURL(url) != nil else { validationError = DownloadStore.urlEntryHint; return }
        store.openPastedURLs(url)
    }
    private func paste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { focusesURL = true; return }
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if lines.count > 1 { store.openPastedURLs(text) }
        else { url = text.trimmingCharacters(in: .whitespacesAndNewlines); focusesURL = true }
    }
}

extension Notification.Name { static let mvdFocusSearch = Notification.Name("MVD.focusSearch") }

/// Blank space in the custom header remains a native window-dragging region.
private struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView { override var mouseDownCanMoveWindow: Bool { true } }
}

struct LibraryStatusBar: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    private var folder: DownloadFolder? { store.folders.first { $0.id == store.selectedFolderID } }
    private var destination: String { folder?.path ?? store.settings.destinationDirectory }

    var body: some View {
        HStack(spacing: 15) {
            HStack(spacing: 7) {
                Image(systemName: store.connected ? "speedometer" : "exclamationmark.circle")
                Text(store.totalSpeed > 0 ? Format.speed(store.totalSpeed) : store.connected ? "Ready" : "Offline")
                    .monospacedDigit()
            }
            .foregroundStyle(store.connected ? appearance.tintColor : .orange)
            Rectangle().fill(appearance.separatorColor).frame(width: 1, height: 17)
            Menu {
                Button("Default: \(Format.folder(store.settings.destinationDirectory))") { store.selectedFolderID = nil; store.filter = .all }
                ForEach(store.folders) { folder in
                    Button(folder.name, systemImage: folder.icon) { store.selectedFolderID = folder.id; store.filter = .all }
                }
                Divider()
                Button("Change default folder…") { chooseDestination() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: folder?.icon ?? "folder")
                    Text("Save to: \(Format.folder(destination))").lineLimit(1).truncationMode(.middle)
                        .layoutPriority(-1)
                    Image(systemName: "chevron.down").imageScale(.small)
                }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .help("New downloads in this view save to \(destination)")
            Spacer(minLength: 8)
            Text(store.visibleJobs.count == 1 ? "1 item" : "\(store.visibleJobs.count) items").fixedSize()
        }
        .harborFont(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 17)
        .overlay(alignment: .top) { Rectangle().fill(appearance.separatorColor).frame(height: 1) }
    }
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.title = "Default Download Folder"; panel.prompt = "Choose"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: store.settings.destinationDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            var settings = store.settings; settings.destinationDirectory = url.path
            Task { if await store.saveSettings(settings) { store.selectedFolderID = nil } }
        }
    }
}
