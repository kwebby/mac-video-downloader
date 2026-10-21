import AppKit
import Foundation
import HarborCore
import QuickLookUI
import UniformTypeIdentifiers

extension DownloadJob {
    var isAudio: Bool { playbackMediaKind == .audio }
    var isVideo: Bool { playbackMediaKind == .video }

    /// Eligibility is metadata-only; the file is checked when Play is pressed.
    var canPlay: Bool {
        status == .completed && (isAudio || isVideo) && outputPath?.hasPrefix("/") == true
    }

    func checkedPlaybackURL() throws -> URL {
        guard status == .completed else { throw UIError.message("Wait for this download to finish before playing it.") }
        guard isAudio || isVideo else { throw UIError.message("This download is not an audio or video file.") }
        guard let path = outputPath, path.hasPrefix("/") else {
            throw UIError.message("This completed download has no saved file location.")
        }
        let url = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw UIError.message("This file is no longer in its download folder. Restore it or download it again.")
        }
        guard !isDirectory.boolValue,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw UIError.message("The saved download location does not point to a playable file.")
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw UIError.message("MVD cannot read this file. Check its permissions in Finder and try again.")
        }
        return url
    }

    private var playbackMediaKind: PlaybackMediaKind {
        let path = outputPath.flatMap { $0.isEmpty ? nil : $0 } ?? filename
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "wave", "flac", "opus", "ogg", "oga", "aiff", "aif", "aifc", "alac", "wma", "caf", "amr", "ac3", "eac3"]
        let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "ogv", "3gp", "3g2", "vob", "mxf"]
        if audioExtensions.contains(ext) { return .audio }
        // Original audio-only streams can retain a shared audio/video container.
        if options?.mode == .audioOnly, ["mp4", "webm", "mkv"].contains(ext) { return .audio }
        if videoExtensions.contains(ext) { return .video }
        if let type = UTType(filenameExtension: ext) {
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
            if !ext.isEmpty { return .other }
        }
        if options?.mode == .audioOnly { return .audio }
        return kind == .media ? .video : .other
    }
}

private enum PlaybackMediaKind { case audio, video, other }

/// A retained, independent native window avoids the global preview panel's
/// responder-chain and unowned data-source lifetime requirements.
@MainActor
final class AudioPlaybackPreview: NSWindowController, NSWindowDelegate {
    private var previewView: QLPreviewView?

    init() { super.init(window: nil) }

    required init?(coder: NSCoder) { nil }

    func open(_ url: URL, title: String, appearance: NSAppearance? = nil) throws {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 360, height: 240)
            window.center()
            window.delegate = self
            guard let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 560, height: 340), style: .normal) else {
                throw UIError.message("macOS could not create an audio preview. Try again or open the file from Finder.")
            }
            preview.autoresizingMask = [.width, .height]
            // This controller explicitly closes and discards each view on close,
            // because a closed QLPreviewView cannot accept another preview item.
            preview.shouldCloseWithWindow = false
            preview.autostarts = true
            window.contentView = preview
            previewView = preview
            self.window = window
        }
        window?.title = "\(title) — Audio Preview"
        window?.representedURL = url
        window?.appearance = appearance
        previewView?.previewItem = url as NSURL
        showWindow(nil)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        previewView?.close()
        previewView = nil
        window?.contentView = nil
        window = nil
    }
}
