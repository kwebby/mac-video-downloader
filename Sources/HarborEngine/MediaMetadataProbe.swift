import Foundation
import HarborCore

/// Some extractors return playable progressive files without identifying their
/// streams. Inspect a small, bounded set instead of dropping those source rows
/// or claiming that an MP4 extension establishes audio/video capabilities.
enum MediaMetadataProbe {
    static func enrich(_ data: Data, directory: URL, proxy: String?, tools: ProviderTools, control: TransferControl, deadline: Date) throws -> Data {
        // FFprobe must never bypass a user's configured media proxy.
        guard proxy == nil, let ffmpeg = tools.ffmpeg,
              var metadata = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              metadata["entries"] == nil,
              (metadata["has_drm"] as? NSNumber)?.boolValue != true else { return data }
        let hasFormatList = metadata["formats"] is [[String: Any]]
        var formats = metadata["formats"] as? [[String: Any]] ?? [metadata]
        let executable = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { return data }
        var attempted = 0
        var results: [String: Data] = [:]
        for index in formats.indices {
            if control.isStopped { throw EngineError.cancelled }
            guard needsProbe(formats[index]), let raw = formats[index]["url"] as? String else { continue }
            if let result = results[raw] { formats[index] = applying(result, to: formats[index]); continue }
            guard attempted < 4, deadline.timeIntervalSinceNow > 0.2 else { break }
            attempted += 1
            guard (try? PublicNetworkPolicy.validate(raw, allowVideoProviders: true)) != nil else { continue }
            var output = ""
            // Disable playlists and local-file protocols: only progressive
            // container demuxers may inspect this HTTP(S) source. Each worker
            // also has a hard wall-clock deadline and bounded stdout/probing.
            let arguments = ["-v", "error", "-protocol_whitelist", "http,https,tcp,tls",
                             "-format_whitelist", "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,mp3,aac,flac,ogg,wav",
                             "-rw_timeout", "2500000", "-probesize", "1048576", "-analyzeduration", "1000000",
                             "-show_entries", "stream=codec_type,codec_name,width,height,avg_frame_rate,bit_rate:stream_disposition=attached_pic:format=duration",
                             "-of", "json", raw]
            let status = try? SafeSubprocess.run(executable: executable, arguments: arguments, directory: directory, control: control,
                                                maximumOutputBytes: 65_536, maximumLineBytes: 16_384,
                                                timeout: min(3, max(0.1, deadline.timeIntervalSinceNow))) { output += $0 + "\n" }
            if control.isStopped { throw EngineError.cancelled }
            guard status == 0 else { continue }
            let result = Data(output.utf8)
            results[raw] = result
            formats[index] = applying(result, to: formats[index])
        }
        if hasFormatList { metadata["formats"] = formats }
        else if let format = formats.first { metadata = format }
        return try JSONSerialization.data(withJSONObject: metadata)
    }

    static func needsProbe(_ format: [String: Any]) -> Bool {
        guard (format["has_drm"] as? NSNumber)?.boolValue != true,
              let id = format["format_id"] as? String, OptionValidation.safeFormatID(id),
              format["vcodec"] as? String != "images",
              let raw = format["url"] as? String, let url = try? URLValidation.source(raw),
              ["http", "https"].contains(format["protocol"] as? String ?? url.scheme ?? ""),
              ["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "aac", "ogg", "opus", "flac", "wav"].contains((format["ext"] as? String ?? "").lowercased()) else { return false }
        return ["vcodec", "acodec"].contains { key in
            guard let value = format[key] as? String else { return true }
            return value.isEmpty || value == "unknown"
        }
    }

    /// Preserve extractor identity, ordering and any reported data. Only actual
    /// FFprobe stream fields can fill missing metadata; never infer from an ID,
    /// filename, bitrate or container extension.
    static func applying(_ data: Data, to original: [String: Any]) -> [String: Any] {
        guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = probe["streams"] as? [[String: Any]], !streams.isEmpty else { return original }
        var format = original
        let video = streams.first { stream in
            stream["codec_type"] as? String == "video" && ((stream["disposition"] as? [String: Any])?["attached_pic"] as? NSNumber)?.boolValue != true
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }
        func missing(_ key: String) -> Bool {
            guard let value = format[key], !(value is NSNull) else { return true }
            if let text = value as? String { return text.isEmpty || text == "unknown" }
            return false
        }
        for (key, stream) in [("vcodec", video), ("acodec", audio)] where missing(key) {
            if let codec = stream?["codec_name"] as? String, !codec.isEmpty { format[key] = codec }
            else if stream == nil { format[key] = "none" }
        }
        if let video {
            if missing("height"), let height = video["height"] as? NSNumber {
                format["height"] = height; format["_mvd_probe_dimensions"] = true
            }
            if missing("width"), let width = video["width"] as? NSNumber { format["width"] = width }
            if missing("fps"), let fraction = video["avg_frame_rate"] as? String {
                let parts = fraction.split(separator: "/").compactMap { Double($0) }
                if parts.count == 2, parts[1] > 0 { format["fps"] = parts[0] / parts[1] }
            }
        }
        for (key, stream) in [("vbr", video), ("abr", audio)] where missing(key) {
            if let raw = stream?["bit_rate"] as? String, let value = Double(raw), value.isFinite, value > 0 {
                format[key] = value / 1_000
            }
        }
        return format
    }
}
