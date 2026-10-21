import AppKit
import HarborCore
import SwiftUI

extension DownloadFolder {
    var displayColor: Color {
        let hex = colorHex ?? "22A86B"
        guard let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return .green }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct DestinationPicker: View {
    let store: DownloadStore
    @Binding var destination: String
    @Binding var folderID: UUID?
    @AppAppearance private var appearance
    @ViewState private var showsFolderEditor = false
    @ViewState private var folderToEdit: DownloadFolder?
    private var selectedFolder: DownloadFolder? { store.folders.first(where: { $0.id == folderID }) }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selectedFolder?.icon ?? "folder")
                .foregroundStyle(selectedFolder?.displayColor ?? .secondary)
                .font(.system(size: 20))
                .frame(width: 25)
            VStack(alignment: .leading, spacing: 4) {
                Text(selectedFolder?.name ?? (destination == store.settings.destinationDirectory ? "Default download folder" : "Custom download folder"))
                    .harborFont(.callout, weight: .medium)
                Text(Format.folder(destination.isEmpty ? store.settings.destinationDirectory : destination))
                    .harborFont(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            Spacer(minLength: 5)
            Menu {
                Button("Default download folder") {
                    destination = store.settings.destinationDirectory
                    folderID = nil
                }
                ForEach(store.folders) { folder in
                    Button { destination = folder.path; folderID = folder.id } label: { Label(folder.name, systemImage: folder.icon) }
                }
                Divider()
                Button("Choose / Create Folder…") { chooseFolder() }
                Button("New Folder Shortcut…") { folderToEdit = nil; showsFolderEditor = true }
                if let selectedFolder {
                    Button("Edit “\(selectedFolder.name)”…") { folderToEdit = selectedFolder; showsFolderEditor = true }
                }
            } label: { Label("Change…", systemImage: "chevron.up.chevron.down") }
            .fixedSize()
            .accessibilityIdentifier("downloadDestinationPicker")
        }
        .sheet(isPresented: $showsFolderEditor) {
            FolderEditorSheet(store: store, folder: folderToEdit) { folder in
                destination = folder.path
                folderID = folder.id
            }
            .harborEnvironment(store: store, appearance: appearance)
        }
        .onChange(of: store.folders) { _, folders in
            guard let folderID else { return }
            if let selected = folders.first(where: { $0.id == folderID }) { destination = selected.path }
            else { self.folderID = nil }
        }
        .onAppear { if let selectedFolder { destination = selectedFolder.path } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose or Create Download Folder"
        panel.prompt = "Save Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination.isEmpty ? store.settings.destinationDirectory : destination)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path; folderID = nil }
    }
}

struct FolderEditorSheet: View {
    let store: DownloadStore
    var folder: DownloadFolder? = nil
    var onSaved: ((DownloadFolder) -> Void)? = nil
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @ViewState private var path = ""
    @ViewState private var icon = "folder"
    @ViewState private var colorHex = "22A86B"
    @ViewState private var saving = false
    @ViewState private var failure: String?
    private let icons = ["folder", "film", "music.note", "play.rectangle", "photo", "doc", "graduationcap", "briefcase", "archivebox", "star", "externaldrive", "tray"]
    private let colors = ["22A86B", "3688F4", "8B5CF6", "E38A24", "D45490", "20A6A8", "818B98"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(previewFolder.displayColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(folder == nil ? "New Folder Shortcut" : "Edit Folder Shortcut").harborFont(.title2)
                    Text("Organize downloads with a named location, icon, and color.").foregroundStyle(.secondary)
                }
            }
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder shortcut name")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Save location", systemImage: "folder")
                    Spacer()
                    Button("Choose / Create…") { chooseFolder() }
                }
                Text(Format.folder(path)).harborFont(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 7))
                Text("Use New Folder in the chooser to create a folder on disk. Editing this shortcut does not rename or move existing files.")
                    .harborFont(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Icon").harborFont(.subheadline, weight: .medium)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 9) {
                    ForEach(icons, id: \.self) { symbol in
                        Button { icon = symbol } label: {
                            Image(systemName: symbol).font(.system(size: 21))
                                .frame(maxWidth: .infinity).frame(height: 39)
                                .foregroundStyle(icon == symbol ? previewFolder.displayColor : .secondary)
                                .background(icon == symbol ? previewFolder.displayColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(icon == symbol ? previewFolder.displayColor : .clear) }
                        }.buttonStyle(.plain).accessibilityLabel("\(symbol) icon").accessibilityAddTraits(icon == symbol ? .isSelected : [])
                    }
                }
                HStack(spacing: 13) {
                    Text("Color").harborFont(.subheadline, weight: .medium)
                    ForEach(colors, id: \.self) { hex in
                        Button { colorHex = hex } label: {
                            Circle().fill(DownloadFolder(name: "", path: "", colorHex: hex).displayColor)
                                .frame(width: 23, height: 23)
                                .overlay { if colorHex == hex { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) } }
                        }.buttonStyle(.plain).accessibilityLabel("Folder color \(hex)").accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                    }
                }
            }
            if let failure { Text(failure).harborFont(.callout).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save Shortcut") { save() }.buttonStyle(.borderedProminent)
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
            }
        }
        .padding(25).frame(width: 580)
        .background(appearance.backgroundColor)
        .interactiveDismissDisabled(saving)
        .sheetCloseButton(disabled: saving)
        .task {
            name = folder?.name ?? ""
            path = folder?.path ?? store.settings.destinationDirectory
            icon = folder?.icon ?? "folder"
            colorHex = folder?.colorHex ?? "22A86B"
        }
    }

    private var previewFolder: DownloadFolder { DownloadFolder(name: name, path: path, icon: icon, colorHex: colorHex) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose or Create Folder"
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: path)
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { name = url.lastPathComponent }
        }
    }

    private func save() {
        saving = true
        failure = nil
        let updated = DownloadFolder(id: folder?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), path: path, icon: icon, colorHex: colorHex)
        Task {
            defer { saving = false }
            do {
                try await store.saveFolder(updated)
                onSaved?(updated)
                dismiss()
            } catch { failure = error.localizedDescription }
        }
    }
}
