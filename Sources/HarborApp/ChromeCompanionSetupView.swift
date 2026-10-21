import AppKit
import SwiftUI

struct ChromeCompanionSetupView: View {
    var showsDoneButton = false
    @AppAppearance private var appearance
    @Environment(\.dismiss) private var dismiss
    @ViewState private var setup = ChromeCompanionSetup.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                ChromeCompanionIcon(size: 40)
                VStack(alignment: .leading, spacing: 5) {
                    Text(setup.isConfigured ? "Chrome is connected" : "Connect Chrome")
                        .harborFont(.title2)
                    Text("Download videos from the page you’re watching.")
                        .harborFont(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: showsDoneButton ? 25 : 0)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    connectionStatus

                    setupStep(1, title: "Prepare the companion", complete: setup.isPrepared) {
                        Text("MVD saves the extension in a permanent folder and connects it to this app.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button(setup.isPrepared ? "Prepare Again…" : "Prepare Chrome Companion…") {
                                setup.prepareInstallation()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(setup.isBusy || !setup.chromeAvailable)
                            if setup.isBusy { ProgressView().controlSize(.small) }
                        }
                        if !setup.chromeAvailable {
                            HStack(spacing: 6) {
                                Text("Install Google Chrome, then check the connection again.")
                                    .foregroundStyle(.secondary)
                                Link("Get Chrome", destination: URL(string: "https://www.google.com/chrome/")!)
                            }
                            .harborFont(.caption)
                        }
                    }

                    setupStep(2, title: "Add MVD in Chrome", complete: setup.isConfigured) {
                        Text("Open Chrome’s extensions page and turn on Developer mode. Click Load unpacked, then choose the MVD companion folder.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Open Chrome Extensions", systemImage: "arrow.up.right") {
                                setup.openChromeExtensions()
                            }
                            .disabled(setup.isBusy || !setup.chromeAvailable)
                            Button("Show Companion Folder", systemImage: "folder") {
                                setup.revealExtensionFolder()
                            }
                            .disabled(setup.isBusy || !setup.isPrepared)
                        }
                        Text("Chrome requires you to complete this step yourself.")
                            .harborFont(.caption).foregroundStyle(.secondary)
                    }

                    setupStep(3, title: "Verify the connection", complete: setup.isConfigured) {
                        Text("Enable MVD Companion, then open its popup from Chrome’s extensions menu. A green tick appears when the extension connects to this app.")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Check Connection", systemImage: "arrow.clockwise") {
                                setup.recheck()
                            }
                            .disabled(setup.isBusy)
                            if setup.isConfigured {
                                Label("Installed and configured", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .harborFont(.callout)
                            }
                        }
                    }
                }
                .harborFont(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            if showsDoneButton {
                Divider()
                HStack {
                    Text("You can return here anytime from Connect Chrome.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(16)
            }
        }
        .background(appearance.backgroundColor)
        .task { setup.recheck() }
    }

    private var connectionStatus: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(setup.statusTitle).harborFont(.headline)
                Text(setup.statusDetail)
                    .harborFont(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = setup.errorMessage {
                    Text(message).harborFont(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var statusSymbol: String {
        switch setup.status {
        case .connected: "checkmark.circle.fill"
        case .awaitingConnection: "clock"
        case .needsRepair, .unavailable: "exclamationmark.circle"
        case .notConfigured: "puzzlepiece.extension"
        }
    }

    private var statusColor: Color {
        switch setup.status {
        case .connected: .green
        case .needsRepair, .unavailable: .orange
        case .notConfigured, .awaitingConnection: .secondary
        }
    }

    private func setupStep<Content: View>(_ number: Int, title: String, complete: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 13) {
            ZStack {
                Circle().fill(complete ? Color.green.opacity(0.12) : Color.secondary.opacity(0.12))
                if complete {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").harborFont(.callout, weight: .semibold).foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityLabel(complete ? "Step \(number) complete" : "Step \(number)")
            VStack(alignment: .leading, spacing: 10) {
                Text(title).harborFont(.headline).padding(.top, 3)
                content()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ChromeCompanionIcon: View {
    let size: CGFloat
    private static let chromeIcon: NSImage? = {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }()

    var body: some View {
        Group {
            if let icon = Self.chromeIcon {
                Image(nsImage: icon).resizable().interpolation(.high).accessibilityHidden(true)
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .resizable().scaledToFit().foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }
}
