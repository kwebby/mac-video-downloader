import AppKit
import HarborCore
import SwiftUI

struct JobProgressCell: View {
    let job: DownloadJob
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if job.status == .completed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if job.status == .failed { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                Text(job.status.label).foregroundStyle(job.statusColor)
                Spacer(minLength: 2)
                if let progress = job.progress, job.status != .completed {
                    Text(progress, format: .percent.precision(.fractionLength(0))).foregroundStyle(.secondary).monospacedDigit()
                }
            }.harborFont(.caption)
            if let progress = job.progress, job.status != .completed {
                ProgressView(value: progress).tint(job.statusColor).accessibilityLabel("Download progress")
            } else if job.status.isActive {
                ProgressView().controlSize(.mini).accessibilityLabel(job.status.label)
            }
        }
        .padding(.vertical, 6)
        .help(job.errorMessage ?? job.status.label)
    }
}

struct DownloadContextMenu: View {
    let store: DownloadStore
    let ids: Set<UUID>
    private var jobs: [DownloadJob] { store.jobs.filter { ids.contains($0.id) } }
    private var isPending: Bool { !store.pendingJobIDs.isDisjoint(with: ids) }
    var body: some View {
        if !jobs.isEmpty {
            Button("Pause") { Task { await store.perform(.pause, jobs: jobs.filter(\.canPause)) } }.disabled(isPending || !jobs.contains(where: \.canPause))
            Button("Resume / Retry") { Task { await store.perform(.resume, jobs: jobs.filter(\.canResume)) } }.disabled(isPending || !jobs.contains(where: \.canResume))
            Button("Cancel Download") { Task { await store.perform(.cancel, jobs: jobs.filter(\.canCancel)) } }.disabled(isPending || !jobs.contains(where: \.canCancel))
            Divider()
            if jobs.count == 1, let job = jobs.first {
                if job.canPlay {
                    Button(job.isAudio ? "Play Audio" : "Play Video", systemImage: "play.fill") { store.play(job) }
                        .disabled(store.openingPlaybackIDs.contains(job.id))
                }
                Button("Edit Download Options…") { store.editOptions(for: job) }.disabled(isPending || job.status == .processing)
                Button("Show in Finder") { store.reveal(job) }.disabled(job.outputPath == nil)
                Button("Open Source Page") { store.openSource(job) }
                Button("Copy Source URL") { store.copyURL(job) }
                Divider()
            }
            Button("Remove from List") { Task { await store.perform(.remove, jobs: jobs.filter(\.canRemove)) } }
                .disabled(isPending || !jobs.contains(where: \.canRemove))
        } else {
            Button("New Download…") { store.sheet = .addURL }
            Button("Bulk URLs…") { store.sheet = .bulkURLs }
        }
    }
}
