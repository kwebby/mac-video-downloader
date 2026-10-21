import Foundation
import HarborCore

enum OptionValidation {
    static func options(_ value: DownloadOptions?) throws -> DownloadOptions {
        var result = value ?? DownloadOptions()
        guard ["auto", "mp4", "mkv", "webm"].contains(result.container),
              ["original", "m4a", "mp3", "opus", "wav", "flac"].contains(result.audioFormat) else {
            throw EngineError.invalid("Choose a supported output container and audio format.")
        }
        if let id = result.formatID {
            guard safeFormatID(id) else { throw EngineError.invalid("Choose an actual source format from the preview.") }
        }
        if result.mode == .audioOnly {
            guard result.container == "auto" else { throw EngineError.invalid("Audio-only output uses the selected audio format; set the video container to Auto.") }
            if let bitrate = result.audioBitrateKbps {
                guard ["mp3", "m4a", "opus"].contains(result.audioFormat), (64...320).contains(bitrate) else {
                    throw EngineError.invalid("Audio bitrate must be 64–320 Kbps and requires explicit MP3, M4A or Opus conversion. Original and lossless audio preserve their source bitrate.")
                }
            }
        } else {
            guard result.audioFormat == "original", result.audioBitrateKbps == nil else {
                throw EngineError.invalid("Audio conversion options apply to Audio Only downloads.")
            }
        }
        if result.formatID?.isEmpty == true { result.formatID = nil }
        return result
    }

    static func safeFormatID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil
    }

    static func selectedFormat(options: DownloadOptions, quality: VideoQuality, preview: MediaPreview?) throws -> MediaFormatChoice? {
        guard let id = options.formatID else { return nil }
        guard let choice = preview?.formats.first(where: { $0.id == id }) else {
            throw EngineError.invalid("This source format is unavailable. Resolve the video again and choose an available format.")
        }
        switch options.mode {
        case .audioOnly: guard choice.hasAudio else { throw EngineError.invalid("Choose a source format that contains audio.") }
        case .videoOnly, .videoWithAudio: guard choice.hasVideo else { throw EngineError.invalid("Choose a source format that contains video.") }
        }
        if let height = quality.height, height != choice.height {
            throw EngineError.invalid("The selected quality conflicts with the exact source format. Use its actual resolution.")
        }
        return choice
    }

    static func requiresMedia(_ options: DownloadOptions) -> Bool {
        options.mode != .videoWithAudio || options.formatID != nil || options.container != "auto"
    }

    static func destination(_ path: String) throws -> String {
        try URLValidation.settings(DownloadSettings(destinationDirectory: path)).destinationDirectory
    }

    static func folder(_ proposed: DownloadFolder) throws -> DownloadFolder {
        var folder = proposed
        folder.name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.name.isEmpty, folder.name.count <= 80,
              !folder.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              folder.icon.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9.]{0,79}$"#, options: .regularExpression) != nil else {
            throw EngineError.invalid("Use a folder name up to 80 characters and a valid system symbol name.")
        }
        folder.path = try destination(folder.path)
        if let color = folder.colorHex {
            guard color.range(of: #"^#?[A-Fa-f0-9]{6}$"#, options: .regularExpression) != nil else { throw EngineError.invalid("Folder colors must use six hexadecimal RGB digits.") }
            folder.colorHex = "#" + color.replacingOccurrences(of: "#", with: "").uppercased()
        }
        return folder
    }
}
