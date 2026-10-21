import SwiftUI

struct AppearanceMenu: View {
    @AppAppearance private var appearance
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Menu {
            ForEach(AppearanceMode.allCases) { mode in
                Button {
                    appearance.mode = mode
                } label: {
                    Label(mode.title + (appearance.mode == mode ? " ✓" : ""), systemImage: mode.symbol)
                }
            }
            Divider()
            Button("Customize Appearance…", systemImage: "slider.horizontal.3") {
                appearance.settingsTab = .appearance
                openSettings()
            }
        } label: {
            Label("Appearance", systemImage: appearance.mode.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .labelStyle(.iconOnly)
        .fixedSize()
        .frame(width: 28, height: 28)
        .help("Appearance: \(appearance.mode.title). Choose colors and fonts.")
        .accessibilityIdentifier("appearanceMenu")
    }
}

struct AppearanceSettingsView: View {
    @AppAppearance private var appearance
    @ViewState private var fontSearch = ""

    private var filteredFonts: [String] {
        appearance.fontFamilies.filter {
            fontSearch.isEmpty || $0.localizedStandardContains(fontSearch) || $0 == appearance.fontFamily
        }
    }

    var body: some View {
        @Bindable var model = appearance
        Form {
            Section {
                Picker("Appearance", selection: $model.mode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearanceModePicker")
                if appearance.isCustom {
                    Picker("Base", selection: $model.customBase) {
                        ForEach(AppearanceBase.allCases) { base in Text(base.title).tag(base) }
                    }.pickerStyle(.segmented)
                    ColorPicker("Accent color", selection: $model.customAccent, supportsOpacity: false)
                        .accessibilityIdentifier("accentColorPicker")
                    ColorPicker("Background color", selection: $model.customBackground, supportsOpacity: false)
                        .accessibilityIdentifier("backgroundColorPicker")
                    Text("Colors are toned for readable text. Sidebar and detail surfaces follow your background hue.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                } else {
                    Text(appearance.mode == .system ? "Follows your Mac’s light or dark appearance." : "Uses MVD’s light or dark palette. Choose Custom to set your own colors.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
            } header: { Label("Theme", systemImage: "circle.lefthalf.filled") }

            Section {
                TextField("Find an installed font", text: $fontSearch, prompt: Text("Search font families…"))
                    .accessibilityLabel("Search installed font families")
                Picker("Font family", selection: $model.fontFamily) {
                    Text("System").tag("System")
                    ForEach(filteredFonts, id: \.self) { family in Text(family).tag(family) }
                }
                .accessibilityIdentifier("fontFamilyPicker")
                LabeledContent("Text size") {
                    HStack(spacing: 12) {
                        Slider(value: $model.fontSize, in: 11...18, step: 1)
                            .frame(maxWidth: 220)
                            .accessibilityLabel("Interface text size")
                        Text("\(Int(appearance.fontSize)) pt").monospacedDigit().frame(width: 45, alignment: .trailing)
                    }
                }
                Picker("Download rows", selection: $model.density) {
                    ForEach(RowDensity.allCases) { density in Text(density.title).tag(density) }
                }.pickerStyle(.segmented)
            } header: { Label("Typography & spacing", systemImage: "textformat") }

            Section {
                HStack(alignment: .top, spacing: 15) {
                    Image(systemName: "film").font(.system(size: 27, weight: .light)).foregroundStyle(appearance.tintColor)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Make room for what matters.").harborFont(.headline)
                        Text("Your downloads, organized and easy to find.").harborFont(.body)
                        Label("Video page · ready to download", systemImage: "link")
                            .harborFont(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(appearance.surfaceColor)
                Text("Changes apply immediately and are saved on this Mac.").harborFont(.caption).foregroundStyle(.secondary)
            } header: { Label("Live preview", systemImage: "eye") }

            HStack {
                Spacer()
                Button("Reset Appearance", systemImage: "arrow.counterclockwise") {
                    appearance.reset()
                    fontSearch = ""
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(appearance.isCustom ? .hidden : .visible)
    }
}
