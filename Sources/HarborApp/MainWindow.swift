import AppKit
import HarborCore
import SwiftUI

struct MainWindow: View {
    @Bindable var store: DownloadStore
    @AppAppearance private var appearance
    @ViewState private var showsAccelerationConfirmation = false
    private var acceleratableJobs: [DownloadJob] { store.selectedJobs.filter { $0.status != .completed && $0.status != .processing } }
    private var accelerationEnabled: Bool { !acceleratableJobs.isEmpty && acceleratableJobs.allSatisfy { $0.options?.accelerated == true } }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                LibrarySidebar(store: store)
                    .frame(width: geometry.size.width < 1040 ? 210 : 232)
                Rectangle().fill(appearance.separatorColor).frame(width: 1)
                VStack(spacing: 0) {
                    LibraryHeader(store: store)
                        .padding(.top, 52)
                        .padding(.bottom, 22)
                    if let error = store.connectionError { serviceBanner(error).padding(.bottom, 12) }
                    DownloadViewBar(store: store)
                    if !store.selection.isEmpty { selectionActions.padding(.bottom, 12) }
                    Group {
                        if store.libraryView == .grid { DownloadGrid(store: store) }
                        else { QuietLibraryList(store: store) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    LibraryStatusBar(store: store)
                }
                .padding(.horizontal, geometry.size.width < 1040 ? 22 : 32)
                .background(appearance.backgroundColor)
            }
            .environment(appearance)
            .environment(store)
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle("MVD")
        .inspector(isPresented: $store.showsInspector) {
            DownloadInspector(store: store)
                .inspectorColumnWidth(min: 250, ideal: 285, max: 340)
                .harborEnvironment(store: store, appearance: appearance)
        }
        .sheet(item: $store.sheet) { sheet in
            Group {
                switch sheet {
                case .addURL: AddURLSheet(store: store)
                case .fetchPage: FetchPageSheet(store: store)
                case .bulkURLs: BulkURLSheet(store: store)
                case .folderEditor: FolderEditorSheet(store: store, folder: store.folderToEdit)
                case .editDownload:
                    if let job = store.editingJob { EditDownloadSheet(store: store, job: job) }
                }
            }
            .harborEnvironment(store: store, appearance: appearance)
        }
        .alert(item: $store.actionFailure) { failure in
            Alert(title: Text(failure.title), message: Text(failure.message), dismissButton: .default(Text("OK")))
        }
        .background(NativeWindowChrome(integratedTitlebar: true))
        .onChange(of: store.visibleJobs.map(\.id)) { _, visibleIDs in
            store.selection.formIntersection(Set(visibleIDs))
        }
        .confirmationDialog(accelerationEnabled ? "Disable acceleration?" : "Accelerate selected transfers?", isPresented: $showsAccelerationConfirmation, titleVisibility: .visible) {
            Button(accelerationEnabled ? "Disable and Restart" : "Accelerate and Restart") {
                Task { await store.setAcceleration(!accelerationEnabled, jobs: acceleratableJobs) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Active transfers restart with the new setting. Paused downloads stay paused. Parallel file ranges and media fragments are used where supported; speed depends on the server and your network.")
        }
    }

    private var selectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { selectionCount; Spacer(minLength: 4); transferActions; detailsAction }
            HStack(spacing: 10) {
                selectionCount
                Spacer(minLength: 0)
                Menu("Actions") { transferActions; detailsAction }
                    .fixedSize()
            }
        }
        .harborFont(.callout)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(appearance.selectionColor, in: RoundedRectangle(cornerRadius: 8))
    }
    private var selectionCount: some View { Text("\(store.selection.count) selected").foregroundStyle(.secondary) }
    private var detailsAction: some View {
        Button("Details", systemImage: "sidebar.right") { store.showsInspector.toggle() }
            .help("Show or hide download details (⌥⌘I)")
    }
    @ViewBuilder private var transferActions: some View {
        if store.selectedJobs.contains(where: \.canPause) {
            Button("Pause", systemImage: "pause") { Task { await store.perform(.pause, jobs: store.selectedJobs.filter(\.canPause)) } }
        }
        if store.selectedJobs.contains(where: \.canResume) {
            Button("Resume", systemImage: "play") { Task { await store.perform(.resume, jobs: store.selectedJobs.filter(\.canResume)) } }
        }
        if store.selectedJobs.contains(where: \.canCancel) {
            Button("Cancel", systemImage: "xmark") { Task { await store.perform(.cancel, jobs: store.selectedJobs.filter(\.canCancel)) } }
        }
        if !acceleratableJobs.isEmpty {
            Button(accelerationEnabled ? "Acceleration On" : "Accelerate", systemImage: "bolt.fill") { showsAccelerationConfirmation = true }
                .disabled(!store.pendingJobIDs.isDisjoint(with: store.selection))
        }
    }

    private func serviceBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("Can’t reach the download service").fontWeight(.medium)
                Text(message).harborFont(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 6)
            Button("Reconnect") { Task { await store.reconnect() } }
        }
        .padding(12)
        .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 8))
    }
}
