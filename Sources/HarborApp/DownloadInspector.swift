import Foundation
import HarborCore
import SwiftUI

struct DownloadInspector: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    var body: some View {
        Group {
            if store.selectedJobs.count == 1, let job = store.selectedJobs.first {
                JobInspector(store: store, job: job)
            } else if store.selectedJobs.count > 1 {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(store.selectedJobs.count) downloads selected").harborFont(.headline)
                    Text("Use the toolbar or context menu to manage this selection.").foregroundStyle(.secondary)
                    LabeledContent("Transferred", value: Format.bytes(store.selectedJobs.reduce(0) { $0 + $1.bytesReceived }))
                    Spacer()
                }.padding(20)
            } else {
                ContentUnavailableView {
                    Label("Download Details", systemImage: "info.circle")
                } description: {
                    Text("Select a download to see its source, progress, and saved file.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.surfaceColor)
    }
}

private struct JobInspector: View {
    let store: DownloadStore
    let job: DownloadJob
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    if job.kind == .media || job.isAudio || job.isVideo {
                        GeometryReader { geometry in
                            PlayableDownloadArtwork(job: job, width: geometry.size.width, height: geometry.size.width * 9 / 16, proxyURL: store.settings.proxyURL, isOpening: store.openingPlaybackIDs.contains(job.id)) {
                                store.play(job)
                            }
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                    } else {
                        Image(systemName: job.fileSymbol).font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    }
                    Text(job.displayTitle).harborFont(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(job.status.label).harborFont(.subheadline).foregroundStyle(job.statusColor)
                    if job.status != .completed { JobProgressCell(job: job) }
                }
                Divider()
                inspectorSection("Transfer") {
                    detail("Received", job.sizeLabel)
                    if let options = job.options {
                        detail("Output", options.mode.title)
                        if options.mode == .audioOnly {
                            detail("Audio format", options.audioFormat == "original" ? "Original audio" : options.audioFormat.uppercased())
                            if let bitrate = options.audioBitrateKbps { detail("Conversion bitrate", "\(bitrate) kbps") }
                        } else if options.container != "auto" { detail("Container", options.container.uppercased()) }
                        if let format = options.formatID { detail("Source format", format) }
                        detail("Acceleration", options.accelerated ? "Enabled" : "Off")
                    }
                    if let quality = job.quality { detail("Quality", quality.label) }
                    if let duration = job.duration, duration.isFinite, duration > 0 { detail("Duration", durationLabel(duration)) }
                    detail("Speed", job.status == .downloading ? Format.speed(job.bytesPerSecond) : "—")
                    detail("Time remaining", job.etaLabel)
                    detail("Added", job.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let completed = job.completedAt { detail("Finished", completed.formatted(date: .abbreviated, time: .shortened)) }
                    Button("Edit Download Options…", systemImage: "slider.horizontal.3") { store.editOptions(for: job) }
                        .disabled(job.status == .processing || store.pendingJobIDs.contains(job.id))
                    if job.status != .completed && job.status != .processing {
                        Button(job.status == .paused ? (job.options?.accelerated == true ? "Disable Acceleration" : "Enable Acceleration") : (job.options?.accelerated == true ? "Disable & Restart" : "Accelerate & Restart"), systemImage: "bolt.fill") {
                            Task { await store.setAcceleration(job.options?.accelerated != true, jobs: [job]) }
                        }
                        .disabled(store.pendingJobIDs.contains(job.id))
                        .help("Uses parallel ranges or fragments where supported. Active transfers restart; speed depends on the source and network.")
                    }
                }
                if let error = job.errorMessage, !error.isEmpty {
                    inspectorSection(job.status == .failed ? "Needs attention" : "Recovery") {
                        Text(error).harborFont(.callout)
                            .foregroundStyle(job.status == .failed ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                        if job.canResume {
                            Button(job.status == .paused ? "Resume Download" : "Retry Download", systemImage: job.status == .paused ? "play" : "arrow.clockwise") {
                                Task { await store.perform(.resume, jobs: [job]) }
                            }
                        }
                    }
                }
                Divider()
                inspectorSection("Saved file") {
                    if !job.filename.isEmpty { Text(job.filename).harborFont(.callout).textSelection(.enabled) }
                    if let folder = store.folders.first(where: { $0.id == job.folderID }) { Label(folder.name, systemImage: folder.icon).foregroundStyle(folder.displayColor) }
                    Text(Format.folder(job.outputPath ?? job.destinationDirectory))
                        .harborFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if job.outputPath != nil {
                        Button("Show in Finder", systemImage: "folder") { store.reveal(job) }
                    }
                }
                Divider()
                inspectorSection("Source") {
                    Text(job.sourceURL).harborFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open", systemImage: "arrow.up.right.square") { store.openSource(job) }
                        Button("Copy URL", systemImage: "doc.on.doc") { store.copyURL(job) }
                    }
                }
                if job.canRemove {
                    Divider()
                    Button("Remove from List", systemImage: "trash") { Task { await store.perform(.remove, jobs: [job]) } }
                        .help("Removes this entry and temporary transfer data. Saved files are kept.")
                }
            }
            .harborFont(.callout)
            .padding(20)
        }
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).harborFont(.caption).foregroundStyle(.secondary)
            Text(value).harborFont(.callout, monospacedDigits: true).textSelection(.enabled)
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        let total = Int(min(seconds, Double(Int.max / 2)))
        let hours = total / 3600
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func inspectorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).harborFont(.subheadline, weight: .semibold)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
