import AppKit
import HarborCore
import SwiftUI

/// Quiet Library navigation. The center scrolls independently so setup and
/// preferences stay within reach in a short window or a large library.
struct LibrarySidebar: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openURL) private var openURL
    @ViewState private var folderPendingRemoval: DownloadFolder?
    @ViewState private var showsChromeSetup = false
    @ViewState private var chromeSetup = ChromeCompanionSetup.shared

    private let primaryFilters: [DownloadFilter] = [.all, .active, .completed]
    private let additionalFilters: [DownloadFilter] = [.queued, .paused, .failed]

    var body: some View {
        VStack(spacing: 0) {
            brand
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(primaryFilters) { filter in navigationRow(filter) }

                    ForEach(additionalFilters.filter { store.count($0) > 0 || isSelected($0) }) { filter in
                        navigationRow(filter)
                    }

                    Menu {
                        ForEach(additionalFilters) { filter in
                            Button {
                                select(filter)
                            } label: {
                                Label("\(filter.title) (\(store.count(filter)))", systemImage: filter.symbol)
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "line.3.horizontal.decrease")
                                .frame(width: 22)
                            Text("More statuses")
                            Spacer(minLength: 0)
                        }
                        .harborFont(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .frame(minHeight: 30)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Show queued, paused, or failed downloads")
                    .padding(.top, 3)

                    Rectangle()
                        .fill(appearance.separatorColor)
                        .frame(height: 1)
                        .padding(.horizontal, 9)
                        .padding(.top, 15)
                        .padding(.bottom, 14)

                    folderHeader

                    if store.folders.isEmpty {
                        Text("No folder shortcuts yet")
                            .harborFont(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                        LibrarySidebarButton(action: createFolder) {
                            Label("New Folder…", systemImage: "folder.badge.plus")
                                .harborFont(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        ForEach(store.folders) { folder in folderRow(folder) }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(appearance.sidebarColor)
        .overlay(alignment: .trailing) {
            Rectangle().fill(appearance.separatorColor).frame(width: 1)
        }
        .confirmationDialog("Remove folder shortcut?", isPresented: Binding(get: {
            folderPendingRemoval != nil
        }, set: {
            if !$0 { folderPendingRemoval = nil }
        }), titleVisibility: .visible) {
            Button("Remove Shortcut", role: .destructive) {
                if let folder = folderPendingRemoval { Task { await store.removeFolder(folder) } }
                folderPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { folderPendingRemoval = nil }
        } message: {
            Text("Saved files and folders on disk are kept. Existing downloads retain their save locations.")
        }
        .sheet(isPresented: $showsChromeSetup) {
            ChromeCompanionSetupView(showsDoneButton: true)
                .frame(width: 660, height: min(680, max(500, (NSScreen.main?.visibleFrame.height ?? 850) - 160)))
                .sheetCloseButton()
                .harborEnvironment(store: store, appearance: appearance)
        }
    }

    private var brand: some View {
        HStack(spacing: 10) {
            MVDMark(size: 46)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("MVD")
                    .font(brandFont)
                Text("Mac Video Downloader")
                    .harborFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 52)
        .padding(.bottom, 26)
        .accessibilityElement(children: .combine)
    }

    private var brandFont: Font {
        let size = appearance.fontSize + 8
        if appearance.fontFamily != "System",
           let native = NSFontManager.shared.font(withFamily: appearance.fontFamily, traits: [], weight: 9, size: size) {
            return Font(native).weight(.bold)
        }
        return .system(size: size, weight: .bold)
    }

    private func navigationRow(_ filter: DownloadFilter) -> some View {
        let selected = isSelected(filter)
        let title = filter == .all ? "Downloads" : filter.title
        return LibrarySidebarButton(selected: selected, action: { select(filter) }) {
            HStack(spacing: 12) {
                Image(systemName: navigationSymbol(filter))
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(selected ? appearance.tintColor : Color.primary.opacity(0.85))
                    .frame(width: 22)
                    .accessibilityHidden(true)
                Text(title)
                    .harborFont(.body, weight: selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 3)
                countBadge(store.count(filter), selected: selected)
            }
        }
        .help("\(title): \(store.count(filter)) downloads")
        .accessibilityLabel("\(title), \(store.count(filter)) downloads")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var folderHeader: some View {
        HStack {
            Text("Folders")
                .harborFont(.callout, weight: .medium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Button(action: createFolder) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New folder shortcut")
            .accessibilityLabel("New folder shortcut")
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.bottom, 3)
    }

    private func folderRow(_ folder: DownloadFolder) -> some View {
        let selected = store.selectedFolderID == folder.id
        let count = store.jobs.filter { $0.folderID == folder.id }.count
        return LibrarySidebarButton(selected: selected, action: {
            store.filter = .all
            store.selectedFolderID = folder.id
        }) {
            HStack(spacing: 12) {
                Image(systemName: folder.icon)
                    .font(.system(size: 19))
                    .foregroundStyle(folder.displayColor)
                    .frame(width: 22)
                Text(folder.name)
                    .harborFont(.body, weight: selected ? .medium : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 3)
                countBadge(count, selected: selected)
            }
        }
        .help("\(folder.name) · \(Format.folder(folder.path))")
        .accessibilityLabel("\(folder.name), \(count) downloads")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .contextMenu {
            Button("Edit Folder…", systemImage: "pencil") {
                store.folderToEdit = folder
                store.sheet = .folderEditor
            }
            Button("Open Folder", systemImage: "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: folder.path))
            }
            Divider()
            Button("Remove Shortcut…", systemImage: "minus.circle", role: .destructive) {
                folderPendingRemoval = folder
            }
        }
    }

    private func countBadge(_ count: Int, selected: Bool) -> some View {
        Text("\(count)")
            .harborFont(.caption, monospacedDigits: true)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 24)
            .background(selected ? appearance.tintColor.opacity(0.09) : appearance.hoverColor, in: RoundedRectangle(cornerRadius: 9))
            .accessibilityHidden(true)
    }

    private var footer: some View {
        VStack(spacing: 3) {
            LibrarySidebarButton(bordered: true, action: { showsChromeSetup = true }) {
                HStack(spacing: 10) {
                    ChromeCompanionIcon(size: 21)
                        .frame(width: 22)
                    Text("Connect Chrome")
                        .harborFont(.callout, weight: .medium)
                        .lineLimit(1)
                    Spacer(minLength: 1)
                    Image(systemName: chromeSetup.isConfigured ? "checkmark.circle.fill" : "chevron.right")
                        .font(.system(size: chromeSetup.isConfigured ? 16 : 10, weight: .medium))
                        .foregroundStyle(chromeSetup.isConfigured ? appearance.tintColor : Color.secondary)
                }
            }
            .help(chromeSetup.statusDetail)
            .accessibilityLabel(chromeSetup.isConfigured ? "Chrome installed and configured. Open companion setup." : "Connect Chrome. \(chromeSetup.statusTitle).")
            .padding(.bottom, 7)

            footerButton("Settings", symbol: "gearshape", action: { openSettings() })
                .help("Download location, proxy, media tools, and appearance")
            footerButton("Hire Us", symbol: "heart", external: true, action: { openURL(MVDLinks.hireUs) })
                .help("Open Kwebby services in your browser")
            footerButton("Donate", symbol: "gift", external: true, action: { openURL(MVDLinks.donate) })
                .help("Support MVD")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }

    private func footerButton(_ title: String, symbol: String, external: Bool = false, action: @escaping () -> Void) -> some View {
        LibrarySidebarButton(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .frame(width: 22)
                Text(title)
                    .harborFont(.body)
                    .lineLimit(1)
                Spacer(minLength: 1)
                if external {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func isSelected(_ filter: DownloadFilter) -> Bool {
        store.selectedFolderID == nil && store.filter == filter
    }

    private func select(_ filter: DownloadFilter) {
        store.filter = filter
        store.selectedFolderID = nil
    }

    private func createFolder() {
        store.folderToEdit = nil
        store.sheet = .folderEditor
    }

    private func navigationSymbol(_ filter: DownloadFilter) -> String {
        switch filter {
        case .all: "square.and.arrow.down"
        case .active: "clock"
        default: filter.symbol
        }
    }
}

/// A real keyboard-focusable button with quiet feedback in both color schemes.
private struct LibrarySidebarButton<Content: View>: View {
    @AppAppearance private var appearance
    @ViewState private var hovered = false
    @FocusState private var focused: Bool
    let selected: Bool
    let bordered: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool = false, bordered: Bool = false, action: @escaping () -> Void, @ViewBuilder label: () -> Content) {
        self.selected = selected
        self.bordered = bordered
        self.action = action
        content = label()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 13)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .background(background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(focused ? appearance.tintColor : (bordered ? appearance.separatorColor : .clear), lineWidth: focused ? 2 : 1)
                }
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hovered = $0 }
    }

    private var background: Color {
        if selected { return appearance.selectionColor }
        if hovered { return appearance.hoverColor }
        return .clear
    }
}
