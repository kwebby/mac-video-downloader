import AppKit
import HarborCore
import SwiftUI

struct MediaOptionsSheet: View {
    let store: DownloadStore
    let preview: MediaPreview
    let sourceURL: String
    let initialSetup: DownloadSetup
    let onSave: (DownloadSetup) -> Void
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var setup = DownloadSetup()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download Options").harborFont(.title2)
            ScrollView {
                VStack(spacing: 12) {
                    MediaPreviewCard(preview: preview, sourceURL: sourceURL, qualityID: $setup.qualityID, showsQuality: false, proxyURL: store.settings.proxyURL)
                    DownloadOptionsView(store: store, preview: preview, setup: $setup, sourceURL: sourceURL)
                }
            }
            .frame(height: min(510, max(300, (NSScreen.main?.visibleFrame.height ?? 850) - 240)))
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Options") { onSave(setup); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 680)
        .background(appearance.backgroundColor)
        .sheetCloseButton()
        .task { setup = initialSetup }
    }
}

struct EditDownloadSheet: View {
    let store: DownloadStore
    let job: DownloadJob
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var setup = DownloadSetup()
    @ViewState private var preview: MediaPreview?
    @ViewState private var loading = true
    @ViewState private var applying = false
    @ViewState private var failure: String?

    private var latestJob: DownloadJob { store.jobs.first(where: { $0.id == job.id }) ?? job }
    private var applyLabel: String {
        switch latestJob.status {
        case .completed: "Download New Copy"
        case .paused: "Apply Changes"
        case .queued: "Apply and Queue"
        default: "Restart with Changes"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 11) {
                MVDMark(size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Edit Download Options").harborFont(.title2)
                    Text(job.displayTitle).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if loading {
                ProgressView("Reading available formats…").frame(maxWidth: .infinity).padding(40)
            } else if let preview {
                ScrollView {
                    VStack(spacing: 12) {
                        MediaPreviewCard(preview: preview, sourceURL: job.sourceURL, qualityID: $setup.qualityID, showsQuality: false, proxyURL: store.settings.proxyURL)
                        DownloadOptionsView(store: store, preview: preview, setup: $setup, sourceURL: job.sourceURL)
                    }
                }.frame(height: min(480, max(280, (NSScreen.main?.visibleFrame.height ?? 850) - 320)))
                Label(latestJob.status == .completed ? "A new download will be created. Your saved file is kept." : (latestJob.status == .paused ? "Applying changes discards incompatible partial data. This download stays paused." : "This restarts the transfer with the chosen options. Incompatible partial data is discarded."), systemImage: latestJob.status == .completed ? "doc.on.doc" : "arrow.clockwise")
                    .harborFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Text(failure).harborFont(.callout).foregroundStyle(.red).textSelection(.enabled)
                if preview == nil { Button("Read Formats Again") { Task { await loadPreview() } }.disabled(loading) }
            }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(applying)
                Spacer()
                if applying { ProgressView().controlSize(.small) }
                Button(applying ? "Applying…" : applyLabel) { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || applying || preview == nil || latestJob.status == .processing)
            }
        }
        .padding(24).frame(width: 710)
        .background(appearance.backgroundColor)
        .interactiveDismissDisabled(applying)
        .sheetCloseButton(disabled: applying)
        .task {
            setup.qualityID = job.quality?.id ?? VideoQuality.best.id
            setup.options = job.options ?? DownloadOptions()
            setup.destinationDirectory = job.destinationDirectory
            setup.folderID = job.folderID
            await loadPreview()
        }
    }

    private func loadPreview() async {
        loading = true
        failure = nil
        defer { loading = false }
        do {
            let resolved = try await store.resolveMedia(job.sourceURL)
            if resolved.reportsAudioOnly { setup.options.mode = .audioOnly; setup.options.container = "auto" }
            if !resolved.qualities.contains(where: { $0.id == setup.qualityID }) { setup.qualityID = resolved.qualities.first?.id ?? VideoQuality.best.id }
            if let selected = setup.options.formatID, !resolved.formats.contains(where: { $0.id == selected }) {
                setup.options.formatID = nil
                failure = "The previously selected source format is no longer offered. Choose a current format or Automatic."
            }
            preview = resolved
        } catch { failure = error.localizedDescription }
    }

    private func apply() {
        guard let preview else { return }
        applying = true
        failure = nil
        Task {
            defer { applying = false }
            do {
                try await store.updateDownload(job, quality: setup.quality(in: preview), options: setup.options, destinationDirectory: setup.destinationDirectory, folderID: setup.folderID)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
