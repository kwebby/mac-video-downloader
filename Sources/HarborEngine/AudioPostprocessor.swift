import Foundation
import HarborCore

enum AudioPostprocessor {
    static func run(file: URL, ffmpeg: String, options: DownloadOptions, control: TransferControl) throws -> TransferResult {
        let directory = file.deletingLastPathComponent()
        var ext = options.audioFormat
        var codec: String
        switch options.audioFormat {
        case "mp3": codec = "libmp3lame"
        case "m4a": codec = "aac"
        case "opus": codec = "libopus"
        case "wav": codec = "pcm_s16le"
        case "flac": codec = "flac"
        default:
            // Preserve the source audio codec. Unknown codecs use Matroska
            // audio instead of silently converting to a lossy fallback.
            codec = "copy"
            ext = originalExtension(file: file, ffmpeg: ffmpeg, control: control)
        }
        let filename = URLValidation.filename(file.deletingPathExtension().lastPathComponent + "-extracted." + ext)
        let output = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        var args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-n", "-i", file.path, "-map", "0:a:0", "-vn", "-c:a", codec]
        if let bitrate = options.audioBitrateKbps { args += ["-b:a", "\(bitrate)k"] }
        args += [output.path]
        var diagnostic = ""
        let status = try SafeSubprocess.run(executable: ffmpeg, arguments: args, directory: directory, control: control, maximumOutputBytes: 1_048_576, timeout: 30 * 60) { diagnostic = ErrorRedactor.message($0) }
        if control.isStopped { throw EngineError.cancelled }
        guard status == 0 else { throw EngineError.transfer("Audio extraction or conversion failed. The source may not contain audio, or the requested encoder may be unavailable. " + diagnostic) }
        return TransferResult(file: output, filename: output.lastPathComponent)
    }

    private static func originalExtension(file: URL, ffmpeg: String, control: TransferControl) -> String {
        let probe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent().appendingPathComponent("ffprobe")
        guard FileManager.default.isExecutableFile(atPath: probe.path) else { return "mka" }
        var data = ""
        let result = try? SafeSubprocess.run(executable: probe.path, arguments: ["-v", "error", "-select_streams", "a:0", "-show_entries", "stream=codec_name", "-of", "default=noprint_wrappers=1:nokey=1", file.path], directory: file.deletingLastPathComponent(), control: control, maximumOutputBytes: 16_384, timeout: 10) { data = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard result == 0 else { return "mka" }
        switch data {
        case "aac", "alac": return "m4a"
        case "mp3": return "mp3"
        case "opus": return "opus"
        case "vorbis": return "ogg"
        case "flac": return "flac"
        case "pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le": return "wav"
        case "ac3", "eac3", "dts": return data
        default: return "mka"
        }
    }
}
