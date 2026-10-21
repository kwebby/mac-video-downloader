import Foundation
import HarborCore
@testable import HarborEngine

@main
enum MediaMetadataHarness {
    static func main() async throws {
        let videoProbe = Data(#"{"streams":[{"codec_type":"video","codec_name":"h264","width":1428,"height":720,"avg_frame_rate":"30/1","bit_rate":"142650"},{"codec_type":"audio","codec_name":"aac","bit_rate":"128557"}]}"#.utf8)
        let original: [String: Any] = ["format_id": "2", "ext": "mp4", "url": "https://example.com/file.mp4", "protocol": "https", "vcodec": NSNull(), "acodec": NSNull(), "height": NSNull(), "tbr": 142.65]
        precondition(MediaMetadataProbe.needsProbe(original))
        let enriched = MediaMetadataProbe.applying(videoProbe, to: original)
        let metadata = try JSONSerialization.data(withJSONObject: ["title": "Public provider fixture", "formats": [enriched]])
        let preview = try MediaResolver.parse(metadata)
        precondition(preview.formats.count == 1)
        let format = preview.formats[0]
        precondition(format.id == "2" && format.hasVideo && format.hasAudio)
        precondition(format.height == 720 && format.width == 1428 && format.fps == 30)
        precondition(format.videoCodec == "h264" && format.audioCodec == "aac")
        precondition(format.videoBitrateKbps == 142.65 && format.audioBitrateKbps == 128.557)
        precondition(preview.qualities == [.best], "A height absent from extractor metadata must not become a yt-dlp height selector.")
        _ = try OptionValidation.selectedFormat(options: DownloadOptions(formatID: "2"), quality: .best, preview: preview)
        _ = try OptionValidation.selectedFormat(options: DownloadOptions(mode: .audioOnly, formatID: "2"), quality: .best, preview: preview)
        let silent = MediaMetadataProbe.applying(Data(#"{"streams":[{"codec_type":"video","codec_name":"h264","width":640,"height":360}]}"#.utf8), to: original)
        let silentPreview = try MediaResolver.parse(JSONSerialization.data(withJSONObject: ["formats": [silent]]))
        precondition(silentPreview.formats.count == 1 && silentPreview.formats[0].hasVideo && !silentPreview.formats[0].hasAudio)
        do {
            _ = try OptionValidation.selectedFormat(options: DownloadOptions(mode: .audioOnly, formatID: "2"), quality: .best, preview: silentPreview)
            preconditionFailure("A silent source was accepted for audio extraction.")
        } catch {}
        let audio = MediaMetadataProbe.applying(Data(#"{"streams":[{"codec_type":"audio","codec_name":"aac","bit_rate":"128000"}]}"#.utf8), to: original)
        let audioPreview = try MediaResolver.parse(JSONSerialization.data(withJSONObject: ["formats": [audio]]))
        precondition(audioPreview.formats.count == 1 && !audioPreview.formats[0].hasVideo && audioPreview.formats[0].hasAudio)
        precondition(MediaMetadataProbe.applying(Data("not JSON".utf8), to: original)["height"] is NSNull)
        for override in [["protocol": "m3u8_native"], ["has_drm": true], ["ext": "mhtml"], ["url": "file:///tmp/private.mp4"], ["format_id": "--exec=bad"]] as [[String: Any]] {
            precondition(!MediaMetadataProbe.needsProbe(original.merging(override) { _, new in new }))
        }
        let reported = original.merging(["height": 360, "width": 640, "vcodec": "h264", "acodec": "aac"]) { _, new in new }
        precondition(!MediaMetadataProbe.needsProbe(reported))
        let reportedPreview = try MediaResolver.parse(JSONSerialization.data(withJSONObject: ["formats": [MediaMetadataProbe.applying(videoProbe, to: reported)]]))
        precondition(reportedPreview.qualities.map(\.id) == ["best", "360p"] && reportedPreview.formats[0].height == 360)
        print("Media metadata fixtures passed: truthful streams/dimensions/bitrates, exact-format acceptance, silent/audio-only isolation, reported quality preservation, and unsupported-source guards.")

        if CommandLine.arguments.count == 2 {
            let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let enriched = try MediaMetadataProbe.enrich(data, directory: directory, proxy: nil, tools: ProviderTools(), control: TransferControl(), deadline: Date().addingTimeInterval(12))
            let preview = try MediaResolver.parse(enriched)
            precondition(preview.formats.count == 3 && preview.formats.allSatisfy { $0.hasVideo && $0.hasAudio && $0.height != nil })
            precondition(preview.qualities == [.best])
            print("Public codec-unreported provider: \(preview.formats.map(\.label).joined(separator: "; "))")
        }
    }
}
