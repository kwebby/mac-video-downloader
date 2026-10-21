import Foundation
import HarborCore
import SwiftUI

enum DownloadLibraryView: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var title: String { self == .list ? "List" : "Grid" }
    var symbol: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum MVDLinks {
    static let hireUs = URL(string: "https://kwebby.com/services")!
    static let donate = URL(string: "https://checkout.dodopayments.com/buy/pdt_0NqDCEkv5kQm3ei5prGCE?quantity=1")!
}

struct DownloadViewBar: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance

    var body: some View {
        HStack(spacing: 12) {
            Picker("Filter downloads", selection: $store.filter) {
                Text("All (\(count(.all)))").tag(DownloadFilter.all)
                Text("Active (\(count(.active)))").tag(DownloadFilter.active)
                if store.filter != .all && store.filter != .active {
                    Text("\(store.filter.title) (\(count(store.filter)))").tag(store.filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help(store.selectedFolderID == nil ? "Show all or active downloads" : "Show all or active downloads in this folder")
            .accessibilityIdentifier("downloadFilterPicker")
            Spacer(minLength: 12)
            Picker("Download view", selection: $store.libraryView) {
                ForEach(DownloadLibraryView.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .frame(width: 86)
            .help("List (⌘2) or Grid (⌘1)")
            .accessibilityIdentifier("downloadViewPicker")
        }
        .controlSize(.regular)
        .harborFont(.callout)
        .padding(.vertical, 12)
        .background(appearance.backgroundColor)
        .overlay(alignment: .bottom) {
            Rectangle().fill(appearance.separatorColor).frame(height: 1)
        }
    }

    private func count(_ filter: DownloadFilter) -> Int {
        store.jobs.filter { job in
            filter.includes(job)
                && (store.selectedFolderID == nil || job.folderID == store.selectedFolderID)
                && (store.search.isEmpty || "\(job.displayTitle) \(job.sourceURL) \(job.status.label)".localizedStandardContains(store.search))
        }.count
    }
}

/// Reused in the library heading so ordering stays alongside search.
struct DownloadSortMenu: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance

    private var selectedChoice: DownloadSortChoice? {
        DownloadSortChoice.allCases.first { store.sortOrder == $0.comparators }
    }

    var body: some View {
        Menu {
            ForEach(DownloadSortChoice.allCases) { choice in
                Button {
                    store.sortOrder = choice.comparators
                } label: {
                    if choice == selectedChoice {
                        Label(choice.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(choice.menuTitle)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                Text("Sort: \(selectedChoice?.title ?? "Custom")")
                Image(systemName: "chevron.down").imageScale(.small)
            }
            .foregroundStyle(appearance.mutedTextColor)
            .harborFont(.callout)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort downloads in either view")
        .accessibilityIdentifier("downloadSortMenu")
    }
}

private enum DownloadSortChoice: String, CaseIterable, Identifiable {
    case newest, oldest, name, largest, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        case .largest: "Largest"
        case .status: "Status"
        }
    }
    var menuTitle: String {
        switch self {
        case .newest: "Newest First"
        case .oldest: "Oldest First"
        case .name: "Name"
        case .largest: "Largest First"
        case .status: "Status"
        }
    }
    var comparators: [KeyPathComparator<DownloadJob>] {
        switch self {
        case .newest: [KeyPathComparator(\DownloadJob.createdAt, order: .reverse)]
        case .oldest: [KeyPathComparator(\DownloadJob.createdAt)]
        case .name: [KeyPathComparator(\DownloadJob.displayTitle)]
        case .largest: [KeyPathComparator(\DownloadJob.bytesReceived, order: .reverse)]
        case .status: [KeyPathComparator(\DownloadJob.status.rawValue)]
        }
    }
}
