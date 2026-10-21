import AppKit
import HarborCore
import SwiftUI

struct URLComposer: View {
    let store: DownloadStore
    let dismissOnSuccess: Bool
    @ViewState private var url = ""
    @ViewState private var preview: MediaPreview?
    @ViewState private var reviewedURL: String?
    @ViewState private var setup = DownloadSetup()
    @ViewState private var resolving = false
    @ViewState private var failure: String?
    @ViewState private var reviewTask: Task<Void, Never>?
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                TextField("Paste a URL…", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .focused($focused)
                    .onSubmit { reviewOrDownload() }
                    .disabled(resolving || store.submitting)
                    .accessibilityLabel("Download URL")
                    .accessibilityIdentifier("downloadURLField")
                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        if pasted.components(separatedBy: .newlines).filter({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }).count > 1 {
                            store.openPastedURLs(pasted)
                        } else { url = pasted }
                    }
                    focused = true
                } label: { Image(systemName: "doc.on.clipboard") }
                    .controlSize(.large)
                    .help("Paste a link from the clipboard")
                    .accessibilityLabel("Paste URL")
                    .disabled(resolving || store.submitting)
            }
            if let preview, let reviewedURL {
                ScrollView {
                    VStack(spacing: 12) {
                        MediaPreviewCard(preview: preview, sourceURL: reviewedURL, qualityID: $setup.qualityID, showsQuality: false, proxyURL: store.settings.proxyURL)
                        DownloadOptionsView(store: store, preview: preview, setup: $setup, showsDestination: false, sourceURL: reviewedURL)
                    }
                }
                .frame(height: min(330, max(220, (NSScreen.main?.visibleFrame.height ?? 850) - 550)))
            }
            DestinationPicker(store: store, destination: $setup.destinationDirectory, folderID: $setup.folderID)
                .padding(10)
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .harborFont(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(resolving ? "Reading media details and available qualities…" : (preview == nil ? "Review video and audio output before downloading. Other files start immediately." : "Ready to download to your selected folder."))
                    .harborFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button(action: reviewOrDownload) {
                    HStack(spacing: 7) {
                        if resolving || store.submitting { ProgressView().controlSize(.mini) }
                        Text(resolving ? "Reading…" : (store.submitting ? "Starting…" : (preview == nil ? "Review Link" : "Download")))
                    }.frame(minWidth: 82)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(resolving || store.submitting || DownloadStore.normalizedURL(url) == nil || (preview != nil && setup.options.mode != .audioOnly && selectedQuality == nil))
                .accessibilityIdentifier("startDownloadButton")
            }
        }
        .task {
            focused = true
            if setup.destinationDirectory.isEmpty {
                let folder = store.folders.first(where: { $0.id == store.selectedFolderID })
                setup.destinationDirectory = folder?.path ?? store.settings.destinationDirectory
                setup.folderID = folder?.id
            }
            loadDraft()
        }
        .onChange(of: store.urlDraft) { _, value in if !value.isEmpty, !resolving, !store.submitting { loadDraft() } }
        .onChange(of: url) { _, newValue in
            if DownloadStore.normalizedURL(newValue) != reviewedURL {
                preview = nil
                reviewedURL = nil
                failure = nil
            }
        }
        .onDisappear { reviewTask?.cancel() }
    }

    private var selectedQuality: VideoQuality? { preview.flatMap { setup.quality(in: $0) } }

    private func loadDraft() {
        guard dismissOnSuccess, !store.urlDraft.isEmpty else { return }
        let shouldReview = store.reviewDraftAutomatically
        url = store.urlDraft
        store.urlDraft = ""
        store.reviewDraftAutomatically = false
        preview = nil
        reviewedURL = nil
        failure = nil
        if shouldReview { reviewOrDownload() }
    }

    private func reviewOrDownload() {
        guard !resolving, !store.submitting else { return }
        guard let normalized = DownloadStore.normalizedURL(url) else { failure = DownloadStore.urlEntryHint; return }
        failure = nil
        if let preview, reviewedURL == normalized {
            guard preview.isDirectFile || setup.options.mode == .audioOnly || selectedQuality != nil else { return }
            reviewTask = Task {
                if await store.enqueue(normalized, quality: selectedQuality, options: setup.options, destinationDirectory: setup.destinationDirectory, folderID: setup.folderID) { finish() }
            }
            return
        }
        resolving = true
        reviewTask = Task {
            defer { resolving = false }
            do {
                let resolved = try await store.resolveMedia(normalized)
                guard !Task.isCancelled else { return }
                if resolved.isDirectFile {
                    if await store.enqueue(normalized, options: setup.options, destinationDirectory: setup.destinationDirectory, folderID: setup.folderID) { finish() }
                } else {
                    guard !resolved.qualities.isEmpty else { throw UIError.message("No downloadable video qualities were found for this link.") }
                    reviewedURL = normalized
                    setup.qualityID = resolved.qualities.first(where: { $0.id == VideoQuality.best.id })?.id ?? resolved.qualities[0].id
                    setup.options.formatID = nil
                    if resolved.reportsAudioOnly { setup.options.mode = .audioOnly; setup.options.container = "auto" }
                    preview = resolved
                }
            } catch {
                guard !Task.isCancelled else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func finish() {
        url = ""
        preview = nil
        reviewedURL = nil
        if dismissOnSuccess { dismiss() }
    }
}

struct AddURLSheet: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) { MVDMark(size: 29); Text("New Download").harborFont(.title2, weight: .semibold) }
                Text("Paste a link, review the media, and choose its output.")
                    .foregroundStyle(.secondary)
                if let source = store.reviewSourcePageURL, let host = URL(string: source)?.host {
                    Label("Sent from \(host). Review the link to continue.", systemImage: "puzzlepiece.extension")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
            }
            URLComposer(store: store, dismissOnSuccess: true)
            Divider()
            HStack(alignment: .center) {
                Label("Video, audio, or silent video", systemImage: "film.stack")
                    .harborFont(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(25)
        .frame(width: 710)
        .background(appearance.backgroundColor)
        .interactiveDismissDisabled(store.submitting)
        .sheetCloseButton(disabled: store.submitting)
        .onDisappear { store.reviewSourcePageURL = nil }
    }
}

struct FetchPageSheet: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var url = ""
    @ViewState private var candidates: [PageCandidate] = []
    @ViewState private var selected: Set<String> = []
    @ViewState private var fetching = false
    @ViewState private var downloading = false
    @ViewState private var scanned = false
    @ViewState private var failure: String?
    @ViewState private var reviewURLs: [String]?
    @FocusState private var focused: Bool

    var body: some View {
        if let reviewURLs {
            BulkURLSheet(store: store, initialURLs: reviewURLs, onBack: { self.reviewURLs = nil })
                .harborEnvironment(store: store, appearance: appearance)
        } else {
            pageContent
        }
    }

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Fetch Links from Page").harborFont(.title2, weight: .semibold)
                Text("Collect links from a webpage, then choose what to download.").foregroundStyle(.secondary)
            }
            HStack {
                TextField("https://example.com/page", text: $url)
                    .textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { fetch() }.accessibilityLabel("Webpage URL")
                Button(fetching ? "Fetching…" : "Fetch Links") { fetch() }
                    .disabled(fetching || downloading || DownloadStore.normalizedURL(url) == nil)
            }
            if fetching { ProgressView("Reading page…").controlSize(.small) }
            if let failure { Text(failure).foregroundStyle(.red).harborFont(.callout).textSelection(.enabled) }
            if scanned {
                HStack {
                    Text("\(candidates.count) links found").font(.subheadline.weight(.medium))
                    Spacer()
                    Button(selected.count == candidates.count ? "Deselect All" : "Select All") {
                        selected = selected.count == candidates.count ? [] : Set(candidates.map(\.url))
                    }.buttonStyle(.link).disabled(candidates.isEmpty || downloading)
                }
                List(candidates) { candidate in
                    Toggle(isOn: Binding(get: { selected.contains(candidate.url) }, set: { value in
                        if value { selected.insert(candidate.url) } else { selected.remove(candidate.url) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.title.isEmpty ? candidate.url : candidate.title).lineLimit(1)
                            Text(candidate.url).harborFont(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }.padding(.vertical, 5)
                    }.toggleStyle(.checkbox).disabled(downloading)
                }
                .frame(height: 250)
                .overlay { if candidates.isEmpty { Text("No downloadable links were found.").foregroundStyle(.secondary) } }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Static page links and media sources", systemImage: "link")
                    Text("Pages that load content through scripts may need the Chrome companion or the original video page URL.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 12)
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(downloading)
                Spacer()
                if downloading { ProgressView().controlSize(.small) }
                Button("Review Selected\(selected.isEmpty ? "" : " (\(selected.count))")") { reviewSelected() }
                    .buttonStyle(.borderedProminent).disabled(selected.isEmpty || fetching || downloading)
            }
        }
        .padding(25)
        .frame(width: 650)
        .background(appearance.backgroundColor)
        .interactiveDismissDisabled(downloading)
        .sheetCloseButton(disabled: downloading)
        .task { focused = true }
    }

    private func fetch() {
        guard !fetching, DownloadStore.normalizedURL(url) != nil else { return }
        fetching = true
        failure = nil
        Task {
            defer { fetching = false }
            do {
                candidates = try await store.inspectPage(url)
                selected = []
                scanned = true
            } catch { failure = error.localizedDescription }
        }
    }

    private func reviewSelected() {
        let chosen = candidates.filter { selected.contains($0.url) }.map(\.url)
        guard chosen.count <= 50 else { failure = "Choose up to 50 links at a time to review."; return }
        reviewURLs = chosen
    }
}
