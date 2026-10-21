import AppKit
import HarborCore
import SwiftUI

private enum BulkReviewStatus {
    case waiting, resolving, ready, adding, queued, failed
}

private struct BulkReviewItem: Identifiable {
    let id = UUID()
    let url: String
    var status: BulkReviewStatus = .waiting
    var preview: MediaPreview?
    var setup = DownloadSetup()
    var qualityID: String {
        get { setup.qualityID }
        set { setup.qualityID = newValue }
    }
    var selected = true
    var error: String?

    var quality: VideoQuality? { preview.flatMap { setup.quality(in: $0) } }
    var canSelect: Bool { status == .ready }
}

struct BulkURLSheet: View {
    let store: DownloadStore
    var initialURLs: [String] = []
    var onBack: (() -> Void)? = nil
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var input = ""
    @ViewState private var items: [BulkReviewItem] = []
    @ViewState private var resolving = false
    @ViewState private var downloading = false
    @ViewState private var duplicateCount = 0
    @ViewState private var reviewedInput = ""
    @ViewState private var failure: String?
    @ViewState private var reviewTask: Task<Void, Never>?
    @ViewState private var optionsItemID: UUID?
    @FocusState private var focused: Bool

    private var selectedItems: [BulkReviewItem] { items.filter { $0.canSelect && $0.selected } }
    private var readyCount: Int { items.filter(\.canSelect).count }
    private var queuedCount: Int { items.filter { $0.status == .queued }.count }
    private var working: Bool { resolving || downloading }
    private var commonQualities: [VideoQuality] {
        let previews = selectedItems.filter { $0.setup.options.mode != .audioOnly }.compactMap(\.preview).filter { !$0.isDirectFile }
        guard let first = previews.first else { return [] }
        return first.qualities.filter { quality in previews.allSatisfy { $0.qualities.contains(where: { $0.id == quality.id }) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { MVDMark(size: 29); Text("Bulk URLs").harborFont(.title2, weight: .semibold) }
                Text("Paste your links, review each video, then download your selection.")
                    .foregroundStyle(.secondary)
            }
            inputSection
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .harborFont(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if !items.isEmpty {
                reviewSection
            } else {
                Label("Video qualities and thumbnails appear after you review the links.", systemImage: "film.stack")
                    .harborFont(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            Divider()
            footer
        }
        .padding(25)
        .frame(width: 770)
        .background(appearance.backgroundColor)
        .interactiveDismissDisabled(downloading)
        .sheetCloseButton(disabled: downloading)
        .task {
            focused = true
            if !initialURLs.isEmpty {
                input = initialURLs.joined(separator: "\n")
                reviewURLs()
            } else if !store.bulkURLDraft.isEmpty {
                input = store.bulkURLDraft
                store.bulkURLDraft = ""
                reviewURLs()
            }
        }
        .onChange(of: input) { _, value in
            guard !working, value != reviewedInput else { return }
            items = []
            failure = nil
            duplicateCount = 0
        }
        .onDisappear { reviewTask?.cancel() }
        .sheet(isPresented: Binding(get: { optionsItemID != nil }, set: { if !$0 { optionsItemID = nil } })) {
            if let id = optionsItemID, let item = items.first(where: { $0.id == id }), let preview = item.preview {
                MediaOptionsSheet(store: store, preview: preview, sourceURL: item.url, initialSetup: item.setup) { setup in
                    update(id) { $0.setup = setup; $0.error = nil }
                    optionsItemID = nil
                }
                .harborEnvironment(store: store, appearance: appearance)
            }
        }
    }

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .font(appearance.font(.body))
                    .scrollContentBackground(.hidden)
                    .padding(7)
                    .focused($focused)
                    .accessibilityLabel("Bulk URLs, one per line")
                    .accessibilityIdentifier("bulkURLInput")
                if input.isEmpty {
                    Text("https://example.com/video\nhttps://example.com/another-video")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 15)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: items.isEmpty ? 160 : 94)
            .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary) }
            .disabled(working)
            HStack {
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) { input = pasted }
                    focused = true
                } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .disabled(working)
                Text("One URL per line · Up to 50 unique links")
                    .harborFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(resolving ? "Reading Links…" : "Review Links") { reviewURLs() }
                    .disabled(working || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("reviewBulkURLsButton")
            }
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                if resolving { ProgressView().controlSize(.mini) }
                Text(resolving ? "Reading video details…" : "\(readyCount) ready\(queuedCount > 0 ? " · \(queuedCount) added" : "")")
                    .harborFont(.subheadline, weight: .medium)
                if duplicateCount > 0 {
                    Text("\(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") ignored")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(selectedItems.count == readyCount && readyCount > 0 ? "Deselect All" : "Select All") {
                    let select = selectedItems.count != readyCount
                    for index in items.indices where items[index].canSelect { items[index].selected = select }
                }
                .buttonStyle(.link).disabled(working || readyCount == 0)
                Menu("Apply Quality") {
                    ForEach(commonQualities) { quality in
                        Button(quality.label) { applyQuality(quality) }
                    }
                }
                .disabled(working || commonQualities.isEmpty)
                .help("Apply a quality offered by every selected video. An incompatible exact format selection resets to Automatic. Audio-only and direct files keep their options.")
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        reviewRow(item)
                        if item.id != items.last?.id { Divider().padding(.leading, 42) }
                    }
                }
            }
            .frame(height: min(340, max(180, CGFloat(items.count) * 108)))
            .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary) }
        }
    }

    private func reviewRow(_ item: BulkReviewItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Select \(item.preview?.title ?? item.url)", isOn: Binding(
                get: { items.first(where: { $0.id == item.id })?.selected ?? false },
                set: { value in update(item.id) { $0.selected = value } }
            ))
            .toggleStyle(.checkbox).labelsHidden()
            .disabled(working || !item.canSelect)
            .padding(.top, 21)
            MediaThumbnail(url: item.preview?.thumbnailURL, width: 94, height: 56, title: item.preview?.title, proxyURL: store.settings.proxyURL)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.preview?.title.isEmpty == false ? item.preview!.title : (URL(string: item.url)?.host ?? item.url))
                    .harborFont(.subheadline, weight: .medium)
                    .lineLimit(2)
                Text(item.url).harborFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(item.url)
                rowStatus(item)
                if let error = item.error {
                    Text(error).harborFont(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if item.status == .ready, let preview = item.preview, !preview.isDirectFile {
                VStack(alignment: .trailing, spacing: 9) {
                    if item.setup.options.mode != .audioOnly {
                        Picker("Quality for \(preview.title)", selection: Binding(
                            get: { items.first(where: { $0.id == item.id })?.qualityID ?? item.qualityID },
                            set: { value in update(item.id) { $0.qualityID = value; $0.error = nil } }
                        )) {
                            ForEach(preview.qualities) { quality in Text(quality.label).tag(quality.id) }
                        }
                        .labelsHidden().disabled(working || item.setup.options.formatID != nil)
                    }
                    Button("Options…", systemImage: "slider.horizontal.3") { optionsItemID = item.id }.disabled(working)
                }
                .frame(width: 158)
            } else if item.status == .ready, item.preview?.isDirectFile == true {
                Button("Options…") { optionsItemID = item.id }.disabled(working)
            } else if item.status == .failed, DownloadStore.normalizedURL(item.url) != nil {
                Button("Retry") { resolveOnly(item.id) }.disabled(working)
            }
        }
        .padding(12)
    }

    @ViewBuilder private func rowStatus(_ item: BulkReviewItem) -> some View {
        switch item.status {
        case .waiting:
            Text("Waiting to read details").harborFont(.caption).foregroundStyle(.secondary)
        case .resolving:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Reading details…").harborFont(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 8) {
                Label(item.preview?.isDirectFile == true ? "Original file" : "Ready", systemImage: "checkmark.circle")
                if let duration = Format.duration(item.preview?.duration) { Text(duration).monospacedDigit() }
                if item.preview?.isDirectFile == false { Text(item.setup.options.mode.title) }
            }
            .harborFont(.caption).foregroundStyle(.secondary)
            Text(Format.folder(item.setup.destinationDirectory)).harborFont(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        case .adding:
            Label("Adding to downloads…", systemImage: "arrow.down.circle").harborFont(.caption).foregroundStyle(.secondary)
        case .queued:
            Label("Added to downloads", systemImage: "checkmark.circle.fill").harborFont(.caption).foregroundStyle(.green)
        case .failed:
            Text("Couldn’t read this link").harborFont(.caption).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            if let onBack { Button("Back", action: onBack).disabled(working) }
            Button(queuedCount > 0 ? "Done" : "Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction).disabled(downloading)
            Spacer()
            if downloading { ProgressView().controlSize(.small) }
            Label(Format.folder(store.settings.destinationDirectory), systemImage: "folder")
                .harborFont(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 265, alignment: .trailing)
            Button(downloading ? "Adding…" : "Download Selected\(selectedItems.isEmpty ? "" : " (\(selectedItems.count))")") { downloadSelected() }
                .buttonStyle(.borderedProminent)
                .disabled(working || selectedItems.isEmpty)
                .accessibilityIdentifier("downloadBulkSelectionButton")
        }
    }

    private func reviewURLs() {
        guard !working else { return }
        reviewedInput = input
        failure = nil
        var unique: Set<String> = []
        var parsed: [BulkReviewItem] = []
        var duplicates = 0
        for line in input.components(separatedBy: .newlines) {
            let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let normalized = DownloadStore.normalizedURL(raw)
            let value = normalized ?? raw
            guard unique.insert(value).inserted else { duplicates += 1; continue }
            var item = BulkReviewItem(url: value)
            let folder = store.folders.first(where: { $0.id == store.selectedFolderID })
            item.setup.destinationDirectory = folder?.path ?? store.settings.destinationDirectory
            item.setup.folderID = folder?.id
            if normalized == nil {
                item.status = .failed
                item.selected = false
                item.error = DownloadStore.urlEntryHint
            }
            parsed.append(item)
        }
        guard parsed.count <= 50 else {
            failure = "This list has \(parsed.count) unique links. Review up to 50 at a time."
            return
        }
        guard !parsed.isEmpty else { return }
        items = parsed
        duplicateCount = duplicates
        resolvePending()
    }

    private func resolveOnly(_ id: UUID) {
        update(id) { $0.status = .waiting; $0.error = nil }
        resolvePending()
    }

    private func resolvePending() {
        let pending = items.filter { $0.status == .waiting }.map { (id: $0.id, url: $0.url) }
        guard !pending.isEmpty else { return }
        resolving = true
        reviewTask = Task {
            defer { resolving = false }
            await withTaskGroup(of: (UUID, MediaPreview?, String?).self) { group in
                var next = 0
                @MainActor func addNext() {
                    guard next < pending.count, !Task.isCancelled else { return }
                    let entry = pending[next]
                    next += 1
                    update(entry.id) { $0.status = .resolving }
                    group.addTask {
                        do { return (entry.id, try await store.resolveMedia(entry.url), nil) }
                        catch { return (entry.id, nil, error.localizedDescription) }
                    }
                }
                addNext()
                addNext()
                for await (id, preview, error) in group {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    update(id) { item in
                        if let preview, preview.isDirectFile || !preview.qualities.isEmpty {
                            item.preview = preview
                            item.qualityID = preview.qualities.first(where: { $0.id == VideoQuality.best.id })?.id ?? preview.qualities.first?.id ?? VideoQuality.best.id
                            if preview.reportsAudioOnly { item.setup.options.mode = .audioOnly; item.setup.options.container = "auto" }
                            item.status = .ready
                            item.selected = true
                            item.error = nil
                        } else {
                            item.status = .failed
                            item.selected = false
                            item.error = error ?? "No downloadable video qualities were found for this link."
                        }
                    }
                    addNext()
                }
            }
        }
    }

    private func applyQuality(_ quality: VideoQuality) {
        for index in items.indices where items[index].canSelect && items[index].selected {
            guard items[index].setup.options.mode != .audioOnly else { continue }
            guard items[index].preview?.qualities.contains(where: { $0.id == quality.id }) == true else { continue }
            if let selectedFormat = items[index].preview?.formats.first(where: { $0.id == items[index].setup.options.formatID }), selectedFormat.height != quality.height {
                items[index].setup.options.formatID = nil
            }
            items[index].qualityID = quality.id
            items[index].error = nil
        }
    }

    private func downloadSelected() {
        let chosen = selectedItems
        guard !working, !chosen.isEmpty else { return }
        downloading = true
        reviewTask = Task {
            defer { downloading = false }
            for item in chosen {
                guard !Task.isCancelled else { break }
                update(item.id) { $0.status = .adding; $0.error = nil }
                do {
                    guard item.preview?.isDirectFile == true || item.setup.options.mode == .audioOnly || item.quality != nil else { throw UIError.message("Choose a quality available for this video.") }
                    try await store.enqueueReviewedURL(item.url, quality: item.quality, options: item.setup.options, destinationDirectory: item.setup.destinationDirectory, folderID: item.setup.folderID)
                    update(item.id) { $0.status = .queued; $0.selected = false }
                } catch {
                    update(item.id) { $0.status = .ready; $0.error = error.localizedDescription }
                }
            }
        }
    }

    private func update(_ id: UUID, _ change: (inout BulkReviewItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}
