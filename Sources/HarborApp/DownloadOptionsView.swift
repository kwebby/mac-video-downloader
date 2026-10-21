import AppKit
import HarborCore
import SwiftUI

extension MediaMode {
    var title: String {
        switch self {
        case .videoWithAudio: "Video + Audio"
        case .videoOnly: "Silent Video"
        case .audioOnly: "Audio Only"
        }
    }
    var symbol: String {
        switch self {
        case .videoWithAudio: "play.rectangle"
        case .videoOnly: "speaker.slash"
        case .audioOnly: "music.note"
        }
    }
}

extension MediaPreview {
    var reportsAudioOnly: Bool { !formats.isEmpty && formats.contains(where: \.hasAudio) && !formats.contains(where: \.hasVideo) }
}

struct DownloadSetup: Equatable {
    var qualityID = VideoQuality.best.id
    var options = DownloadOptions()
    var destinationDirectory = ""
    var folderID: UUID?

    func quality(in preview: MediaPreview) -> VideoQuality? {
        guard !preview.isDirectFile, options.mode != .audioOnly else { return nil }
        return preview.qualities.first(where: { $0.id == qualityID })
    }
}

struct DownloadOptionsView: View {
    let store: DownloadStore
    let preview: MediaPreview
    @Binding var setup: DownloadSetup
    var showsDestination = true
    var sourceURL: String? = nil
    @AppAppearance private var appearance

    private var availableFormats: [MediaFormatChoice] {
        let height = preview.qualities.first(where: { $0.id == setup.qualityID })?.height
        return preview.formats.filter { format in
            if setup.options.mode == .audioOnly { return format.hasAudio }
            return format.hasVideo && (height == nil || format.height == height)
        }
    }
    private var selectedFormat: MediaFormatChoice? { preview.formats.first(where: { $0.id == setup.options.formatID }) }
    private var usesLossyAudio: Bool { ["m4a", "mp3", "opus"].contains(setup.options.audioFormat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if !preview.isDirectFile {
                HStack(spacing: 8) {
                    ForEach(preview.reportsAudioOnly ? [.audioOnly] : MediaMode.allCases, id: \.self) { mode in modeButton(mode) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Download output mode")
                .accessibilityIdentifier("mediaModePicker")
                if preview.reportsAudioOnly {
                    Text("This source reports audio only. Keep the original audio or choose a conversion format below.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                } else if let sourceURL, DownloadStore.isRecognizedMediaURL(sourceURL), preview.qualities.filter({ $0.height != nil }).count <= 1 {
                    Text("This direct media link reports only its original video representation. Additional resolutions appear only when the source offers them.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
                if setup.options.mode != .audioOnly {
                    optionRow("Quality", symbol: "slider.horizontal.3") {
                        Picker("Video quality", selection: $setup.qualityID) {
                            ForEach(preview.qualities) { quality in Text(quality.label).tag(quality.id) }
                        }
                        .labelsHidden().disabled(setup.options.formatID != nil)
                        .accessibilityIdentifier("videoQualityPicker")
                    }
                }
                optionRow("Source format", symbol: "film.stack") {
                    Picker("Source format", selection: Binding(
                        get: { setup.options.formatID ?? "" },
                        set: { id in selectFormat(id) }
                    )) {
                        Text("Automatic").tag("")
                        ForEach(availableFormats) { format in Text(format.label).tag(format.id) }
                    }.labelsHidden().accessibilityIdentifier("sourceFormatPicker")
                }
                if let selectedFormat {
                    Text(selectedFormat.metadataDescription)
                        .harborFont(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if setup.options.mode != .audioOnly {
                        Text("The selected source format fixes the video resolution. Choose Automatic to change quality.")
                            .harborFont(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(availableFormats.isEmpty ? "No individual format details were reported. Automatic uses the available source streams." : "Automatic chooses compatible source streams for your selection. Choose a format to inspect its codec and bitrate.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
                if setup.options.mode == .audioOnly {
                    audioOptions
                } else {
                    optionRow("Save as", symbol: "doc.badge.gearshape") {
                        Picker("Video container", selection: $setup.options.container) {
                            Text("Auto · original container").tag("auto")
                            Text("MP4").tag("mp4")
                            Text("MKV").tag("mkv")
                            Text("WebM").tag("webm")
                        }.labelsHidden().accessibilityIdentifier("videoContainerPicker")
                    }
                    Text(setup.options.mode == .videoOnly ? "The saved video has no audio track. Container compatibility is checked before the transfer starts." : "Source audio is kept or merged with the selected video. Changing container remuxes compatible codecs without increasing quality.")
                        .harborFont(.caption).foregroundStyle(.secondary)
                }
                Divider()
            }
            Toggle(isOn: $setup.options.accelerated) {
                Label("Accelerate transfer", systemImage: "bolt.fill")
            }
            .toggleStyle(.switch)
            .help("Use parallel file ranges or media fragments when supported. Performance depends on the source and your network.")
            Text("Uses parallel file ranges or media fragments where supported. Speed depends on the source and your network.")
                .harborFont(.caption).foregroundStyle(.secondary)
            if showsDestination {
                Divider()
                DestinationPicker(store: store, destination: $setup.destinationDirectory, folderID: $setup.folderID)
            }
        }
        .padding(15)
        .background(appearance.surfaceColor, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary) }
        .onAppear {
            if preview.reportsAudioOnly, setup.options.mode != .audioOnly { selectMode(.audioOnly) }
        }
    }

    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionRow("Audio format", symbol: "waveform") {
                Picker("Audio format", selection: Binding(get: { setup.options.audioFormat }, set: { selectAudioFormat($0) })) {
                    Text("Original · no conversion").tag("original")
                    Text("M4A / AAC").tag("m4a")
                    Text("MP3").tag("mp3")
                    Text("Opus").tag("opus")
                    Text("WAV").tag("wav")
                    Text("FLAC").tag("flac")
                }.labelsHidden().accessibilityIdentifier("audioFormatPicker")
            }
            optionRow("Output bitrate", symbol: "waveform.path") {
                Picker("Audio output bitrate", selection: Binding(
                    get: { usesLossyAudio ? (setup.options.audioBitrateKbps ?? 192) : 0 },
                    set: { setup.options.audioBitrateKbps = $0 }
                )) {
                    if usesLossyAudio {
                        ForEach([64, 96, 128, 160, 192, 256, 320], id: \.self) { value in Text("\(value) kbps").tag(value) }
                    } else { Text(setup.options.audioFormat == "original" ? "Original source bitrate" : "Lossless · automatic").tag(0) }
                }.labelsHidden().disabled(!usesLossyAudio)
            }
            Text(setup.options.audioFormat == "original" ? "Keeps the original audio stream without conversion. Output bitrate is determined by the source." : (usesLossyAudio ? "Converts the source audio to the chosen format and bitrate. A higher bitrate cannot restore detail missing from the source." : "Converts to a lossless output format. Bitrate is determined by the audio content; conversion cannot restore missing source detail."))
                .harborFont(.caption).foregroundStyle(.secondary)
        }
    }

    private func optionRow<Content: View>(_ label: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Label(label, systemImage: symbol).frame(width: 140, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder private func modeButton(_ mode: MediaMode) -> some View {
        if setup.options.mode == mode {
            modeChoice(mode).buttonStyle(.borderedProminent)
        } else {
            modeChoice(mode).buttonStyle(.bordered)
        }
    }

    private func modeChoice(_ mode: MediaMode) -> some View {
        Button { selectMode(mode) } label: {
            Label(mode.title, systemImage: mode.symbol).frame(maxWidth: .infinity)
        }
        .controlSize(.large)
        .accessibilityIdentifier("mediaMode_\(mode.rawValue)")
        .accessibilityAddTraits(setup.options.mode == mode ? .isSelected : [])
        .accessibilityValue(setup.options.mode == mode ? "Selected" : "Not selected")
    }

    private func selectFormat(_ id: String) {
        var updated = setup
        updated.options.formatID = id.isEmpty ? nil : id
        if updated.options.mode != .audioOnly, let height = preview.formats.first(where: { $0.id == id })?.height,
           let quality = preview.qualities.first(where: { $0.height == height }) { updated.qualityID = quality.id }
        setup = updated
    }

    private func selectMode(_ mode: MediaMode) {
        var updated = setup
        updated.options.mode = mode
        updated.options.formatID = nil
        if mode == .audioOnly { updated.options.container = "auto" }
        else { updated.options.audioFormat = "original"; updated.options.audioBitrateKbps = nil }
        setup = updated
    }

    private func selectAudioFormat(_ format: String) {
        var updated = setup
        updated.options.audioFormat = format
        updated.options.audioBitrateKbps = ["m4a", "mp3", "opus"].contains(format) ? (updated.options.audioBitrateKbps ?? 192) : nil
        setup = updated
    }
}

extension MediaFormatChoice {
    var metadataDescription: String {
        var parts: [String] = []
        if let container { parts.append(container.uppercased()) }
        if let width, let height { parts.append("\(width) × \(height)") }
        else if let height { parts.append("\(height)p") }
        if let fps, fps.isFinite, fps > 0 { parts.append("\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps") }
        if let videoCodec, videoCodec != "none" { parts.append("Video: \(videoCodec)") }
        if let videoBitrateKbps, videoBitrateKbps.isFinite, videoBitrateKbps > 0 { parts.append("\(videoBitrateKbps.formatted(.number.precision(.fractionLength(0)))) kbps video") }
        if let audioCodec, audioCodec != "none" { parts.append("Audio: \(audioCodec)") }
        if let audioBitrateKbps, audioBitrateKbps.isFinite, audioBitrateKbps > 0 { parts.append("\(audioBitrateKbps.formatted(.number.precision(.fractionLength(0)))) kbps audio") }
        if let fileSize { parts.append(Format.bytes(fileSize)) }
        if !hasAudio { parts.append("No source audio") }
        return parts.isEmpty ? "The source did not report codec or bitrate details for this format." : parts.joined(separator: " · ")
    }
}

struct MVDMark: View {
    var size: CGFloat = 34
    var body: some View {
        Group {
            if let image = NSImage(named: "MVDMark") ?? Bundle.main.url(forResource: "MVDMark", withExtension: "png").flatMap({ NSImage(contentsOf: $0) }) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "arrow.down.to.line.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(Color.green)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("MVD, Mac Video Downloader")
    }
}
