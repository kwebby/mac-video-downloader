import AppKit
import HarborCore
import SwiftUI

struct DownloadGrid: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(store.visibleJobs) { job in
                    DownloadGridCard(store: store, job: job)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appearance.backgroundColor)
        .overlay {
            if store.visibleJobs.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptySymbol)
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if !store.search.isEmpty {
                        Button("Clear Search") { store.search = "" }
                    } else if store.selectedFolderID != nil || store.jobs.isEmpty {
                        Button("Add URL…") { store.sheet = .addURL }
                    }
                }
            }
        }
    }

    private var emptyTitle: String {
        store.search.isEmpty ? "No downloads in \(store.libraryTitle)" : "No matching downloads"
    }

    private var emptySymbol: String {
        if !store.search.isEmpty { return "magnifyingglass" }
        return store.selectedFolderID == nil ? store.filter.symbol : "folder"
    }

    private var emptyDescription: String {
        if !store.search.isEmpty { return "Try a different filename, source, or status." }
        if store.selectedFolderID != nil { return "Choose Add URL to save a download in this folder." }
        return "Downloads will appear here when their status changes."
    }
}

private struct DownloadGridCard: View {
    @Bindable var store: DownloadStore
    let job: DownloadJob
    @AppAppearance private var appearance
    @FocusState private var selectionIsFocused: Bool

    private var isSelected: Bool { store.selection.contains(job.id) }
    private var contextSelection: Set<UUID> { isSelected ? store.selection : [job.id] }

    var body: some View {
        VStack(spacing: 0) {
            artwork
                .padding(.horizontal, 10)
                .padding(.top, 10)

            Button(action: select) {
                details
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .focused($selectionIsFocused)
            .simultaneousGesture(TapGesture(count: 2).onEnded { open() })
            .onKeyPress(.return) {
                open()
                return .handled
            }
            .accessibilityLabel(job.displayTitle)
            .accessibilityValue(accessibilityStatus)
            .accessibilityHint("Select download. Press Return to open or inspect it.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction { select() }
            .accessibilityAction(named: Text("Open or inspect download")) { open() }
        }
        .background {
            // This is a sibling hit target behind the controls, so clicking Play
            // never runs the card's selection or double-click gestures.
            RoundedRectangle(cornerRadius: 11)
                .fill(appearance.surfaceColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(appearance.tintColor.opacity(isSelected ? 0.08 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 11))
                .onTapGesture(count: 2) { open() }
                .onTapGesture { select() }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    isSelected || selectionIsFocused ? appearance.tintColor : Color.primary.opacity(0.10),
                    lineWidth: selectionIsFocused ? 2 : isSelected ? 1.5 : 1
                )
                .allowsHitTesting(false)
        }
        .contextMenu {
            DownloadContextMenu(store: store, ids: contextSelection)
        }
    }

    private var artwork: some View {
        GeometryReader { geometry in
            if job.canPlay {
                playableArtwork(size: geometry.size)
            } else {
                playableArtwork(size: geometry.size)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open() }
                    .onTapGesture { select() }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
    }

    private func playableArtwork(size: CGSize) -> some View {
        // Card selection is a border/tint, rather than the table's solid fill.
        // Keep the shared artwork's normal foreground contrast in both themes.
        PlayableDownloadArtwork(
            job: job,
            width: size.width,
            height: size.height,
            proxyURL: store.settings.proxyURL,
            isOpening: store.openingPlaybackIDs.contains(job.id)
        ) {
            store.play(job)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.displayTitle)
                .harborFont(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(job.displayTitle)

            HStack(spacing: 6) {
                Text(job.sourceHost).lineLimit(1).truncationMode(.middle)
                if job.options?.accelerated == true {
                    Image(systemName: "bolt.fill")
                        .foregroundStyle(.green)
                        .help("Acceleration enabled")
                }
                if let options = job.options, options.mode != .videoWithAudio {
                    Image(systemName: options.mode.symbol).help(options.mode.title)
                }
            }
            .harborFont(.caption)
            .foregroundStyle(.secondary)

            JobProgressCell(job: job)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(job.sizeLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.sizeLabel)
                Spacer(minLength: 0)
                if job.status == .downloading {
                    Text(Format.speed(job.bytesPerSecond))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .harborFont(.caption, monospacedDigits: true)
            .foregroundStyle(.secondary)
        }
    }

    private var accessibilityStatus: String {
        var parts = [job.sourceHost, job.status.label, job.sizeLabel]
        if let progress = job.progress, job.status != .completed {
            parts.append(progress.formatted(.percent.precision(.fractionLength(0))))
        }
        if job.status == .downloading { parts.append(Format.speed(job.bytesPerSecond)) }
        return parts.joined(separator: ", ")
    }

    private func select() {
        if NSEvent.modifierFlags.contains(.command) {
            if !store.selection.insert(job.id).inserted { store.selection.remove(job.id) }
        } else {
            store.selection = [job.id]
        }
    }

    private func open() { store.primaryAction([job.id]) }
}
