import AppKit
import HarborCore
import SwiftUI

struct HarborSettingsView: View {
    let store: DownloadStore
    @AppAppearance private var appearance

    var body: some View {
        TabView(selection: Binding(get: { appearance.settingsTab }, set: { appearance.settingsTab = $0 })) {
            GeneralSettingsView(store: store)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            MediaToolsSettingsView(store: store)
                .tabItem { Label("Media Tools", systemImage: "wrench.and.screwdriver") }
                .tag(SettingsTab.mediaTools)
            ChromeCompanionSetupView()
                .tabItem { Label("Chrome", systemImage: "puzzlepiece.extension") }
                .tag(SettingsTab.chrome)
        }
        .padding(.top, 8)
        .frame(minWidth: 660, idealWidth: 720, minHeight: 600, idealHeight: 680)
        .background(appearance.backgroundColor)
        .background(NativeWindowChrome())
        .alert(item: Binding(get: { store.actionFailure }, set: { store.actionFailure = $0 })) { failure in
            Alert(title: Text(failure.title), message: Text(failure.message), dismissButton: .default(Text("OK")))
        }
    }
}

private struct GeneralSettingsView: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    @ViewState private var destination = ""
    @ViewState private var maxConcurrent = 3
    @ViewState private var proxy = ""
    @ViewState private var saving = false
    @ViewState private var dirty = false
    @ViewState private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Save downloads to") {
                        HStack {
                            Text(Format.folder(destination)).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .trailing)
                            Button("Choose…") { chooseFolder() }
                        }
                    }
                    Stepper(value: $maxConcurrent, in: 1...8) {
                        LabeledContent("Simultaneous downloads", value: "\(maxConcurrent)")
                    }
                    Text("Changes apply to new or restarted transfers.").harborFont(.caption).foregroundStyle(.secondary)
                } header: { Label("Downloads", systemImage: "arrow.down.circle") }

                Section {
                    TextField("Proxy URL", text: $proxy, prompt: Text("http://127.0.0.1:8080"))
                    Text("Leave blank for a direct connection. Media downloads support unauthenticated HTTP(S) and SOCKS proxy URLs. Proxy routing for direct file downloads is unavailable in this build.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                } header: { Label("Proxy", systemImage: "network") }
            }
            .formStyle(.grouped)
            .scrollContentBackground(appearance.isCustom ? .hidden : .visible)
            if let error = validationError {
                Text(error).foregroundStyle(.red).harborFont(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 23).padding(.bottom, 12)
            }
            Divider()
            HStack {
                Text(dirty ? "Unsaved changes" : "Settings are up to date")
                    .harborFont(.caption).foregroundStyle(.secondary)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save Changes") { save() }
                    .buttonStyle(.borderedProminent).disabled(!dirty || saving)
                    .keyboardShortcut("s", modifiers: [.command])
            }.padding(16)
        }
        .onAppear { if !dirty { load(store.settings) } }
        .onChange(of: store.settings) { _, value in if !dirty { load(value) } }
        .onChange(of: destination) { _, _ in updateDirty() }
        .onChange(of: maxConcurrent) { _, _ in updateDirty() }
        .onChange(of: proxy) { _, _ in updateDirty() }
    }

    private func load(_ value: DownloadSettings) {
        destination = value.destinationDirectory
        maxConcurrent = value.maxConcurrent
        proxy = value.proxyURL ?? ""
        dirty = false
    }

    private func updateDirty() {
        dirty = destination != store.settings.destinationDirectory || maxConcurrent != store.settings.maxConcurrent || proxy != (store.settings.proxyURL ?? "")
        validationError = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: destination)
        if panel.runModal() == .OK, let url = panel.url { destination = url.path }
    }

    private func save() {
        let trimmedProxy = proxy.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProxy.isEmpty {
            guard let url = URLComponents(string: trimmedProxy),
                  let scheme = url.scheme?.lowercased(), ["http", "https", "socks4", "socks4a", "socks5", "socks5h"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                validationError = "Enter a complete proxy URL, such as http://127.0.0.1:8080 or socks5h://127.0.0.1:1080."
                return
            }
        }
        saving = true
        Task {
            defer { saving = false }
            if await store.saveSettings(DownloadSettings(destinationDirectory: destination, maxConcurrent: maxConcurrent, proxyURL: trimmedProxy.isEmpty ? nil : trimmedProxy)) {
                proxy = trimmedProxy
                dirty = false
            }
        }
    }
}

private struct MediaToolsSettingsView: View {
    let store: DownloadStore
    @AppAppearance private var appearance
    var body: some View {
        Form {
            Section {
                if store.capabilities.isEmpty {
                    Text(store.connected ? "Checking installed tools…" : "Connect to the download service to check available tools.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.capabilities) { capability in
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: capability.available ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(capability.available ? .green : .orange)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(capability.name).fontWeight(.medium)
                            Text(capability.detail).harborFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(capability.name): \(capability.available ? "available" : "unavailable"). \(capability.detail)")
                }
            } header: { Label("Available capabilities", systemImage: "wrench.and.screwdriver") }
            Section {
                HStack {
                    Label(store.connectionLabel, systemImage: store.connected ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh Tools", systemImage: "arrow.clockwise") { Task { await store.reconnect() } }
                }
                if let error = store.connectionError { Text(error).harborFont(.caption).foregroundStyle(.red).textSelection(.enabled) }
            } header: { Label("Download service", systemImage: "externaldrive.connected.to.line.below") }
        }
        .formStyle(.grouped)
        .scrollContentBackground(appearance.isCustom ? .hidden : .visible)
    }
}
