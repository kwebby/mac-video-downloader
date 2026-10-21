import AppKit
import HarborCore
import SwiftUI

/// The library keeps downloads on one shared surface, with details collapsing
/// into each item when there is not room for the desktop columns.
struct QuietLibraryList: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance
    @FocusState private var isFocused: Bool
    @ViewState private var selectionAnchor: UUID?
    @ViewState private var keyboardItem: UUID?

    var body: some View {
        GeometryReader { geometry in
            let layout = QuietLibraryLayout(width: geometry.size.width, fontSize: appearance.fontSize)
            VStack(spacing: 0) {
                columnHeadings(layout: layout)
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.visibleJobs) { job in
                                QuietLibraryRow(store: store, job: job, layout: layout) {
                                    select(job.id, modifiers: NSEvent.modifierFlags)
                                }
                                .id(job.id)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($isFocused)
                    .onKeyPress(keys: [.upArrow], phases: .down) { press in
                        moveSelection(by: -1, extending: press.modifiers.contains(.shift), scroll: scroll)
                        return .handled
                    }
                    .onKeyPress(keys: [.downArrow], phases: .down) { press in
                        moveSelection(by: 1, extending: press.modifiers.contains(.shift), scroll: scroll)
                        return .handled
                    }
                    .onKeyPress(.return) {
                        guard !store.selection.isEmpty else { return .ignored }
                        store.primaryAction(store.selection)
                        return .handled
                    }
                    .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        store.selection = Set(store.visibleJobs.map(\.id))
                        return .handled
                    }
                    .overlay {
                        if store.visibleJobs.isEmpty { emptyState }
                    }
                    .overlay(alignment: .top) {
                        if isFocused {
                            Rectangle().fill(appearance.tintColor.opacity(0.7)).frame(height: 2)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .background(appearance.surfaceColor)
            .onChange(of: store.visibleJobs.map(\.id)) { _, ids in
                if let selectionAnchor, !ids.contains(selectionAnchor) { self.selectionAnchor = nil }
                if let keyboardItem, !ids.contains(keyboardItem) { self.keyboardItem = nil }
            }
        }
        .accessibilityIdentifier("quietLibraryList")
    }

    private func columnHeadings(layout: QuietLibraryLayout) -> some View {
        HStack(spacing: layout.spacing) {
            Text("Item").frame(maxWidth: .infinity, alignment: .leading)
            if layout.showsFormat { Text("Format").frame(width: layout.formatWidth, alignment: .leading) }
            if layout.showsFolder { Text("Folder").frame(width: layout.folderWidth, alignment: .leading) }
            if layout.showsSize { Text("Size").frame(width: layout.sizeWidth, alignment: .leading) }
            if !layout.stacksStatus { Text("Status").frame(width: layout.statusWidth, alignment: .leading) }
            Color.clear.frame(width: layout.actionWidth, height: 1).accessibilityHidden(true)
        }
        .harborFont(.caption)
        .foregroundStyle(appearance.mutedTextColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(appearance.separatorColor).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(appearance.separatorColor).frame(height: 1) }
        .padding(.horizontal, 0)
        .accessibilityHidden(true)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: store.search.isEmpty ? (store.selectedFolderID == nil ? store.filter.symbol : "folder") : "magnifyingglass")
        } description: {
            Text(emptyDescription)
        } actions: {
            if !store.search.isEmpty {
                Button("Clear Search") { store.search = "" }
            } else if store.selectedFolderID != nil || store.jobs.isEmpty {
                Button("Add URL…") { store.sheet = .addURL }
            } else {
                Button("Show All Downloads") { store.filter = .all }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.surfaceColor)
    }

    private var emptyTitle: String {
        store.search.isEmpty ? "No downloads in \(store.libraryTitle)" : "No matching downloads"
    }

    private var emptyDescription: String {
        if !store.search.isEmpty { return "Try a different title, source, or status." }
        if store.selectedFolderID != nil { return "Paste a link to save your first download in this folder." }
        if store.jobs.isEmpty { return "Paste a video page or file link above to start your library." }
        return "Downloads will appear here when their status changes."
    }

    private func select(_ id: UUID, modifiers: NSEvent.ModifierFlags) {
        isFocused = true
        let ids = store.visibleJobs.map(\.id)
        if modifiers.contains(.shift), let anchor = selectionAnchor ?? keyboardItem ?? ids.first(where: { store.selection.contains($0) }),
           let start = ids.firstIndex(of: anchor), let end = ids.firstIndex(of: id) {
            let range = Set(ids[min(start, end)...max(start, end)])
            if modifiers.contains(.command) { store.selection.formUnion(range) }
            else { store.selection = range }
        } else if modifiers.contains(.command) {
            if !store.selection.insert(id).inserted { store.selection.remove(id) }
            selectionAnchor = id
        } else {
            store.selection = [id]
            selectionAnchor = id
        }
        keyboardItem = id
    }

    private func moveSelection(by offset: Int, extending: Bool, scroll: ScrollViewProxy) {
        let ids = store.visibleJobs.map(\.id)
        guard !ids.isEmpty else { return }
        let selected = keyboardItem.flatMap { ids.firstIndex(of: $0) }
            ?? ids.firstIndex(where: { store.selection.contains($0) })
        let next = selected.map { min(ids.count - 1, max(0, $0 + offset)) } ?? (offset > 0 ? 0 : ids.count - 1)
        let id = ids[next]
        if extending, let anchor = selectionAnchor ?? keyboardItem ?? selected.map({ ids[$0] }), let start = ids.firstIndex(of: anchor) {
            selectionAnchor = anchor
            store.selection = Set(ids[min(start, next)...max(start, next)])
        } else {
            store.selection = [id]
            selectionAnchor = id
        }
        keyboardItem = id
        scroll.scrollTo(id)
    }
}

private struct QuietLibraryLayout {
    let width: CGFloat
    let fontSize: Double
    var stacksStatus: Bool { width <= 650 }
    var showsFolder: Bool { width >= 1_080 && fontSize <= 15 }
    var showsFormat: Bool { width >= (fontSize > 15 ? 1_050 : 850) }
    var showsSize: Bool { showsFormat }
    var spacing: CGFloat { width >= 850 ? 16 : 12 }
    var formatWidth: CGFloat { 70 }
    var folderWidth: CGFloat { 112 }
    var sizeWidth: CGFloat { 76 }
    var statusWidth: CGFloat { width >= 1_080 ? 218 : width >= 850 ? 180 : fontSize > 15 ? 172 : 158 }
    var actionWidth: CGFloat { 76 }
    var thumbnailWidth: CGFloat { width >= 1_080 ? 116 : width >= 850 ? 102 : stacksStatus ? 76 : 88 }
    var thumbnailHeight: CGFloat { width >= 1_080 ? 72 : width >= 850 ? 68 : stacksStatus ? 52 : 60 }
}

private struct QuietLibraryRow: View {
    @Bindable var store: DownloadStore
    let job: DownloadJob
    let layout: QuietLibraryLayout
    let onSelect: () -> Void
    @AppAppearance private var appearance
    @ViewState private var hovered = false

    private var isSelected: Bool { store.selection.contains(job.id) }
    private var pending: Bool { store.pendingJobIDs.contains(job.id) }
    private var contextSelection: Set<UUID> { isSelected ? store.selection : [job.id] }
    private var folder: DownloadFolder? { store.folders.first { $0.id == job.folderID } }

    var body: some View {
        HStack(alignment: layout.stacksStatus ? .top : .center, spacing: layout.spacing) {
            item.frame(maxWidth: .infinity, alignment: .leading)
            if layout.showsFormat { formatDetails.frame(width: layout.formatWidth, alignment: .leading) }
            if layout.showsFolder { folderDetails.frame(width: layout.folderWidth, alignment: .leading) }
            if layout.showsSize {
                Text(totalSize).harborFont(.callout, monospacedDigits: true)
                    .foregroundStyle(appearance.mutedTextColor)
                    .lineLimit(2)
                    .frame(width: layout.sizeWidth, alignment: .leading)
                    .help(job.sizeLabel)
            }
            if !layout.stacksStatus {
                QuietLibraryStatus(job: job, compact: !layout.showsFormat)
                    .frame(width: layout.statusWidth, alignment: .leading)
            }
            actions.frame(width: layout.actionWidth)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, appearance.density == .compact ? 12 : 17)
        .background {
            // A separate hit target behind the controls prevents Play, menus,
            // and transfer actions from also selecting or opening the row.
            RoundedRectangle(cornerRadius: 9)
                .fill(rowColor)
                .contentShape(RoundedRectangle(cornerRadius: 9))
                .onTapGesture(count: 2) { store.primaryAction([job.id]) }
                .onTapGesture(perform: onSelect)
        }
        .overlay(alignment: .bottom) {
            if !isSelected && !job.status.isActive {
                Rectangle().fill(appearance.separatorColor).frame(height: 1)
                    .padding(.horizontal, 14).allowsHitTesting(false)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 9).strokeBorder(appearance.tintColor.opacity(0.55), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onHover { hovered = $0 }
        .contextMenu { DownloadContextMenu(store: store, ids: contextSelection) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("downloadRow-\(job.id.uuidString)")
    }

    private var rowColor: Color {
        if isSelected { return appearance.selectionColor }
        if hovered { return appearance.hoverColor }
        if job.status.isActive { return appearance.tintColor.opacity(0.045) }
        return .clear
    }

    private var item: some View {
        HStack(alignment: layout.stacksStatus ? .top : .center, spacing: 13) {
            artwork
            VStack(alignment: .leading, spacing: 11) {
                itemDetailsButton
                if layout.stacksStatus {
                    QuietLibraryStatus(job: job, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var itemDetailsButton: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(job.displayTitle)
                        .harborFont(.headline, weight: .medium)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .help(job.displayTitle)
                    HStack(spacing: 5) {
                        Image(systemName: "link").font(.system(size: 10)).accessibilityHidden(true)
                        Text(job.sourceHost).lineLimit(1).truncationMode(.middle)
                        if job.options?.accelerated == true {
                            Image(systemName: "bolt.fill").foregroundStyle(appearance.tintColor).help("Acceleration enabled")
                        }
                    }
                    .harborFont(.caption)
                    .foregroundStyle(appearance.mutedTextColor)
                    if !layout.showsFormat { compactMetadata }
                    else if !layout.showsFolder {
                        folderDetails.harborFont(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .simultaneousGesture(TapGesture(count: 2).onEnded { store.primaryAction([job.id]) })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(job.displayTitle)
            .accessibilityValue("\(job.sourceHost), \(job.status.label), \(job.sizeLabel)")
            .accessibilityHint("Select download. Press Return to play or inspect it.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { onSelect() }
            .accessibilityAction(named: Text("Play or inspect download")) { store.primaryAction([job.id]) }
    }

    @ViewBuilder private var artwork: some View {
        if job.canPlay {
            playableArtwork
        } else {
            playableArtwork
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onTapGesture(count: 2) { store.primaryAction([job.id]) }
                .onTapGesture(perform: onSelect)
        }
    }

    private var playableArtwork: some View {
        PlayableDownloadArtwork(job: job, width: layout.thumbnailWidth, height: layout.thumbnailHeight,
                                proxyURL: store.settings.proxyURL,
                                isOpening: store.openingPlaybackIDs.contains(job.id)) {
            store.play(job)
        }
    }

    private var compactMetadata: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(formatLabel)
                if let qualityLabel { Text("·"); Text(qualityLabel) }
                if totalSize != "—" { Text("·"); Text(totalSize) }
            }
            .harborFont(.caption, monospacedDigits: true)
            .foregroundStyle(appearance.mutedTextColor)
            .lineLimit(1)
            folderDetails.harborFont(.caption)
        }
    }

    private var formatDetails: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(formatLabel).harborFont(.callout).lineLimit(1)
            if let qualityLabel {
                Text(qualityLabel)
                    .harborFont(.caption, monospacedDigits: true)
                    .foregroundStyle(appearance.mutedTextColor)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(appearance.fieldColor, in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
            }
            if job.options?.mode == .videoOnly {
                Text("No audio").harborFont(.caption).foregroundStyle(appearance.mutedTextColor).lineLimit(1)
            }
        }
    }

    private var folderDetails: some View {
        HStack(spacing: 6) {
            Image(systemName: folder?.icon ?? "folder")
                .foregroundStyle(folder?.displayColor ?? appearance.mutedTextColor)
            Text(folder?.name ?? URL(fileURLWithPath: job.destinationDirectory).lastPathComponent)
                .foregroundStyle(appearance.mutedTextColor)
                .lineLimit(1).truncationMode(.middle)
        }
        .harborFont(.callout)
        .help(Format.folder(job.destinationDirectory))
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if job.canPause {
                rowAction("Pause download", symbol: "pause.fill") { Task { await store.perform(.pause, jobs: [job]) } }
                    .disabled(pending)
            } else if job.canResume {
                rowAction(job.status == .paused ? "Resume download" : "Retry download", symbol: job.status == .paused ? "play.fill" : "arrow.clockwise") {
                    Task { await store.perform(.resume, jobs: [job]) }
                }
                .disabled(pending)
            } else if job.status == .completed {
                rowAction("Show in Finder", symbol: "folder") { store.reveal(job) }.disabled(job.outputPath == nil)
            } else {
                rowAction("Download details", symbol: "info") { store.selection = [job.id]; store.showsInspector = true }
            }
            Menu { DownloadContextMenu(store: store, ids: contextSelection) } label: {
                Image(systemName: "ellipsis").frame(width: 32, height: 30).contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(width: 32, height: 30)
            .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(appearance.separatorColor, lineWidth: 1) }
            .disabled(!store.pendingJobIDs.isDisjoint(with: contextSelection))
            .help("More actions for \(job.displayTitle)")
            .accessibilityLabel("More actions for \(job.displayTitle)")
        }
    }

    private func rowAction(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 32, height: 30)
                .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(appearance.separatorColor, lineWidth: 1) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pending ? "Updating download…" : label)
        .accessibilityLabel(label)
    }

    private var formatLabel: String {
        let ext = URL(fileURLWithPath: job.outputPath ?? job.filename).pathExtension
        if !ext.isEmpty { return ext.uppercased() }
        if let options = job.options {
            if options.mode == .audioOnly { return options.audioFormat == "original" ? "Audio" : options.audioFormat.uppercased() }
            if options.container != "auto" { return options.container.uppercased() }
        }
        return job.kind == .media ? "Video" : "File"
    }

    private var qualityLabel: String? {
        if job.isAudio || job.options?.mode == .audioOnly {
            return job.options?.audioBitrateKbps.map { "\($0) kbps" }
        }
        if let height = job.quality?.height { return "\(height)p" }
        guard let quality = job.quality else { return nil }
        return quality.id == "best" ? "Best" : quality.label
    }

    private var totalSize: String {
        guard let value = job.totalBytes ?? (job.bytesReceived > 0 ? job.bytesReceived : nil) else { return "—" }
        return Format.bytes(value)
    }
}

private struct QuietLibraryStatus: View {
    let job: DownloadJob
    let compact: Bool
    @AppAppearance private var appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                statusMark
                Text(job.status.label).harborFont(.callout).lineLimit(1)
                Spacer(minLength: 0)
                if job.status == .downloading && !compact {
                    Text(Format.speed(job.bytesPerSecond))
                        .harborFont(.caption, monospacedDigits: true)
                        .foregroundStyle(appearance.mutedTextColor).lineLimit(1)
                }
            }
            if let progress = job.progress, job.status != .completed && job.status != .failed && job.status != .cancelled {
                ProgressView(value: progress)
                    .tint(job.status == .paused ? appearance.mutedTextColor : appearance.tintColor)
                    .accessibilityLabel("Download progress")
                HStack(spacing: 6) {
                    if !compact { Text(Format.bytes(job.bytesReceived)) }
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                    Spacer(minLength: 0)
                    Text(compact && job.status == .downloading ? Format.speed(job.bytesPerSecond) : job.status == .downloading && job.etaLabel != "—" ? "\(job.etaLabel) left" : Format.bytes(job.bytesReceived))
                }
                .harborFont(.caption, monospacedDigits: true)
                .foregroundStyle(appearance.mutedTextColor)
                .lineLimit(1)
                if compact && job.status == .downloading && job.etaLabel != "—" {
                    Text("\(job.etaLabel) left")
                        .harborFont(.caption, monospacedDigits: true)
                        .foregroundStyle(appearance.mutedTextColor)
                        .lineLimit(1)
                }
            } else {
                Text(statusDetail)
                    .harborFont(.caption)
                    .foregroundStyle(appearance.mutedTextColor)
                    .lineLimit(2)
                    .padding(.leading, 25)
            }
        }
        .help(job.errorMessage ?? "\(job.status.label) · \(job.sizeLabel)\(job.status == .downloading ? " · \(Format.speed(job.bytesPerSecond)) · \(job.etaLabel) left" : "")")
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusMark: some View {
        if job.status.isActive {
            Image(systemName: job.status == .downloading ? "arrow.down.circle" : job.status == .processing ? "gearshape" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(appearance.tintColor)
                .frame(width: 18, height: 18).accessibilityHidden(true)
        } else {
            Image(systemName: statusSymbol)
                .font(.system(size: job.status == .completed ? 20 : 17, weight: .medium))
                .foregroundStyle(job.status == .completed ? appearance.tintColor : job.status == .failed ? Color.red : appearance.mutedTextColor)
                .frame(width: 18, height: 20)
                .accessibilityHidden(true)
        }
    }

    private var statusSymbol: String {
        switch job.status {
        case .completed: "checkmark.circle.fill"
        case .paused: "pause.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "xmark.circle"
        default: "clock"
        }
    }

    private var statusDetail: String {
        switch job.status {
        case .completed: job.canPlay ? "Ready to play" : "Saved to your Mac"
        case .failed: job.errorMessage ?? "Retry or review download options"
        case .cancelled: "Download cancelled"
        case .queued: "Waiting for an available slot"
        case .resolving: "Finding available media"
        case .processing: "Preparing your file"
        case .paused: "Ready to resume"
        case .downloading: Format.speed(job.bytesPerSecond)
        }
    }
}
