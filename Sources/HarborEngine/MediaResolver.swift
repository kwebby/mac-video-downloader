import Foundation
import HarborCore

enum MediaQuality {
    /// Canonicalize the complete value. Client-provided labels and IDs never
    /// become format expressions or unchecked persistent metadata.
    static func validate(_ proposed: VideoQuality?) throws -> VideoQuality {
        guard let proposed else { return .best }
        if proposed.id == "best", proposed.height == nil { return .best }
        guard let height = proposed.height, (1...8_640).contains(height), proposed.id == "\(height)p" else {
            throw EngineError.invalid("Choose Best available or a resolution returned by the media preview.")
        }
        return VideoQuality(id: "\(height)p", label: "\(height)p", height: height)
    }
}

enum MediaResolver {
    static func resolve(source: URL, directory: URL, proxy: String?, tools: ProviderTools, control: TransferControl) async throws -> MediaPreview {
        guard let executable = tools.downloader else {
            throw EngineError.unavailable("Video previews need yt-dlp. Run Scripts/setup-tools.sh, then restart Harbor.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var arguments = [
            "--ignore-config", "--no-plugin-dirs", "--no-update", "--no-cache-dir", "--no-playlist",
            "--dump-single-json", "--skip-download", "--no-warnings", "--quiet", "--no-colors",
            "--socket-timeout", "10", "--retries", "1", "--extractor-retries", "1",
            "--proxy", proxy ?? "", "--no-js-runtimes"
        ]
        if let ffmpeg = tools.ffmpeg { arguments += ["--ffmpeg-location", ffmpeg] }
        if let deno = tools.deno { arguments += ["--js-runtimes", "deno:\(deno)"] }
        arguments += ["--", source.absoluteString]
        return try await Task.detached(priority: .utility) {
            let deadline = Date().addingTimeInterval(32)
            var metadata: Data?
            var diagnostic = ""
            let status = try SafeSubprocess.run(executable: executable, arguments: arguments, directory: directory, control: control, maximumOutputBytes: 8 * 1_048_576, maximumLineBytes: 8 * 1_048_576, timeout: 27) { line in
                if line.hasPrefix("{") { metadata = Data(line.utf8) }
                else if line.contains("ERROR:") { diagnostic = ErrorRedactor.message(line) }
            }
            if control.isStopped { throw EngineError.cancelled }
            guard status == 0, let metadata else {
                throw EngineError.transfer("Could not resolve this video. " + (diagnostic.isEmpty ? "The provider could not provide playable media information." : diagnostic))
            }
            let enriched = try MediaMetadataProbe.enrich(metadata, directory: directory, proxy: proxy, tools: tools, control: control, deadline: deadline)
            return try parse(enriched)
        }.value
    }

    static func parse(_ data: Data) throws -> MediaPreview {
        guard let metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any], metadata["entries"] == nil else {
            throw EngineError.invalid("Preview one video at a time. Paste multiple video URLs into the bulk review list.")
        }
        if (metadata["has_drm"] as? NSNumber)?.boolValue == true {
            throw EngineError.unavailable("DRM-protected media is not supported.")
        }
        let title = String((metadata["title"] as? String ?? "Video").prefix(400))
        let thumbnail = (metadata["thumbnail"] as? String).flatMap { raw -> String? in
            guard raw.utf8.count <= 8_192, let url = try? URLValidation.source(raw) else { return nil }
            return url.absoluteString
        }
        let rawDuration = (metadata["duration"] as? NSNumber)?.doubleValue
        let duration = rawDuration.flatMap { $0.isFinite && $0 >= 0 && $0 <= 315_360_000 ? $0 : nil }
        let formats = metadata["formats"] as? [[String: Any]] ?? [metadata]
        let heights = Set(formats.compactMap { format -> Int? in
            guard (format["has_drm"] as? NSNumber)?.boolValue != true,
                  (format["_mvd_probe_dimensions"] as? Bool) != true,
                  let value = format["height"] as? NSNumber else { return nil }
            let codec = format["vcodec"] as? String
            guard codec != "none", codec != "images" else { return nil }
            let ext = (format["video_ext"] as? String ?? format["ext"] as? String ?? "").lowercased()
            guard !["jpg", "jpeg", "png", "webp", "gif", "svg", "mhtml"].contains(ext), format["protocol"] as? String != "mhtml" else { return nil }
            // Generic HLS/DASH manifests can report real RESOLUTION dimensions
            // without naming codecs. Explicit dimensions still establish a
            // video rendition; an audio-only vcodec=none above never does.
            // Probed dimensions appear on exact format rows only. yt-dlp's
            // height selector cannot match a height its extractor did not report.
            if codec == nil, ((format["width"] as? NSNumber)?.doubleValue ?? 0) <= 0 { return nil }
            let height = value.doubleValue
            guard height.isFinite, height.rounded() == height, (1...8_640).contains(height) else { return nil }
            return Int(height)
        })
        let qualities: [VideoQuality] = [.best] + heights.sorted(by: >).map { VideoQuality(id: "\($0)p", label: "\($0)p", height: $0) }
        var seen: Set<String> = []
        let choices = formats.compactMap { format -> MediaFormatChoice? in
            guard (format["has_drm"] as? NSNumber)?.boolValue != true, let id = format["format_id"] as? String,
                  OptionValidation.safeFormatID(id), seen.insert(id).inserted else { return nil }
            func text(_ key: String) -> String? {
                guard let value = format[key] as? String, value != "none", value != "unknown", !value.isEmpty else { return nil }
                return String(value.prefix(64))
            }
            func number(_ key: String, maximum: Double = 1_000_000) -> Double? {
                guard let value = (format[key] as? NSNumber)?.doubleValue, value.isFinite, value > 0, value <= maximum else { return nil }
                return value
            }
            let height = number("height", maximum: 8_640).map(Int.init)
            let width = number("width", maximum: 16_384).map(Int.init)
            let video = text("vcodec"), audio = text("acodec")
            let ext = text("ext")
            guard video != "images", !["jpg", "jpeg", "png", "webp", "gif", "svg", "mhtml"].contains(ext ?? ""), format["protocol"] as? String != "mhtml" else { return nil }
            let hasVideo = video != nil || (format["vcodec"] as? String != "none" && height != nil && width != nil)
            let hasAudio = audio != nil || (format["acodec"] as? String != "none" && text("audio_ext") != nil)
            guard hasVideo || hasAudio else { return nil }
            let vbr = number("vbr") ?? (hasVideo && !hasAudio ? number("tbr") : nil)
            let abr = number("abr") ?? (hasAudio && !hasVideo ? number("tbr") : nil)
            var parts: [String] = []
            if let height { parts.append("\(height)p") }
            else { parts.append(hasVideo ? "Video" : "Audio") }
            if let ext { parts.append(ext.uppercased()) }
            if let video { parts.append(video) }
            if let audio { parts.append(audio) }
            if let bitrate = hasVideo ? vbr : abr { parts.append("\(Int(bitrate.rounded())) Kbps") }
            else if let total = number("tbr") { parts.append("\(Int(total.rounded())) Kbps total") }
            let size = number("filesize", maximum: Double(Int64.max / 2)).map(Int64.init)
            return MediaFormatChoice(id: id, label: String(parts.joined(separator: " · ").prefix(240)), height: height, width: width, fps: number("fps", maximum: 1_000), videoCodec: video, audioCodec: audio, container: ext, videoBitrateKbps: vbr, audioBitrateKbps: abr, fileSize: size, hasVideo: hasVideo, hasAudio: hasAudio)
        }
        return MediaPreview(title: title, thumbnailURL: thumbnail, duration: duration, qualities: qualities, formats: Array(choices.prefix(512)))
    }
}
